module media

import crypto.md5 as std_md5
import tl

pub const min_part_size = 4 * 1024
pub const default_part_size = 128 * 1024
pub const max_part_size = 512 * 1024
pub const big_file_threshold = 10 * 1024 * 1024

pub interface ProgressReporter {
	report(progress TransferProgress)
}

struct NopProgressReporter {}

fn (r NopProgressReporter) report(progress TransferProgress) {}

pub struct Part {
pub:
	index       int
	total_parts int
	offset      u64
	bytes       []u8
}

pub struct TransferProgress {
pub:
	transferred u64
	total       u64
	part_index  int
	total_parts int
}

pub struct UploadOptions {
pub:
	file_id     i64
	part_size   int = default_part_size
	resume_part int
	reporter    ProgressReporter = NopProgressReporter{}
}

pub struct UploadedFile {
pub:
	file_id      i64
	name         string
	total_size   u64
	part_size    int
	total_parts  int
	resume_part  int
	is_big       bool
	md5_checksum string
	input_file   tl.InputFileType
}

pub struct SendFileOptions {
pub:
	upload        UploadOptions
	caption       string
	mime_type     string = 'application/octet-stream'
	attributes    []tl.DocumentAttributeType
	force_file    bool = true
	nosound_video bool
	spoiler       bool
}

pub struct SendPhotoOptions {
pub:
	upload                UploadOptions
	caption               string
	spoiler               bool
	ttl_seconds           int
	has_ttl_seconds_value bool
}

pub struct DownloadOptions {
pub:
	offset        i64
	max_bytes     i64
	part_size     int = default_part_size
	precise       bool
	cdn_supported bool             = true
	reporter      ProgressReporter = NopProgressReporter{}
}

pub struct CdnRedirect {
pub:
	dc_id          int
	file_token     []u8
	encryption_key []u8
	encryption_iv  []u8
	file_hashes    []tl.FileHashType
}

pub struct DownloadResult {
pub:
	bytes            []u8
	start_offset     i64
	end_offset       i64
	completed        bool
	has_cdn_redirect bool
	cdn_redirect     CdnRedirect
}

pub struct UploadPlan {
pub:
	file_id      i64
	name         string
	total_size   u64
	part_size    int
	total_parts  int
	resume_part  int
	is_big       bool
	md5_checksum string
mut:
	payload  []u8
	reporter ProgressReporter = NopProgressReporter{}
}

pub struct DownloadCursor {
pub:
	start_offset  i64
	part_size     int
	max_bytes     i64
	precise       bool
	cdn_supported bool
mut:
	offset           i64
	transferred      u64
	chunks_completed int
	complete         bool
	reporter         ProgressReporter = NopProgressReporter{}
}

pub fn normalize_part_size(part_size int) !int {
	if part_size < min_part_size {
		return error('media part size must be at least ${min_part_size} bytes')
	}
	if part_size > max_part_size {
		return error('media part size must be at most ${max_part_size} bytes')
	}
	if part_size % 1024 != 0 {
		return error('media part size must be divisible by 1024 bytes')
	}
	return part_size
}

pub fn new_upload_plan(name string, payload []u8, options UploadOptions) !UploadPlan {
	if name.len == 0 {
		return error('upload file name must not be empty')
	}
	if payload.len == 0 {
		return error('upload payload must not be empty')
	}
	if options.file_id == 0 {
		return error('upload file id must be non-zero')
	}
	part_size := normalize_part_size(options.part_size)!
	total_parts := (payload.len + part_size - 1) / part_size
	if options.resume_part < 0 {
		return error('upload resume_part must not be negative')
	}
	if options.resume_part > total_parts {
		return error('upload resume_part must not exceed total parts')
	}
	is_big := payload.len > big_file_threshold
	md5_checksum := if is_big { '' } else { std_md5.sum(payload).hex() }
	return UploadPlan{
		file_id:      options.file_id
		name:         name
		total_size:   u64(payload.len)
		part_size:    part_size
		total_parts:  total_parts
		resume_part:  options.resume_part
		is_big:       is_big
		md5_checksum: md5_checksum
		payload:      payload.clone()
		reporter:     options.reporter
	}
}

