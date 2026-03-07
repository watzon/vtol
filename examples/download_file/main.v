module main

import media
import os
import tl
import vtol

const default_dc_host = '149.154.167.50'
const default_session_file = '.vtol.example.session.json'
const default_history_limit = 50

struct StdoutProgressReporter {}

fn (r StdoutProgressReporter) report(progress media.TransferProgress) {
	if progress.total > 0 {
		println('downloaded ${progress.transferred}/${progress.total} bytes (part ${
			progress.part_index + 1}/${progress.total_parts})')
		return
	}
	println('downloaded ${progress.transferred} bytes (part ${progress.part_index + 1}/${progress.total_parts})')
}

fn main() {
	run() or {
		eprintln('download_file: ${err}')
		exit(1)
	}
}

fn run() ! {
	session_file := first_non_empty_env([
		'VTOL_EXAMPLE_SESSION_FILE',
	]) or { default_session_file }
	peer_key := first_non_empty_env([
		'VTOL_EXAMPLE_PEER',
	]) or { 'me' }
	output_path := first_non_empty_env([
		'VTOL_EXAMPLE_OUTPUT',
	]) or { '' }
	history_limit := env_int('VTOL_EXAMPLE_HISTORY_LIMIT', default_history_limit)

	mut client := new_example_client(session_file)!
	defer {
		client.disconnect() or {}
	}

	client.connect()!
	if !client.did_restore_session() {
		return error('no saved session was restored from ${session_file}; run examples/auth_basic first')
	}

	peer := client.resolve_input_peer(peer_key)!
	history := client.get_history(peer, history_limit)!
	reference, default_name := find_download_target(history)!
	target_path := if output_path.len > 0 { output_path } else { default_name }
	parent_dir := os.dir(target_path)
	if parent_dir.len > 0 && parent_dir != '.' {
		os.mkdir_all(parent_dir)!
	}

	result := client.download_file_reference(reference, media.DownloadOptions{
		part_size:     64 * 1024
		cdn_supported: false
		reporter:      StdoutProgressReporter{}
	})!
	if result.has_cdn_redirect {
		return error('download was redirected to a CDN; rerun with a different message or media type')
	}

	os.write_file_array(target_path, result.bytes)!
	println('wrote ${result.bytes.len} bytes to ${target_path}')
}

fn find_download_target(history tl.MessagesMessagesType) !(media.FileReference, string) {
	for message in messages_from_history(history) {
		match message {
			tl.Message {
				if !message.has_media_value {
					continue
				}
				match message.media {
					tl.MessageMediaDocument {
						if !message.media.has_document_value {
							continue
						}
						document := message.media.document
						match document {
							tl.Document {
								name := document_file_name(document)
								return vtol.document_file_reference(document, ''), name
							}
							else {}
						}
					}
					tl.MessageMediaPhoto {
						if !message.media.has_photo_value {
							continue
						}
						photo := message.media.photo
						match photo {
							tl.Photo {
								return vtol.photo_file_reference(photo, ''), 'photo_${photo.id}.jpg'
							}
							else {}
						}
					}
					else {}
				}
			}
			else {}
		}
	}
	return error('no photo or document was found in the recent message history')
}

fn messages_from_history(history tl.MessagesMessagesType) []tl.MessageType {
	return match history {
		tl.MessagesMessages {
			history.messages.clone()
		}
		tl.MessagesMessagesSlice {
			history.messages.clone()
		}
		tl.MessagesMessagesNotModified {
			[]tl.MessageType{}
		}
		else {
			[]tl.MessageType{}
		}
	}
}

fn document_file_name(document tl.Document) string {
	for attribute in document.attributes {
		match attribute {
			tl.DocumentAttributeFilename {
				if attribute.file_name.len > 0 {
					return os.file_name(attribute.file_name)
				}
			}
			else {}
		}
	}
	return 'document_${document.id}.bin'
}

fn new_example_client(session_file string) !vtol.Client {
	app_id := required_env([
		'VTOL_EXAMPLE_API_ID',
		'VTOL_TEST_API_ID',
	])!.int()
	app_hash := required_env([
		'VTOL_EXAMPLE_API_HASH',
		'VTOL_TEST_API_HASH',
	])!
	dc_host := first_non_empty_env([
		'VTOL_EXAMPLE_DC_HOST',
		'VTOL_TEST_DC_HOST',
	]) or { default_dc_host }
	return vtol.new_client_with_session_file(vtol.ClientConfig{
		app_id:     app_id
		app_hash:   app_hash
		dc_options: [
			vtol.DcOption{
				id:   2
				host: dc_host
				port: 443
			},
		]
		test_mode:  env_flag([
			'VTOL_EXAMPLE_TEST_MODE',
			'VTOL_TEST_MODE',
		])
	}, session_file)
}

fn required_env(keys []string) !string {
	if value := first_non_empty_env(keys) {
		return value
	}
	return error('missing required environment variable: ${keys.join(' or ')}')
}

fn first_non_empty_env(keys []string) ?string {
	for key in keys {
		value := os.getenv(key).trim_space()
		if value.len > 0 {
			return value
		}
	}
	return none
}

fn env_flag(keys []string) bool {
	if value := first_non_empty_env(keys) {
		normalized := value.to_lower()
		return normalized == '1' || normalized == 'true' || normalized == 'yes'
	}
	return false
}

fn env_int(key string, fallback int) int {
	value := os.getenv(key).trim_space()
	if value.len == 0 {
		return fallback
	}
	parsed := value.int()
	if parsed <= 0 {
		return fallback
	}
	return parsed
}
