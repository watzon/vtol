module vtol

import media
import os
import tl

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

pub fn (mut c Client) send_text[T](peer T, message string) !SentMessage {
	resolved := c.resolve_peer_like(peer)!
	batch := c.send_text_updates(resolved, message)!
	return sent_message_from_updates(resolved, batch, message)!
}

pub fn (mut c Client) send_message[T](peer T, message string) !SentMessage {
	return c.send_text(peer, message)!
}

pub fn (mut c Client) send_text_updates[T](peer T, message string) !tl.UpdatesType {
	resolved := c.resolve_peer_like(peer)!
	return c.send_message_updates(resolved.input_peer, message)!
}

pub fn (mut c Client) send_message_updates(peer tl.InputPeerType, message string) !tl.UpdatesType {
	if message.len == 0 {
		return error('message must not be empty')
	}
	result := c.invoke(tl.MessagesSendMessage{
		peer:                           peer
		reply_to:                       tl.UnknownInputReplyToType{}
		has_reply_to_value:             false
		message:                        message
		random_id:                      c.random_id()!
		reply_markup:                   tl.UnknownReplyMarkupType{}
		has_reply_markup_value:         false
		send_as:                        tl.InputPeerEmpty{}
		has_send_as_value:              false
		quick_reply_shortcut:           tl.UnknownInputQuickReplyShortcutType{}
		has_quick_reply_shortcut_value: false
		suggested_post:                 tl.UnknownSuggestedPostType{}
		has_suggested_post_value:       false
	})!
	return c.ingest_updates_result(result)!
}

pub fn (mut c Client) send_file[T](peer T, name string, data []u8, options media.SendFileOptions) !SentMessage {
	resolved := c.resolve_peer_like(peer)!
	batch := c.send_file_updates(resolved, name, data, options)!
	return sent_message_from_updates(resolved, batch, options.caption)!
}

pub fn (mut c Client) send_file_updates[T](peer T, name string, data []u8, options media.SendFileOptions) !tl.UpdatesType {
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
	}, options.caption)
}

pub fn (mut c Client) send_file_path[T](peer T, path string, options media.SendFileOptions) !SentMessage {
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

pub fn (mut c Client) send_file_to_username(username string, name string, data []u8, options media.SendFileOptions) !SentMessage {
	return c.send_file(username, name, data, options)!
}

pub fn (mut c Client) send_photo[T](peer T, name string, data []u8, options media.SendPhotoOptions) !SentMessage {
	resolved := c.resolve_peer_like(peer)!
	batch := c.send_photo_updates(resolved, name, data, options)!
	return sent_message_from_updates(resolved, batch, options.caption)!
}

pub fn (mut c Client) send_photo_updates[T](peer T, name string, data []u8, options media.SendPhotoOptions) !tl.UpdatesType {
	resolved := c.resolve_peer_like(peer)!
	uploaded := c.upload_file_bytes(name, data, options.upload)!
	return c.send_media_request_updates(resolved.input_peer, tl.InputMediaUploadedPhoto{
		spoiler:               options.spoiler
		file:                  uploaded.input_file
		ttl_seconds:           options.ttl_seconds
		has_stickers_value:    false
		has_ttl_seconds_value: options.has_ttl_seconds_value
	}, options.caption)
}

pub fn (mut c Client) send_photo_path[T](peer T, path string, options media.SendPhotoOptions) !SentMessage {
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

pub fn (mut c Client) send_photo_to_username(username string, name string, data []u8, options media.SendPhotoOptions) !SentMessage {
	return c.send_photo(username, name, data, options)!
}

pub fn (mut c Client) send_message_to_username(username string, message string) !SentMessage {
	return c.send_message(username, message)!
}

pub fn document_file_location(document tl.Document, thumb_size string) tl.InputFileLocationType {
	return media.document_file_reference(document, thumb_size).input_location()
}

pub fn photo_file_location(photo tl.Photo, thumb_size string) tl.InputFileLocationType {
	return media.photo_file_reference(photo, thumb_size).input_location()
}

pub fn document_file_reference(document tl.Document, thumb_size string) media.FileReference {
	return media.document_file_reference(document, thumb_size)
}

pub fn photo_file_reference(photo tl.Photo, thumb_size string) media.FileReference {
	return media.photo_file_reference(photo, thumb_size)
}

pub fn (mut c Client) download_file_reference(reference media.FileReference, options media.DownloadOptions) !media.DownloadResult {
	return c.download_file(reference.input_location(), options)!
}

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

fn (mut c Client) send_media_request_updates(peer tl.InputPeerType, media_value tl.InputMediaType, caption string) !tl.UpdatesType {
	result := c.invoke(tl.MessagesSendMedia{
		peer:                             peer
		reply_to:                         tl.UnknownInputReplyToType{}
		has_reply_to_value:               false
		media:                            media_value
		message:                          caption
		random_id:                        c.random_id()!
		reply_markup:                     tl.UnknownReplyMarkupType{}
		has_reply_markup_value:           false
		entities:                         []tl.MessageEntityType{}
		has_entities_value:               false
		has_schedule_date_value:          false
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