pub fn (p UploadPlan) initial_progress() TransferProgress {
	mut transferred := u64(p.resume_part * p.part_size)
	if transferred > p.total_size {
		transferred = p.total_size
	}
	return TransferProgress{
		transferred: transferred
		total:       p.total_size
		part_index:  p.resume_part - 1
		total_parts: p.total_parts
	}
}

pub fn (p UploadPlan) remaining_parts() int {
	return p.total_parts - p.resume_part
}

pub fn (p UploadPlan) part(index int) !Part {
	if index < 0 || index >= p.total_parts {
		return error('upload part index ${index} is out of range')
	}
	start := index * p.part_size
	end := if start + p.part_size < p.payload.len {
		start + p.part_size
	} else {
		p.payload.len
	}
	return Part{
		index:       index
		total_parts: p.total_parts
		offset:      u64(start)
		bytes:       p.payload[start..end].clone()
	}
}

pub fn (p UploadPlan) progress_after_part(index int) !TransferProgress {
	part := p.part(index)!
	transferred := part.offset + u64(part.bytes.len)
	return TransferProgress{
		transferred: transferred
		total:       p.total_size
		part_index:  index
		total_parts: p.total_parts
	}
}

pub fn (p UploadPlan) report_initial_progress() {
	p.reporter.report(p.initial_progress())
}

pub fn (p UploadPlan) report_uploaded_part(index int) ! {
	p.reporter.report(p.progress_after_part(index)!)
}

pub fn (p UploadPlan) uploaded_file() UploadedFile {
	input_file := if p.is_big {
		tl.InputFileType(tl.InputFileBig{
			id:    p.file_id
			parts: p.total_parts
			name:  p.name
		})
	} else {
		tl.InputFileType(tl.InputFile{
			id:           p.file_id
			parts:        p.total_parts
			name:         p.name
			md5_checksum: p.md5_checksum
		})
	}
	return UploadedFile{
		file_id:      p.file_id
		name:         p.name
		total_size:   p.total_size
		part_size:    p.part_size
		total_parts:  p.total_parts
		resume_part:  p.resume_part
		is_big:       p.is_big
		md5_checksum: p.md5_checksum
		input_file:   input_file
	}
}

pub fn new_download_cursor(options DownloadOptions) !DownloadCursor {
	if options.offset < 0 {
		return error('download offset must not be negative')
	}
	if options.max_bytes < 0 {
		return error('download max_bytes must not be negative')
	}
	part_size := normalize_part_size(options.part_size)!
	return DownloadCursor{
		start_offset:  options.offset
		part_size:     part_size
		max_bytes:     options.max_bytes
		precise:       options.precise
		cdn_supported: options.cdn_supported
		offset:        options.offset
		reporter:      options.reporter
		complete:      options.max_bytes == 0 && false
	}
}

pub fn (c DownloadCursor) is_complete() bool {
	return c.complete
}

pub fn (c DownloadCursor) current_offset() i64 {
	return c.offset
}

pub fn (c DownloadCursor) next_offset() i64 {
	return c.offset
}

pub fn (c DownloadCursor) next_limit() int {
	if c.complete {
		return 0
	}
	if c.max_bytes > 0 {
		remaining := c.max_bytes - i64(c.transferred)
		if remaining <= 0 {
			return 0
		}
		if remaining < c.part_size {
			return int(remaining)
		}
	}
	return c.part_size
}

pub fn (mut c DownloadCursor) accept_chunk(chunk_len int) !TransferProgress {
	if chunk_len < 0 {
		return error('download chunk length must not be negative')
	}
	requested := c.next_limit()
	if requested <= 0 {
		return error('download cursor has no remaining capacity')
	}
	if chunk_len > requested {
		return error('download chunk length ${chunk_len} exceeds requested limit ${requested}')
	}
	c.offset += chunk_len
	c.transferred += u64(chunk_len)
	c.chunks_completed++
	if chunk_len < requested {
		c.complete = true
	}
	if c.max_bytes > 0 && i64(c.transferred) >= c.max_bytes {
		c.complete = true
	}
	progress := TransferProgress{
		transferred: c.transferred
		total:       if c.max_bytes > 0 { u64(c.max_bytes) } else { 0 }
		part_index:  c.chunks_completed - 1
		total_parts: if c.max_bytes > 0 {
			(int(c.max_bytes) + c.part_size - 1) / c.part_size
		} else {
			0
		}
	}
	c.reporter.report(progress)
	return progress
}
