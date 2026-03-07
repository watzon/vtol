module media

import crypto
import crypto.aes as std_aes
import crypto.md5 as std_md5
import tl

// min_part_size is the smallest supported upload or download part size in bytes.
pub const min_part_size = 4 * 1024
// default_part_size is the default upload or download part size in bytes.
pub const default_part_size = 128 * 1024
// max_part_size is the largest supported upload or download part size in bytes.
pub const max_part_size = 512 * 1024
// big_file_threshold is the size above which Telegram requires the big-file upload path.
pub const big_file_threshold = 10 * 1024 * 1024

// ProgressReporter receives upload and download progress updates.
pub interface ProgressReporter {
	report(progress TransferProgress)
}

struct NopProgressReporter {}

fn (r NopProgressReporter) report(progress TransferProgress) {}

// Part describes a single file part within an upload plan.
pub struct Part {
pub:
	index       int
	total_parts int
	offset      u64
	bytes       []u8
}

// TransferProgress reports the current progress of an upload or download.
pub struct TransferProgress {
pub:
	transferred u64
	total       u64
	part_index  int
	total_parts int
}

// UploadOptions configures upload planning and progress reporting.
pub struct UploadOptions {
pub:
	file_id     i64
	part_size   int = default_part_size
	resume_part int
	reporter    ProgressReporter = NopProgressReporter{}
}

// UploadedFile describes a successfully prepared Telegram input file.
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

// SendFileOptions configures document sends built on top of the media helpers.
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

// SendPhotoOptions configures photo sends built on top of the media helpers.
pub struct SendPhotoOptions {
pub:
	upload                UploadOptions
	caption               string
	spoiler               bool
	ttl_seconds           int
	has_ttl_seconds_value bool
}

// DownloadOptions configures download cursor behavior and progress reporting.
pub struct DownloadOptions {
pub:
	offset        i64
	max_bytes     i64
	part_size     int = default_part_size
	precise       bool
	cdn_supported bool             = true
	reporter      ProgressReporter = NopProgressReporter{}
}

// CdnRedirect stores the metadata Telegram returns for CDN-backed downloads.
pub struct CdnRedirect {
pub:
	dc_id          int
	file_token     []u8
	encryption_key []u8
	encryption_iv  []u8
	file_hashes    []tl.FileHashType
}

// FileReferenceKind identifies which Telegram file location variant to build.
pub enum FileReferenceKind {
	document
	photo
}

// FileReference stores the data needed to reconstruct an input file location.
pub struct FileReference {
pub:
	kind           FileReferenceKind
	id             i64
	access_hash    i64
	file_reference []u8
	thumb_size     string
}

// DownloadResult is returned by client and media download helpers.
pub struct DownloadResult {
pub:
	bytes            []u8
	start_offset     i64
	end_offset       i64
	completed        bool
	has_cdn_redirect bool
	cdn_redirect     CdnRedirect
}

// UploadPlan precomputes upload parts, file metadata, and progress reporting.
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

// DownloadCursor tracks paged download progress across successive getFile calls.
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

// new_document_file_reference builds a FileReference for a document location.
pub fn new_document_file_reference(id i64, access_hash i64, file_reference []u8, thumb_size string) FileReference {
	return FileReference{
		kind:           .document
		id:             id
		access_hash:    access_hash
		file_reference: file_reference.clone()
		thumb_size:     thumb_size
	}
}

// new_photo_file_reference builds a FileReference for a photo location.
pub fn new_photo_file_reference(id i64, access_hash i64, file_reference []u8, thumb_size string) FileReference {
	return FileReference{
		kind:           .photo
		id:             id
		access_hash:    access_hash
		file_reference: file_reference.clone()
		thumb_size:     thumb_size
	}
}

// document_file_reference extracts a FileReference from a TL document.
pub fn document_file_reference(document tl.Document, thumb_size string) FileReference {
	return new_document_file_reference(document.id, document.access_hash, document.file_reference,
		thumb_size)
}

// photo_file_reference extracts a FileReference from a TL photo.
pub fn photo_file_reference(photo tl.Photo, thumb_size string) FileReference {
	return new_photo_file_reference(photo.id, photo.access_hash, photo.file_reference,
		thumb_size)
}

