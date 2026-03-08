module vtol

import media
import os
import tl

// upload_file_bytes uploads an in-memory payload and returns the resulting Telegram input file.
pub fn (mut c Client) upload_file_bytes(name string, data []u8, options media.UploadOptions) !media.UploadedFile {
	c.connect()!
	file_id := if options.file_id != 0 {
		options.file_id
	} else {
		c.random_id()!
	}
	plan := media.new_upload_plan(name, data, media.UploadOptions{
		file_id:     file_id
		part_size:   options.part_size
		resume_part: options.resume_part
		reporter:    options.reporter
	})!
	plan.report_initial_progress()
	for part_index in plan.resume_part .. plan.total_parts {
		part := plan.part(part_index)!
		method_name := if plan.is_big { 'upload.saveBigFilePart' } else { 'upload.saveFilePart' }
		result := if plan.is_big {
			c.invoke(tl.UploadSaveBigFilePart{
				file_id:          plan.file_id
				file_part:        part.index
				file_total_parts: plan.total_parts
				bytes:            part.bytes
			})!
		} else {
			c.invoke(tl.UploadSaveFilePart{
				file_id:   plan.file_id
				file_part: part.index
				bytes:     part.bytes
			})!
		}
		expect_bool_true(result, method_name)!
		plan.report_uploaded_part(part.index)!
	}
	return plan.uploaded_file()
}

// upload_file_path reads and uploads a local file path.
pub fn (mut c Client) upload_file_path(path string, options media.UploadOptions) !media.UploadedFile {
	if path.len == 0 {
		return error('upload path must not be empty')
	}
	name := os.file_name(path)
	if name.len == 0 {
		return error('upload path must include a file name')
	}
	data := os.read_bytes(path)!
	return c.upload_file_bytes(name, data, options)!
}

// download_file downloads bytes for a Telegram file location.
pub fn (mut c Client) download_file(location tl.InputFileLocationType, options media.DownloadOptions) !media.DownloadResult {
	c.connect()!
	mut cursor := media.new_download_cursor(options)!
	mut bytes := []u8{}
	for !cursor.is_complete() {
		limit := cursor.next_limit()
		if limit <= 0 {
			break
		}
		result := c.invoke(tl.UploadGetFile{
			precise:       options.precise
			cdn_supported: options.cdn_supported
			location:      location
			offset:        cursor.next_offset()
			limit:         limit
		})!
		match result {
			tl.UploadFile {
				bytes << result.bytes.clone()
				_ = cursor.accept_chunk(result.bytes.len)!
			}
			tl.UploadFileCdnRedirect {
				return media.DownloadResult{
					bytes:            bytes
					start_offset:     cursor.start_offset
					end_offset:       cursor.current_offset()
					completed:        false
					has_cdn_redirect: true
					cdn_redirect:     media.CdnRedirect{
						dc_id:          result.dc_id
						file_token:     result.file_token.clone()
						encryption_key: result.encryption_key.clone()
						encryption_iv:  result.encryption_iv.clone()
						file_hashes:    result.file_hashes.clone()
					}
				}
			}
			else {
				return error('expected upload.File, got ${result.qualified_name()}')
			}
		}
	}
	return media.DownloadResult{
		bytes:        bytes
		start_offset: cursor.start_offset
		end_offset:   cursor.current_offset()
		completed:    true
	}
}

// send_text sends a text message to a peer-like target and returns a normalized SentMessage.
pub fn (mut c Client) send_text[T](peer T, message RichTextInput) !SentMessage {
	return c.send_text_with(peer, message, SendOptions{})!
}

// send_text_with sends a text message using explicit send options.
pub fn (mut c Client) send_text_with[T](peer T, message RichTextInput, options SendOptions) !SentMessage {
	resolved := c.resolve_peer_like(peer)!
	text := rich_text_from_input(message)
	batch := c.send_message_updates_with(resolved.input_peer, text, options)!
	return sent_message_from_updates(c, resolved, batch, text.text)!
}

