module media

import crypto
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

fn test_file_reference_round_trips_into_input_locations() {
	document_reference := new_document_file_reference(11, 22, [u8(1), 2, 3], 'y')
	document_location := document_reference.input_location()
	match document_location {
		tl.InputDocumentFileLocation {
			assert document_location.id == 11
			assert document_location.access_hash == 22
			assert document_location.file_reference == [u8(1), 2, 3]
			assert document_location.thumb_size == 'y'
		}
		else {
			assert false
		}
	}

	photo_reference := new_photo_file_reference(33, 44, [u8(4), 5], 'm').with_file_reference([
		u8(9),
		8,
	])
	photo_location := photo_reference.input_location()
	match photo_location {
		tl.InputPhotoFileLocation {
			assert photo_location.id == 33
			assert photo_location.access_hash == 44
			assert photo_location.file_reference == [u8(9), 8]
			assert photo_location.thumb_size == 'm'
		}
		else {
			assert false
		}
	}
}

fn test_file_reference_error_helpers_cover_plain_and_indexed_errors() {
	assert is_file_reference_error('FILE_REFERENCE_EXPIRED')
	assert is_file_reference_error('FILE_REFERENCE_INVALID')
	assert is_file_reference_error('FILE_REFERENCE_3_EXPIRED')
	assert file_reference_error_index('FILE_REFERENCE_3_EXPIRED') or { panic(err) } == 3
	assert file_reference_error_index('FILE_REFERENCE_7_INVALID') or { panic(err) } == 7
	assert file_reference_error_index('PHONE_MIGRATE_4') == none
	assert !is_file_reference_error('PHONE_MIGRATE_4')
}

fn test_merge_and_verify_file_hashes() {
	chunk := 'cdn-fragment'.bytes()
	digest := crypto.default_backend().sha256(chunk) or { panic(err) }
	mut merged := merge_file_hashes([
		tl.FileHashType(tl.FileHash{
			offset: 0
			limit:  4
			hash:   [u8(1)]
		}),
	], [
		tl.FileHashType(tl.FileHash{
			offset: 0
			limit:  chunk.len
			hash:   digest
		}),
	])
	assert merged.len == 2
	verify_file_hash(chunk, 0, merged) or { panic(err) }
	verify_file_hash('bad-fragment'.bytes(), 0, merged) or {
		assert err.msg() == 'file hash mismatch at offset 0 limit 12'
		return
	}
	assert false
}

fn test_decrypt_cdn_bytes_matches_stable_ctr_vector() {
	key := [
		u8(0x00),
		0x01,
		0x02,
		0x03,
		0x04,
		0x05,
		0x06,
		0x07,
		0x08,
		0x09,
		0x0a,
		0x0b,
		0x0c,
		0x0d,
		0x0e,
		0x0f,
		0x10,
		0x11,
		0x12,
		0x13,
		0x14,
		0x15,
		0x16,
		0x17,
		0x18,
		0x19,
		0x1a,
		0x1b,
		0x1c,
		0x1d,
		0x1e,
		0x1f,
	]
	iv := [
		u8(0x00),
		0x01,
		0x02,
		0x03,
		0x04,
		0x05,
		0x06,
		0x07,
		0x08,
		0x09,
		0x0a,
		0x0b,
		0x0c,
		0x0d,
		0x0e,
		0x0f,
	]
	ciphertext := [
		u8(0x0e),
		0xc5,
		0x8c,
		0x94,
		0x1c,
		0x8b,
		0x6d,
		0xac,
		0xe4,
		0x65,
		0x5f,
		0xee,
		0xe3,
		0xe8,
		0x3e,
		0x8c,
		0x8b,
		0x84,
		0xaa,
		0xa1,
		0x5b,
		0xf5,
		0x87,
		0x10,
		0x46,
		0x1a,
		0x2f,
		0x7c,
		0xf1,
		0x33,
		0x32,
		0x5b,
	]
	plaintext := decrypt_cdn_bytes(ciphertext, key, iv, 4096) or { panic(err) }
	assert plaintext.hex() == '00112233445566778899aabbccddeeff102132435465768798a9bacbdcedfe0f'
}

fn test_decrypt_and_verify_cdn_bytes_checks_hash_before_decrypting() {
	ciphertext := [
		u8(0x4d),
		0x3d,
		0x9e,
		0x09,
		0x05,
		0xf5,
		0xf0,
		0x4b,
		0xb9,
		0x97,
		0x31,
		0x47,
		0x86,
		0x3e,
		0x20,
		0xb9,
	]
	redirect := CdnRedirect{
		dc_id:          5
		file_token:     [u8(1), 2]
		encryption_key: [
			u8(0x00),
			0x01,
			0x02,
			0x03,
			0x04,
			0x05,
			0x06,
			0x07,
			0x08,
			0x09,
			0x0a,
			0x0b,
			0x0c,
			0x0d,
			0x0e,
			0x0f,
			0x10,
			0x11,
			0x12,
			0x13,
			0x14,
			0x15,
			0x16,
			0x17,
			0x18,
			0x19,
			0x1a,
			0x1b,
			0x1c,
			0x1d,
			0x1e,
			0x1f,
		]
		encryption_iv:  [
			u8(0x00),
			0x01,
			0x02,
			0x03,
			0x04,
			0x05,
			0x06,
			0x07,
			0x08,
			0x09,
			0x0a,
			0x0b,
			0x0c,
			0x0d,
			0x0e,
			0x0f,
		]
		file_hashes:    [
			tl.FileHashType(tl.FileHash{
				offset: 0
				limit:  ciphertext.len
				hash:   crypto.default_backend().sha256(ciphertext) or { panic(err) }
			}),
		]
	}

	plaintext := decrypt_and_verify_cdn_bytes(ciphertext, redirect, 0) or { panic(err) }
	assert plaintext.hex() == 'f0e1d2c3b4a5968778695a4b3c2d1e0f'
}