// input_location converts a FileReference back into a TL input file location.
pub fn (reference FileReference) input_location() tl.InputFileLocationType {
	return match reference.kind {
		.document {
			tl.InputFileLocationType(tl.InputDocumentFileLocation{
				id:             reference.id
				access_hash:    reference.access_hash
				file_reference: reference.file_reference.clone()
				thumb_size:     reference.thumb_size
			})
		}
		.photo {
			tl.InputFileLocationType(tl.InputPhotoFileLocation{
				id:             reference.id
				access_hash:    reference.access_hash
				file_reference: reference.file_reference.clone()
				thumb_size:     reference.thumb_size
			})
		}
	}
}

// with_file_reference returns a copy with an updated file_reference payload.
pub fn (reference FileReference) with_file_reference(file_reference []u8) FileReference {
	return FileReference{
		kind:           reference.kind
		id:             reference.id
		access_hash:    reference.access_hash
		file_reference: file_reference.clone()
		thumb_size:     reference.thumb_size
	}
}

// is_file_reference_error reports whether a Telegram error indicates a stale file reference.
pub fn is_file_reference_error(message string) bool {
	return file_reference_error_index(message) != none || message == 'FILE_REFERENCE_EXPIRED'
		|| message == 'FILE_REFERENCE_INVALID'
}

// file_reference_error_index extracts the indexed file reference from a Telegram error message.
pub fn file_reference_error_index(message string) ?int {
	if message == 'FILE_REFERENCE_EXPIRED' || message == 'FILE_REFERENCE_INVALID' {
		return 0
	}
	for suffix in ['_EXPIRED', '_INVALID'] {
		prefix := 'FILE_REFERENCE_'
		if !message.starts_with(prefix) || !message.ends_with(suffix) {
			continue
		}
		index_text := message[prefix.len..message.len - suffix.len]
		if index_text.len == 0 {
			continue
		}
		index := index_text.int()
		if index >= 0 {
			return index
		}
	}
	return none
}

// merge_file_hashes merges updated file hashes over an existing set.
pub fn merge_file_hashes(existing []tl.FileHashType, updates []tl.FileHashType) []tl.FileHashType {
	mut merged := []tl.FileHashType{}
	for hash in existing {
		if !has_matching_file_hash(updates, hash) {
			merged << hash
		}
	}
	for hash in updates {
		merged << hash
	}
	return merged
}

// file_hash_at finds the file hash for a specific offset and limit pair.
pub fn file_hash_at(hashes []tl.FileHashType, offset i64, limit int) ?tl.FileHash {
	for hash in hashes {
		match hash {
			tl.FileHash {
				if hash.offset == offset && hash.limit == limit {
					return *hash
				}
			}
			else {}
		}
	}
	return none
}

// verify_file_hash validates a downloaded chunk against Telegram-provided hashes.
pub fn verify_file_hash(bytes []u8, offset i64, hashes []tl.FileHashType) ! {
	expected := file_hash_at(hashes, offset, bytes.len) or {
		return error('missing file hash for offset ${offset} limit ${bytes.len}')
	}
	digest := crypto.default_backend().sha256(bytes)!
	if digest != expected.hash {
		return error('file hash mismatch at offset ${offset} limit ${bytes.len}')
	}
}