// send_message is an alias for send_text.
pub fn (mut c Client) send_message[T](peer T, message RichTextInput) !SentMessage {
	return c.send_text(peer, message)!
}

// send_text_updates sends a text message and returns the raw updates payload.
pub fn (mut c Client) send_text_updates[T](peer T, message RichTextInput) !tl.UpdatesType {
	return c.send_text_updates_with(peer, message, SendOptions{})!
}

// send_text_updates_with sends a text message and returns the raw updates payload with explicit options.
pub fn (mut c Client) send_text_updates_with[T](peer T, message RichTextInput, options SendOptions) !tl.UpdatesType {
	resolved := c.resolve_peer_like(peer)!
	return c.send_message_updates_with(resolved.input_peer, message, options)!
}

// send_message_updates sends a text message to a resolved input peer and returns the raw updates payload.
pub fn (mut c Client) send_message_updates(peer tl.InputPeerType, message RichTextInput) !tl.UpdatesType {
	return c.send_message_updates_with(peer, message, SendOptions{})!
}

// send_message_updates_with sends a text message to a resolved input peer with explicit options.
pub fn (mut c Client) send_message_updates_with(peer tl.InputPeerType, message RichTextInput, options SendOptions) !tl.UpdatesType {
	text := rich_text_from_input(message)
	if text.text.len == 0 {
		return error('message must not be empty')
	}
	resolved_options := normalize_send_options(options)!
	result := c.invoke(tl.MessagesSendMessage{
		peer:                           peer
		no_webpage:                     resolved_options.disable_link_preview
		silent:                         resolved_options.silent
		reply_to:                       resolved_options.reply_to
		has_reply_to_value:             resolved_options.has_reply_to_value
		message:                        text.text
		random_id:                      c.random_id()!
		reply_markup:                   tl.UnknownReplyMarkupType{}
		has_reply_markup_value:         false
		entities:                       text.entities.clone()
		has_entities_value:             text.entities.len > 0
		schedule_date:                  resolved_options.schedule_date
		has_schedule_date_value:        resolved_options.has_schedule_date_value
		send_as:                        tl.InputPeerEmpty{}
		has_send_as_value:              false
		quick_reply_shortcut:           tl.UnknownInputQuickReplyShortcutType{}
		has_quick_reply_shortcut_value: false
		suggested_post:                 tl.UnknownSuggestedPostType{}
		has_suggested_post_value:       false
	})!
	return c.ingest_updates_result(result)!
}

// send_file uploads and sends a document to a peer-like target.
pub fn (mut c Client) send_file[T](peer T, name string, data []u8, options SendFileOptions) !SentMessage {
	resolved := c.resolve_peer_like(peer)!
	batch := c.send_file_updates(resolved, name, data, options)!
	return sent_message_from_updates(c, resolved, batch, options.caption)!
}

// send_file_updates uploads and sends a document and returns the raw updates payload.
pub fn (mut c Client) send_file_updates[T](peer T, name string, data []u8, options SendFileOptions) !tl.UpdatesType {
	resolved := c.resolve_peer_like(peer)!
	uploaded := c.upload_file_bytes(name, data, options.upload)!
	mime_type := if options.mime_type.len > 0 {
		options.mime_type
	} else {
		'application/octet-stream'
	}
	return c.send_media_request_updates(resolved.input_peer, tl.InputMediaUploadedDocument{
		nosound_video:             options.nosound_video
		force_file:                options.force_file
		spoiler:                   options.spoiler
		file:                      uploaded.input_file
		thumb:                     tl.InputFile{}
		video_cover:               tl.InputPhotoEmpty{}
		mime_type:                 mime_type
		attributes:                document_attributes_with_filename(uploaded.name, options.attributes)
		has_thumb_value:           false
		has_stickers_value:        false
		has_video_cover_value:     false
		has_video_timestamp_value: false
		has_ttl_seconds_value:     false
	}, options.caption, file_send_options_to_send_options(options))
}

