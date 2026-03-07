module example_support

import os
import vtol
import vtol.media
import vtol.rpc
import vtol.tl
import vtol.updates

pub const default_dc_host = '149.154.167.50'
pub const default_session_file = '.vtol.example.session.sqlite'
pub const default_timeout_ms = 30_000

pub struct DownloadTarget {
pub:
	reference    media.FileReference
	default_name string
}

pub fn session_file_from_env() string {
	if value := first_non_empty_env(['VTOL_EXAMPLE_SESSION_FILE']) {
		return value
	}
	return default_session_file
}

pub fn new_client_from_env(session_file string) !vtol.Client {
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
	timeout_ms := env_int([
		'VTOL_EXAMPLE_TIMEOUT_MS',
	], default_timeout_ms)
	return vtol.new_client_with_session_file(vtol.ClientConfig{
		app_id:               app_id
		app_hash:             app_hash
		dc_options:           [
			vtol.DcOption{
				id:   2
				host: dc_host
				port: 443
			},
		]
		default_call_options: rpc.CallOptions{
			timeout_ms: timeout_ms
		}
		test_mode:            env_flag([
			'VTOL_EXAMPLE_TEST_MODE',
			'VTOL_TEST_MODE',
		])
	}, session_file)
}

pub fn require_restored_session(client vtol.Client, session_file string) ! {
	if client.did_restore_session() {
		return
	}
	return error('no saved session was restored from ${session_file}; run examples/auth_basic first')
}

pub fn required_env(keys []string) !string {
	if value := first_non_empty_env(keys) {
		return value
	}
	return error('missing required environment variable: ${keys.join(' or ')}')
}

pub fn first_non_empty_env(keys []string) ?string {
	for key in keys {
		value := os.getenv(key).trim_space()
		if value.len > 0 {
			return value
		}
	}
	return none
}

pub fn env_flag(keys []string) bool {
	if value := first_non_empty_env(keys) {
		normalized := value.to_lower()
		return normalized == '1' || normalized == 'true' || normalized == 'yes'
	}
	return false
}

pub fn env_int(keys []string, fallback int) int {
	if value := first_non_empty_env(keys) {
		parsed := value.int()
		if parsed > 0 {
			return parsed
		}
	}
	return fallback
}

pub fn print_current_user(me tl.UsersUserFullType) {
	match me {
		tl.UsersUserFull {
			if me.users.len == 0 {
				println('getMe: users.userFull')
				return
			}
			user := me.users[0]
			match user {
				tl.User {
					if user.has_username_value && user.username.len > 0 {
						println('getMe: @${user.username}')
						return
					}
					println('getMe: user ${user.id}')
				}
				tl.UserEmpty {
					println('getMe: user ${user.id}')
				}
				else {
					println('getMe: ${user.qualified_name()}')
				}
			}
		}
		else {
			println('getMe: ${me.qualified_name()}')
		}
	}
}

pub fn describe_updates(batch tl.UpdatesType) string {
	return match batch {
		tl.UpdateShortSentMessage {
			'server acknowledged message id ${batch.id}'
		}
		tl.Updates {
			'server returned updates with ${batch.updates.len} event(s)'
		}
		tl.UpdatesCombined {
			'server returned a combined update batch with ${batch.updates.len} event(s)'
		}
		tl.UpdatesTooLong {
			'server returned updatesTooLong'
		}
		else {
			'server returned ${batch.qualified_name()}'
		}
	}
}

pub fn find_download_target(history tl.MessagesMessagesType) !DownloadTarget {
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
								return DownloadTarget{
									reference:    vtol.document_file_reference(*document,
										'')
									default_name: document_file_name(*document)
								}
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
								return DownloadTarget{
									reference:    vtol.photo_file_reference(*photo, '')
									default_name: 'photo_${photo.id}.jpg'
								}
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

pub fn receive_event(subscription updates.Subscription) ?updates.Event {
	select {
		event := <-subscription.events {
			return event
		}
		else {
			return none
		}
	}
	return none
}

pub fn describe_event(event updates.Event) string {
	state := 'pts=${event.state.pts} qts=${event.state.qts} seq=${event.state.seq}'
	return match event.kind {
		.live {
			'live update: ${describe_live_batch(event.batch)} (${state})'
		}
		.recovered {
			'recovered updates: ${describe_difference(event.difference)} (${state})'
		}
	}
}

fn messages_from_history(history tl.MessagesMessagesType) []tl.MessageType {
	return match history {
		tl.MessagesMessages {
			history.messages.clone()
		}
		tl.MessagesMessagesSlice {
			history.messages.clone()
		}
		tl.MessagesChannelMessages {
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

fn describe_live_batch(batch tl.UpdatesType) string {
	return match batch {
		tl.UpdateShortSentMessage {
			'updateShortSentMessage id ${batch.id}'
		}
		tl.UpdateShortMessage {
			'updateShortMessage id ${batch.id}'
		}
		tl.UpdateShortChatMessage {
			'updateShortChatMessage id ${batch.id}'
		}
		tl.UpdateShort {
			batch.update.qualified_name()
		}
		tl.Updates {
			'${batch.updates.len} update(s)'
		}
		tl.UpdatesCombined {
			'${batch.updates.len} combined update(s)'
		}
		tl.UpdatesTooLong {
			'updatesTooLong'
		}
		else {
			batch.qualified_name()
		}
	}
}

fn describe_difference(difference tl.UpdatesDifferenceType) string {
	return match difference {
		tl.UpdatesDifference {
			'${difference.new_messages.len + difference.other_updates.len} recovered item(s)'
		}
		tl.UpdatesDifferenceSlice {
			'${difference.new_messages.len + difference.other_updates.len} recovered slice item(s)'
		}
		tl.UpdatesDifferenceEmpty {
			'empty difference'
		}
		tl.UpdatesDifferenceTooLong {
			'difference too long'
		}
		else {
			difference.qualified_name()
		}
	}
}