// decrypt_cdn_bytes decrypts a CDN chunk using Telegram's CTR-style byte offset rules.
pub fn decrypt_cdn_bytes(ciphertext []u8, key []u8, iv []u8, offset i64) ![]u8 {
	if key.len != crypto.tmp_aes_key_size {
		return error('cdn encryption key must be ${crypto.tmp_aes_key_size} bytes')
	}
	if iv.len != std_aes.block_size {
		return error('cdn encryption iv must be ${std_aes.block_size} bytes')
	}
	if offset < 0 {
		return error('cdn offset must not be negative')
	}
	if ciphertext.len == 0 {
		return []u8{}
	}
	cipher := std_aes.new_cipher(key)
	mut counter := cdn_counter_iv(iv, offset)!
	mut keystream := []u8{len: std_aes.block_size}
	mut out := []u8{len: ciphertext.len}
	mut source_index := 0
	skip := int(offset % i64(std_aes.block_size))
	if skip > 0 {
		cipher.encrypt(mut keystream, counter)
		remaining := std_aes.block_size - skip
		first_len := if ciphertext.len < remaining { ciphertext.len } else { remaining }
		for inner in 0 .. first_len {
			out[inner] = ciphertext[inner] ^ keystream[skip + inner]
		}
		source_index += first_len
		increment_counter(mut counter)
	}
	for source_index < ciphertext.len {
		cipher.encrypt(mut keystream, counter)
		chunk_len := if ciphertext.len - source_index < std_aes.block_size {
			ciphertext.len - source_index
		} else {
			std_aes.block_size
		}
		for inner in 0 .. chunk_len {
			out[source_index + inner] = ciphertext[source_index + inner] ^ keystream[inner]
		}
		source_index += chunk_len
		increment_counter(mut counter)
	}
	return out
}

// decrypt_and_verify_cdn_bytes verifies and decrypts a CDN chunk in one step.
pub fn decrypt_and_verify_cdn_bytes(ciphertext []u8, redirect CdnRedirect, offset i64) ![]u8 {
	verify_file_hash(ciphertext, offset, redirect.file_hashes)!
	return decrypt_cdn_bytes(ciphertext, redirect.encryption_key, redirect.encryption_iv,
		offset)!
}

// normalize_part_size validates a part size against Telegram's media rules.
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

// new_upload_plan builds an UploadPlan for a file payload and upload options.
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

// initial_progress returns the initial progress state for an upload plan.
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

// remaining_parts returns how many parts are left to upload.
pub fn (p UploadPlan) remaining_parts() int {
	return p.total_parts - p.resume_part
}

// part returns a specific upload part by index.
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

// progress_after_part returns upload progress after the given part completes.
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

// report_initial_progress emits the initial upload progress to the configured reporter.
pub fn (p UploadPlan) report_initial_progress() {
	p.reporter.report(p.initial_progress())
}

// report_uploaded_part emits progress after the given upload part completes.
pub fn (p UploadPlan) report_uploaded_part(index int) ! {
	p.reporter.report(p.progress_after_part(index)!)
}

// uploaded_file converts the plan metadata into an UploadedFile descriptor.
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

// new_download_cursor creates a download cursor from validated download options.
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

// is_complete reports whether the cursor has consumed all requested bytes.
pub fn (c DownloadCursor) is_complete() bool {
	return c.complete
}

// current_offset returns the next unread offset after accepted chunks.
pub fn (c DownloadCursor) current_offset() i64 {
	return c.offset
}

// next_offset returns the offset that should be used for the next request.
pub fn (c DownloadCursor) next_offset() i64 {
	return c.offset
}

// next_limit returns the chunk size to request next.
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

// accept_chunk advances the cursor after a successful download response.
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

fn has_matching_file_hash(hashes []tl.FileHashType, candidate tl.FileHashType) bool {
	match candidate {
		tl.FileHash {
			for hash in hashes {
				match hash {
					tl.FileHash {
						if hash.offset == candidate.offset && hash.limit == candidate.limit {
							return true
						}
					}
					else {}
				}
			}
		}
		else {}
	}
	return false
}

fn cdn_counter_iv(iv []u8, offset i64) ![]u8 {
	if offset < 0 {
		return error('cdn offset must not be negative')
	}
	block_index := u64(offset / i64(std_aes.block_size))
	if block_index > u64(u32(0xffffffff)) {
		return error('cdn offset ${offset} exceeds supported ctr counter range')
	}
	mut counter := iv.clone()
	counter[counter.len - 4] = u8((block_index >> 24) & 0xff)
	counter[counter.len - 3] = u8((block_index >> 16) & 0xff)
	counter[counter.len - 2] = u8((block_index >> 8) & 0xff)
	counter[counter.len - 1] = u8(block_index & 0xff)
	return counter
}

fn increment_counter(mut counter []u8) {
	for reverse_index in 0 .. counter.len {
		index := counter.len - 1 - reverse_index
		counter[index]++
		if counter[index] != 0 {
			return
		}
	}
}