// send_file_path reads, uploads, and sends a document from disk.
pub fn (mut c Client) send_file_path[T](peer T, path string, options SendFileOptions) !SentMessage {
	if path.len == 0 {
		return error('file path must not be empty')
	}
	name := os.file_name(path)
	if name.len == 0 {
		return error('file path must include a file name')
	}
	data := os.read_bytes(path)!
	return c.send_file(peer, name, data, options)!
}

// send_file_to_username is a convenience wrapper around send_file for usernames.
pub fn (mut c Client) send_file_to_username(username string, name string, data []u8, options SendFileOptions) !SentMessage {
	return c.send_file(username, name, data, options)!
}

// send_photo uploads and sends a photo to a peer-like target.
pub fn (mut c Client) send_photo[T](peer T, name string, data []u8, options SendPhotoOptions) !SentMessage {
	resolved := c.resolve_peer_like(peer)!
	batch := c.send_photo_updates(resolved, name, data, options)!
	return sent_message_from_updates(c, resolved, batch, options.caption)!
}

// send_photo_updates uploads and sends a photo and returns the raw updates payload.
pub fn (mut c Client) send_photo_updates[T](peer T, name string, data []u8, options SendPhotoOptions) !tl.UpdatesType {
	resolved := c.resolve_peer_like(peer)!
	uploaded := c.upload_file_bytes(name, data, options.upload)!
	return c.send_media_request_updates(resolved.input_peer, tl.InputMediaUploadedPhoto{
		spoiler:               options.spoiler
		file:                  uploaded.input_file
		ttl_seconds:           options.ttl_seconds
		has_stickers_value:    false
		has_ttl_seconds_value: options.has_ttl_seconds_value
	}, options.caption, photo_send_options_to_send_options(options))
}

// send_photo_path reads, uploads, and sends a photo from disk.
pub fn (mut c Client) send_photo_path[T](peer T, path string, options SendPhotoOptions) !SentMessage {
	if path.len == 0 {
		return error('photo path must not be empty')
	}
	name := os.file_name(path)
	if name.len == 0 {
		return error('photo path must include a file name')
	}
	data := os.read_bytes(path)!
	return c.send_photo(peer, name, data, options)!
}

// send_photo_to_username is a convenience wrapper around send_photo for usernames.
pub fn (mut c Client) send_photo_to_username(username string, name string, data []u8, options SendPhotoOptions) !SentMessage {
	return c.send_photo(username, name, data, options)!
}

// send_message_to_username is a convenience wrapper around send_message for usernames.
pub fn (mut c Client) send_message_to_username(username string, message string) !SentMessage {
	return c.send_message(username, message)!
}

// document_file_location converts a document into an input file location.
pub fn document_file_location(document tl.Document, thumb_size string) tl.InputFileLocationType {
	return media.document_file_reference(document, thumb_size).input_location()
}

// photo_file_location converts a photo into an input file location.
pub fn photo_file_location(photo tl.Photo, thumb_size string) tl.InputFileLocationType {
	return media.photo_file_reference(photo, thumb_size).input_location()
}

// document_file_reference builds a reusable file reference from a document.
pub fn document_file_reference(document tl.Document, thumb_size string) media.FileReference {
	return media.document_file_reference(document, thumb_size)
}

// photo_file_reference builds a reusable file reference from a photo.
pub fn photo_file_reference(photo tl.Photo, thumb_size string) media.FileReference {
	return media.photo_file_reference(photo, thumb_size)
}

// download_file_reference downloads a file using a reusable FileReference.
pub fn (mut c Client) download_file_reference(reference media.FileReference, options media.DownloadOptions) !media.DownloadResult {
	return c.download_file(reference.input_location(), options)!
}

// get_file_hashes fetches integrity hashes for a file location at the given offset.
pub fn (mut c Client) get_file_hashes(location tl.InputFileLocationType, offset i64) ![]tl.FileHashType {
	if offset < 0 {
		return error('file hash offset must not be negative')
	}
	result := c.invoke(tl.UploadGetFileHashes{
		location: location
		offset:   offset
	})!
	return expect_file_hashes(result)!
}

