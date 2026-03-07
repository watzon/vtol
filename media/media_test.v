module media

import crypto.md5 as std_md5
import tl

@[heap]
struct ReporterState {
mut:
	events []TransferProgress
}

struct Reporter {
mut:
	state &ReporterState
}

fn (r Reporter) report(progress TransferProgress) {
	unsafe {
		r.state.events << progress
	}
}

fn test_new_upload_plan_splits_payload_and_preserves_resume_progress() {
	payload := []u8{len: 6000, init: u8((index % 251) + 1)}
	plan := new_upload_plan('notes.txt', payload, UploadOptions{
		file_id:     99
		part_size:   4096
		resume_part: 1
	}) or { panic(err) }

	assert plan.file_id == 99
	assert plan.total_parts == 2
	assert plan.remaining_parts() == 1
	assert !plan.is_big
	assert plan.md5_checksum == std_md5.sum(payload).hex()

	progress := plan.initial_progress()
	assert progress.transferred == 4096
	assert progress.total == u64(payload.len)
	assert progress.part_index == 0

	part := plan.part(1) or { panic(err) }
	assert part.index == 1
	assert part.total_parts == 2
	assert part.offset == 4096
	assert part.bytes.len == 1904

	uploaded := plan.uploaded_file()
	match uploaded.input_file {
		tl.InputFile {
			assert uploaded.input_file.id == 99
			assert uploaded.input_file.parts == 2
			assert uploaded.input_file.name == 'notes.txt'
			assert uploaded.input_file.md5_checksum == plan.md5_checksum
		}
		else {
			assert false
		}
	}
}

fn test_new_upload_plan_marks_big_files_as_input_file_big() {
	payload := []u8{len: big_file_threshold + 1}
	plan := new_upload_plan('archive.bin', payload, UploadOptions{
		file_id: 100
	}) or { panic(err) }

	assert plan.is_big
	assert plan.md5_checksum == ''
	uploaded := plan.uploaded_file()
	match uploaded.input_file {
		tl.InputFileBig {
			assert uploaded.input_file.id == 100
			assert uploaded.input_file.parts == plan.total_parts
			assert uploaded.input_file.name == 'archive.bin'
		}
		else {
			assert false
		}
	}
}

fn test_upload_plan_reports_uploaded_parts() {
	payload := []u8{len: 5000, init: u8((index % 251) + 1)}
	mut state := &ReporterState{}
	plan := new_upload_plan('report.txt', payload, UploadOptions{
		file_id:   101
		part_size: 4096
		reporter:  Reporter{
			state: state
		}
	}) or { panic(err) }

	plan.report_initial_progress()
	plan.report_uploaded_part(0) or { panic(err) }
	plan.report_uploaded_part(1) or { panic(err) }

	assert state.events.len == 3
	assert state.events[0].transferred == 0
	assert state.events[1].transferred == 4096
	assert state.events[2].transferred == u64(payload.len)
}

fn test_download_cursor_tracks_fixed_limits_and_short_chunks() {
	mut state := &ReporterState{}
	mut cursor := new_download_cursor(DownloadOptions{
		part_size: 4096
		max_bytes: 5000
		reporter:  Reporter{
			state: state
		}
	}) or { panic(err) }

	assert cursor.next_limit() == 4096
	_ = cursor.accept_chunk(4096) or { panic(err) }
	assert !cursor.is_complete()
	assert cursor.next_offset() == 4096
	assert cursor.next_limit() == 904
	_ = cursor.accept_chunk(904) or { panic(err) }
	assert cursor.is_complete()
	assert cursor.current_offset() == 5000
	assert state.events.len == 2
	assert state.events[0].total == 5000
	assert state.events[1].transferred == 5000
}

fn test_download_cursor_completes_on_short_unbounded_chunk() {
	mut cursor := new_download_cursor(DownloadOptions{
		part_size: 4096
	}) or { panic(err) }

	_ = cursor.accept_chunk(2048) or { panic(err) }
	assert cursor.is_complete()
	assert cursor.current_offset() == 2048
}