// get_cdn_file_hashes fetches integrity hashes for a CDN download token.
pub fn (mut c Client) get_cdn_file_hashes(file_token []u8, offset i64) ![]tl.FileHashType {
	if file_token.len == 0 {
		return error('cdn file token must not be empty')
	}
	if offset < 0 {
		return error('cdn file hash offset must not be negative')
	}
	result := c.invoke(tl.UploadGetCdnFileHashes{
		file_token: file_token.clone()
		offset:     offset
	})!
	return expect_file_hashes(result)!
}

// reupload_cdn_file refreshes expired CDN download hashes.
pub fn (mut c Client) reupload_cdn_file(file_token []u8, request_token []u8) ![]tl.FileHashType {
	if file_token.len == 0 {
		return error('cdn file token must not be empty')
	}
	if request_token.len == 0 {
		return error('cdn request token must not be empty')
	}
	result := c.invoke(tl.UploadReuploadCdnFile{
		file_token:    file_token.clone()
		request_token: request_token.clone()
	})!
	return expect_file_hashes(result)!
}

fn (mut c Client) send_media_request_updates(peer tl.InputPeerType, media_value tl.InputMediaType, caption RichTextInput, options SendOptions) !tl.UpdatesType {
	text := rich_text_from_input(caption)
	resolved_options := normalize_send_options(options)!
	result := c.invoke(tl.MessagesSendMedia{
		peer:                             peer
		silent:                           resolved_options.silent
		reply_to:                         resolved_options.reply_to
		has_reply_to_value:               resolved_options.has_reply_to_value
		media:                            media_value
		message:                          text.text
		random_id:                        c.random_id()!
		reply_markup:                     tl.UnknownReplyMarkupType{}
		has_reply_markup_value:           false
		entities:                         text.entities.clone()
		has_entities_value:               text.entities.len > 0
		schedule_date:                    resolved_options.schedule_date
		has_schedule_date_value:          resolved_options.has_schedule_date_value
		has_schedule_repeat_period_value: false
		send_as:                          tl.InputPeerEmpty{}
		has_send_as_value:                false
		quick_reply_shortcut:             tl.UnknownInputQuickReplyShortcutType{}
		has_quick_reply_shortcut_value:   false
		has_effect_value:                 false
		has_allow_paid_stars_value:       false
		suggested_post:                   tl.UnknownSuggestedPostType{}
		has_suggested_post_value:         false
	})!
	return c.ingest_updates_result(result)!
}

struct NormalizedSendOptions {
	reply_to                tl.InputReplyToType = tl.UnknownInputReplyToType{}
	has_reply_to_value      bool
	silent                  bool
	disable_link_preview    bool
	schedule_date           int
	has_schedule_date_value bool
}

fn normalize_send_options(options SendOptions) !NormalizedSendOptions {
	if options.has_reply_to_message_id_value && options.reply_to_message_id <= 0 {
		return error('reply_to_message_id must be greater than zero')
	}
	if options.has_schedule_date_value && options.schedule_date <= 0 {
		return error('schedule_date must be greater than zero')
	}
	return NormalizedSendOptions{
		reply_to:                if options.has_reply_to_message_id_value {
			tl.InputReplyToType(tl.InputReplyToMessage{
				reply_to_msg_id:   options.reply_to_message_id
				reply_to_peer_id:  tl.InputPeerType(tl.InputPeerEmpty{})
				monoforum_peer_id: tl.InputPeerType(tl.InputPeerEmpty{})
			})
		} else {
			tl.InputReplyToType(tl.UnknownInputReplyToType{})
		}
		has_reply_to_value:      options.has_reply_to_message_id_value
		silent:                  options.silent
		disable_link_preview:    options.disable_link_preview
		schedule_date:           options.schedule_date
		has_schedule_date_value: options.has_schedule_date_value
	}
}

fn file_send_options_to_send_options(options SendFileOptions) SendOptions {
	return SendOptions{
		reply_to_message_id:           options.reply_to_message_id
		has_reply_to_message_id_value: options.has_reply_to_message_id_value
		silent:                        options.silent
		schedule_date:                 options.schedule_date
		has_schedule_date_value:       options.has_schedule_date_value
	}
}

fn photo_send_options_to_send_options(options SendPhotoOptions) SendOptions {
	return SendOptions{
		reply_to_message_id:           options.reply_to_message_id
		has_reply_to_message_id_value: options.has_reply_to_message_id_value
		silent:                        options.silent
		schedule_date:                 options.schedule_date
		has_schedule_date_value:       options.has_schedule_date_value
	}
}

fn (mut c Client) ingest_updates_result(result tl.Object) !tl.UpdatesType {
	batch := expect_updates(result)!
	if c.update_manager.is_initialized() || c.has_event_subscription {
		mut source := RuntimeDifferenceSource{
			runtime: c.runtime
		}
		c.update_manager.ingest(batch, mut source)!
		c.dispatch_pending_event_handlers()!
	}
	return batch
}

fn document_attributes_with_filename(file_name string, attributes []tl.DocumentAttributeType) []tl.DocumentAttributeType {
	mut resolved := []tl.DocumentAttributeType{}
	mut has_filename := false
	for attribute in attributes {
		match attribute {
			tl.DocumentAttributeFilename {
				has_filename = true
			}
			else {}
		}
		resolved << attribute
	}
	if !has_filename {
		mut with_filename := []tl.DocumentAttributeType{}
		with_filename << tl.DocumentAttributeType(tl.DocumentAttributeFilename{
			file_name: file_name
		})
		with_filename << resolved
		return with_filename
	}
	return resolved
}

fn expect_updates(object tl.Object) !tl.UpdatesType {
	match object {
		tl.UpdatesTooLong {
			return object
		}
		tl.UpdateShortMessage {
			return object
		}
		tl.UpdateShortChatMessage {
			return object
		}
		tl.UpdateShort {
			return object
		}
		tl.UpdatesCombined {
			return object
		}
		tl.Updates {
			return object
		}
		tl.UpdateShortSentMessage {
			return object
		}
		else {
			return error('expected Updates, got ${object.qualified_name()}')
		}
	}
}

fn expect_bool_true(object tl.Object, operation string) ! {
	match object {
		tl.BoolTrue {
			return
		}
		tl.BoolFalse {
			return error('${operation} returned Bool.false')
		}
		else {
			return error('expected Bool, got ${object.qualified_name()}')
		}
	}
}

fn expect_file_hashes(object tl.Object) ![]tl.FileHashType {
	match object {
		tl.UnknownObject {
			if object.constructor != tl.vector_constructor_id {
				return error('expected Vector<FileHash>, got ${object.qualified_name()}')
			}
			mut payload := object.encode()!
			mut decoder := tl.new_decoder(payload)
			count := decoder.read_vector_len()!
			mut remaining := decoder.read_remaining()
			mut hashes := []tl.FileHashType{cap: count}
			for _ in 0 .. count {
				item, consumed := tl.decode_object_prefix(remaining)!
				match item {
					tl.FileHash {
						hashes << tl.FileHashType(item)
					}
					tl.UnknownObject {
						hashes << tl.FileHashType(tl.UnknownFileHashType{
							constructor: item.constructor
							name:        item.name
							raw_payload: item.raw_payload.clone()
						})
					}
					else {
						return error('expected FileHash, got ${item.qualified_name()}')
					}
				}
				remaining = remaining[consumed..].clone()
			}
			if remaining.len != 0 {
				return error('unexpected trailing bytes in Vector<FileHash>')
			}
			return hashes
		}
		else {
			return error('expected Vector<FileHash>, got ${object.qualified_name()}')
		}
	}
}
