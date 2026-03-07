module vtol

import encoding.hex
import media
import rpc
import session
import tl
import updates

@[heap]
struct FakeRuntimeState {
mut:
	connect_calls    int
	disconnect_calls int
	pump_calls       int
	connected        bool
	invocations      []string
	functions        []tl.Function
	responses        []tl.Object
	update_batches   []tl.UpdatesType
}

struct FakeRuntime {
mut:
	state &FakeRuntimeState
}

fn (f FakeRuntime) is_connected() bool {
	return f.state.connected
}

fn (f FakeRuntime) session_state() session.SessionState {
	return session.SessionState{
		dc_id:       2
		session_id:  99
		auth_key:    []u8{len: 256, init: u8(1)}
		auth_key_id: 77
	}
}

fn (mut f FakeRuntime) connect() ! {
	f.state.connect_calls++
	f.state.connected = true
}

fn (mut f FakeRuntime) disconnect() ! {
	f.state.disconnect_calls++
	f.state.connected = false
}

fn (mut f FakeRuntime) invoke(function tl.Function, options rpc.CallOptions) !tl.Object {
	f.state.invocations << function.method_name()
	f.state.functions << function
	if f.state.responses.len == 0 {
		return error('no fake response queued for ${function.method_name()}')
	}
	response := f.state.responses[0]
	f.state.responses = f.state.responses[1..].clone()
	return response
}

fn (mut f FakeRuntime) pump_once() ! {
	f.state.pump_calls++
}

fn (mut f FakeRuntime) drain_updates() []tl.UpdatesType {
	if f.state.update_batches.len == 0 {
		return []tl.UpdatesType{}
	}
	batches := f.state.update_batches.clone()
	f.state.update_batches = []tl.UpdatesType{}
	return batches
}

@[heap]
struct ProgressState {
mut:
	events []media.TransferProgress
}

struct RecordingProgressReporter {
mut:
	state &ProgressState
}

fn (r RecordingProgressReporter) report(progress media.TransferProgress) {
	unsafe {
		r.state.events << progress
	}
}

fn test_client_connect_and_disconnect_use_runtime_state() {
	mut state := &FakeRuntimeState{}
	mut client := new_fake_client(state)

	client.connect() or { panic(err) }
	assert client.client_state() == .connected
	assert state.connect_calls == 1
	assert client.is_connected()

	client.disconnect() or { panic(err) }
	assert client.client_state() == .disconnected
	assert state.disconnect_calls == 1
	assert !client.is_connected()
}

fn test_login_wrappers_delegate_to_generated_auth_methods() {
	mut state := &FakeRuntimeState{
		responses: [
			tl.Object(tl.AuthSentCode{
				type_value:          tl.AuthSentCodeTypeApp{
					length: 6
				}
				next_type:           tl.UnknownAuthCodeTypeType{}
				has_next_type_value: false
				phone_code_hash:     'code-hash'
			}),
			tl.Object(tl.AuthAuthorization{
				user: make_test_user('alice', 42, 77)
			}),
			tl.Object(tl.AccountPassword{
				current_algo:           srp_password_algo()
				new_algo:               tl.UnknownPasswordKdfAlgoType{}
				new_secure_algo:        tl.UnknownSecurePasswordKdfAlgoType{}
				secure_random:          []u8{}
				has_password:           true
				has_current_algo_value: true
				srp_b:                  srp_b_bytes()
				has_srp_b_value:        true
				srp_id:                 77
				has_srp_id_value:       true
			}),
			tl.Object(tl.AuthAuthorization{
				user: make_test_user('alice', 42, 77)
			}),
			tl.Object(tl.AuthAuthorization{
				user: tl.User{
					bot:                      true
					id:                       99
					access_hash:              88
					has_access_hash_value:    true
					photo:                    tl.UnknownUserProfilePhotoType{}
					has_photo_value:          false
					status:                   tl.UnknownUserStatusType{}
					has_status_value:         false
					emoji_status:             tl.UnknownEmojiStatusType{}
					has_emoji_status_value:   false
					stories_max_id:           tl.UnknownRecentStoryType{}
					has_stories_max_id_value: false
					color:                    tl.UnknownPeerColorType{}
					has_color_value:          false
					profile_color:            tl.UnknownPeerColorType{}
					has_profile_color_value:  false
				}
			}),
		]
	}
	mut client := new_fake_client(state)

	request := client.send_login_code('+15551234567') or { panic(err) }
	assert request.phone_code_hash == 'code-hash'

	authorization := client.sign_in_code(request, '123456') or { panic(err) }
	match authorization {
		tl.AuthAuthorization {
			match authorization.user {
				tl.User {
					assert authorization.user.id == 42
				}
				else {
					assert false
				}
			}
		}
		else {
			assert false
		}
	}

	_ = client.sign_in_password('123123') or { panic(err) }
	_ = client.login_bot('123:bot-token') or { panic(err) }

	assert state.connect_calls == 1
	assert state.invocations == [
		'auth.sendCode',
		'auth.signIn',
		'account.getPassword',
		'auth.checkPassword',
		'auth.importBotAuthorization',
	]

	password_call := state.functions[3]
	match password_call {
		tl.AuthCheckPassword {
			match password_call.password {
				tl.InputCheckPasswordSRP {
					assert password_call.password.a.len == 256
					assert password_call.password.m1.len == 32
				}
				else {
					assert false
				}
			}
		}
		else {
			assert false
		}
	}

	if peer := client.cached_input_peer('alice') {
		match peer {
			tl.InputPeerSelf {
				assert true
			}
			else {
				assert false
			}
		}
	} else {
		assert false
	}
}

fn test_password_check_matches_reference_srp_vector() {
	password_check := password_check_from_account_with_random('123123', tl.AccountPassword{
		has_password:           true
		current_algo:           srp_password_algo()
		has_current_algo_value: true
		srp_b:                  srp_b_bytes()
		has_srp_b_value:        true
		srp_id:                 99
		has_srp_id_value:       true
		new_algo:               tl.UnknownPasswordKdfAlgoType{}
		new_secure_algo:        tl.UnknownSecurePasswordKdfAlgoType{}
		secure_random:          []u8{}
	}, srp_random_bytes()) or { panic(err) }

	assert password_check.a == srp_expected_a_bytes()
	assert hex.encode(password_check.m1).to_upper() == test_srp_expected_m1_hex
}

fn test_resolve_username_caches_peer_and_send_message_reuses_cache() {
	mut state := &FakeRuntimeState{
		responses: [
			tl.Object(tl.ContactsResolvedPeer{
				peer:  tl.PeerUser{
					user_id: 42
				}
				users: [
					tl.UserType(make_test_user('alice', 42, 77)),
				]
				chats: []tl.ChatType{}
			}),
			tl.Object(tl.UpdateShortSentMessage{
				id:              7
				pts:             1
				pts_count:       1
				date:            123
				media:           tl.UnknownMessageMediaType{}
				has_media_value: false
			}),
		]
	}
	mut client := new_fake_client(state)

	peer := client.resolve_input_peer('@Alice') or { panic(err) }
	match peer {
		tl.InputPeerUser {
			assert peer.user_id == 42
			assert peer.access_hash == 77
		}
		else {
			assert false
		}
	}

	peer_again := client.resolve_input_peer('alice') or { panic(err) }
	match peer_again {
		tl.InputPeerUser {
			assert peer_again.user_id == 42
			assert peer_again.access_hash == 77
		}
		else {
			assert false
		}
	}

	_ = client.send_message_to_username('alice', 'hello from cache') or { panic(err) }

	assert state.invocations == [
		'contacts.resolveUsername',
		'messages.sendMessage',
	]

	sent := state.functions[1]
	match sent {
		tl.MessagesSendMessage {
			assert sent.message == 'hello from cache'
			match sent.peer {
				tl.InputPeerUser {
					assert sent.peer.user_id == 42
					assert sent.peer.access_hash == 77
				}
				else {
					assert false
				}
			}
		}
		else {
			assert false
		}
	}
}

fn test_core_wrappers_delegate_to_tl_methods() {
	mut state := &FakeRuntimeState{
		responses: [
			tl.Object(tl.UsersUserFull{
				full_user: tl.UnknownUserFullType{}
				chats:     []tl.ChatType{}
				users:     []tl.UserType{}
			}),
			tl.Object(tl.MessagesDialogsNotModified{
				count: 0
			}),
			tl.Object(tl.MessagesChats{
				chats: []tl.ChatType{}
			}),
			tl.Object(tl.MessagesMessages{
				messages: []tl.MessageType{}
				topics:   []tl.ForumTopicType{}
				chats:    []tl.ChatType{}
				users:    []tl.UserType{}
			}),
		]
	}
	mut client := new_fake_client(state)

	_ = client.get_me() or { panic(err) }
	_ = client.get_dialogs(25) or { panic(err) }
	_ = client.get_chats([10, 20]) or { panic(err) }
	_ = client.get_history(tl.InputPeerSelf{}, 10) or { panic(err) }

	assert state.connect_calls == 1
	assert state.invocations == [
		'users.getFullUser',
		'messages.getDialogs',
		'messages.getChats',
		'messages.getHistory',
	]
}

fn test_client_subscribe_and_pump_updates_tracks_state() {
	mut state := &FakeRuntimeState{
		responses:      [
			tl.Object(tl.UpdatesState{
				pts:          0
				qts:          0
				date:         100
				seq:          0
				unread_count: 0
			}),
		]
		update_batches: [
			tl.UpdatesType(tl.UpdateShortSentMessage{
				id:              7
				pts:             1
				pts_count:       1
				date:            101
				media:           tl.UnknownMessageMediaType{}
				has_media_value: false
			}),
		]
	}
	mut client := new_fake_client(state)

	subscription := client.subscribe_updates(updates.SubscriptionConfig{
		buffer_size: 1
	}) or { panic(err) }
	client.pump_updates_once() or { panic(err) }

	event := receive_event(subscription) or { panic(err) }
	assert event.kind == .live
	assert state.pump_calls == 1

	if current := client.update_state() {
		assert current.pts == 1
		assert current.date == 101
	} else {
		assert false
	}
}

fn test_client_pump_updates_recovers_after_transport_failure() {
	mut state := &FakeRuntimeState{
		responses: [
			tl.Object(tl.UpdatesState{
				pts:          1
				qts:          0
				date:         100
				seq:          0
				unread_count: 0
			}),
			tl.Object(tl.UpdatesDifference{
				new_messages:           []tl.MessageType{}
				new_encrypted_messages: []tl.EncryptedMessageType{}
				other_updates:          [
					tl.UpdateType(tl.UpdateEditMessage{
						message:   tl.UnknownMessageType{}
						pts:       2
						pts_count: 1
					}),
				]
				chats:                  []tl.ChatType{}
				users:                  []tl.UserType{}
				state:                  tl.UpdatesState{
					pts:          2
					qts:          0
					date:         101
					seq:          0
					unread_count: 0
				}
			}),
		]
	}
	mut client := new_fake_client(state)
	_ = client.subscribe_updates(updates.SubscriptionConfig{}) or { panic(err) }
	state.connected = true
	client.runtime = FailingPumpRuntime{
		state: state
	}

	client.pump_updates_once() or { panic(err) }

	assert state.disconnect_calls == 1
	assert state.connect_calls == 2

	if current := client.update_state() {
		assert current.pts == 2
		assert current.date == 101
	} else {
		assert false
	}
}

fn test_upload_file_bytes_reports_progress_and_returns_input_file() {
	payload := []u8{len: 5000, init: u8((index % 251) + 1)}
	mut progress := &ProgressState{}
	mut state := &FakeRuntimeState{
		responses: [
			tl.Object(tl.BoolTrue{}),
			tl.Object(tl.BoolTrue{}),
		]
	}
	mut client := new_fake_client(state)

	uploaded := client.upload_file_bytes('hello.txt', payload, media.UploadOptions{
		part_size: 4096
		reporter:  RecordingProgressReporter{
			state: progress
		}
	}) or { panic(err) }

	assert state.invocations == ['upload.saveFilePart', 'upload.saveFilePart']
	assert progress.events.len == 3
	assert progress.events[0].transferred == 0
	assert progress.events[1].transferred == 4096
	assert progress.events[2].transferred == u64(payload.len)
	assert uploaded.total_parts == 2
	assert uploaded.part_size == 4096
	match uploaded.input_file {
		tl.InputFile {
			assert uploaded.input_file.name == 'hello.txt'
			assert uploaded.input_file.parts == 2
			assert uploaded.input_file.md5_checksum.len == 32
		}
		else {
			assert false
		}
	}

	first_upload_call := state.functions[0]
	match first_upload_call {
		tl.UploadSaveFilePart {
			assert first_upload_call.file_part == 0
			assert first_upload_call.bytes.len == 4096
		}
		else {
			assert false
		}
	}

	second_upload_call := state.functions[1]
	match second_upload_call {
		tl.UploadSaveFilePart {
			assert second_upload_call.file_part == 1
			assert second_upload_call.bytes.len == 904
		}
		else {
			assert false
		}
	}
}

fn test_upload_file_bytes_resume_skips_uploaded_parts() {
	payload := []u8{len: 5000, init: u8((index % 251) + 1)}
	mut state := &FakeRuntimeState{
		responses: [
			tl.Object(tl.BoolTrue{}),
		]
	}
	mut client := new_fake_client(state)

	uploaded := client.upload_file_bytes('resume.bin', payload, media.UploadOptions{
		part_size:   4096
		resume_part: 1
		file_id:     42
	}) or { panic(err) }

	assert state.invocations == ['upload.saveFilePart']
	assert uploaded.resume_part == 1
	assert uploaded.file_id == 42
	resume_call := state.functions[0]
	match resume_call {
		tl.UploadSaveFilePart {
			assert resume_call.file_part == 1
		}
		else {
			assert false
		}
	}
}

fn test_send_file_uploads_document_and_uses_messages_send_media() {
	payload := []u8{len: 5000, init: u8((index % 251) + 1)}
	mut state := &FakeRuntimeState{
		responses: [
			tl.Object(tl.BoolTrue{}),
			tl.Object(tl.BoolTrue{}),
			tl.Object(tl.UpdateShortSentMessage{
				id:              9
				pts:             1
				pts_count:       1
				date:            123
				media:           tl.UnknownMessageMediaType{}
				has_media_value: false
			}),
		]
	}
	mut client := new_fake_client(state)

	_ = client.send_file(tl.InputPeerSelf{}, 'report.txt', payload, media.SendFileOptions{
		upload:    media.UploadOptions{
			part_size: 4096
		}
		caption:   'quarterly report'
		mime_type: 'text/plain'
	}) or { panic(err) }

	assert state.invocations == ['upload.saveFilePart', 'upload.saveFilePart', 'messages.sendMedia']
	send_media_call := state.functions[2]
	match send_media_call {
		tl.MessagesSendMedia {
			assert send_media_call.message == 'quarterly report'
			match send_media_call.media {
				tl.InputMediaUploadedDocument {
					assert send_media_call.media.mime_type == 'text/plain'
					assert send_media_call.media.force_file
					assert send_media_call.media.attributes.len == 1
					first_attribute := send_media_call.media.attributes[0]
					match first_attribute {
						tl.DocumentAttributeFilename {
							assert first_attribute.file_name == 'report.txt'
						}
						else {
							assert false
						}
					}
				}
				else {
					assert false
				}
			}
		}
		else {
			assert false
		}
	}
}

fn test_send_photo_uses_uploaded_photo_media() {
	payload := []u8{len: 5000, init: u8((index % 251) + 1)}
	mut state := &FakeRuntimeState{
		responses: [
			tl.Object(tl.BoolTrue{}),
			tl.Object(tl.BoolTrue{}),
			tl.Object(tl.UpdateShortSentMessage{
				id:              10
				pts:             1
				pts_count:       1
				date:            123
				media:           tl.UnknownMessageMediaType{}
				has_media_value: false
			}),
		]
	}
	mut client := new_fake_client(state)

	_ = client.send_photo(tl.InputPeerSelf{}, 'photo.jpg', payload, media.SendPhotoOptions{
		upload:                media.UploadOptions{
			part_size: 4096
		}
		caption:               'cover'
		spoiler:               true
		ttl_seconds:           60
		has_ttl_seconds_value: true
	}) or { panic(err) }

	assert state.invocations == ['upload.saveFilePart', 'upload.saveFilePart', 'messages.sendMedia']
	send_photo_call := state.functions[2]
	match send_photo_call {
		tl.MessagesSendMedia {
			match send_photo_call.media {
				tl.InputMediaUploadedPhoto {
					assert send_photo_call.message == 'cover'
					assert send_photo_call.media.spoiler
					assert send_photo_call.media.ttl_seconds == 60
					assert send_photo_call.media.has_ttl_seconds_value
				}
				else {
					assert false
				}
			}
		}
		else {
			assert false
		}
	}
}

fn test_download_file_collects_chunks_with_resume_progress() {
	mut progress := &ProgressState{}
	first_chunk := []u8{len: 4096, init: u8((index % 251) + 1)}
	mut state := &FakeRuntimeState{
		responses: [
			tl.Object(tl.UploadFile{
				type_value: tl.StorageFileUnknown{}
				mtime:      0
				bytes:      first_chunk
			}),
			tl.Object(tl.UploadFile{
				type_value: tl.StorageFileUnknown{}
				mtime:      0
				bytes:      [u8(5)]
			}),
		]
	}
	mut client := new_fake_client(state)

	result := client.download_file(tl.InputDocumentFileLocation{
		id:             7
		access_hash:    9
		file_reference: [u8(1), 2]
		thumb_size:     ''
	}, media.DownloadOptions{
		part_size: 4096
		reporter:  RecordingProgressReporter{
			state: progress
		}
	}) or { panic(err) }

	assert result.completed
	assert !result.has_cdn_redirect
	assert result.bytes.len == 4097
	assert result.bytes[..4] == first_chunk[..4]
	assert result.bytes[4096] == u8(5)
	assert result.start_offset == 0
	assert result.end_offset == 4097
	assert progress.events.len == 2
	assert progress.events[0].transferred == 4096
	assert progress.events[1].transferred == 4097
	assert state.invocations == ['upload.getFile', 'upload.getFile']

	first_download_call := state.functions[0]
	match first_download_call {
		tl.UploadGetFile {
			assert first_download_call.offset == 0
			assert first_download_call.limit == 4096
		}
		else {
			assert false
		}
	}

	second_download_call := state.functions[1]
	match second_download_call {
		tl.UploadGetFile {
			assert second_download_call.offset == 4096
			assert second_download_call.limit == 4096
		}
		else {
			assert false
		}
	}
}

fn test_download_file_returns_cdn_redirect_metadata() {
	mut state := &FakeRuntimeState{
		responses: [
			tl.Object(tl.UploadFileCdnRedirect{
				dc_id:          5
				file_token:     [u8(1), 2, 3]
				encryption_key: [u8(4), 5]
				encryption_iv:  [u8(6), 7]
				file_hashes:    [
					tl.FileHashType(tl.FileHash{
						offset: 0
						limit:  4096
						hash:   [u8(9)]
					}),
				]
			}),
		]
	}
	mut client := new_fake_client(state)

	result := client.download_file(tl.InputPhotoFileLocation{
		id:             8
		access_hash:    10
		file_reference: [u8(3), 4]
		thumb_size:     'm'
	}, media.DownloadOptions{
		part_size: 4096
	}) or { panic(err) }

	assert !result.completed
	assert result.has_cdn_redirect
	assert result.cdn_redirect.dc_id == 5
	assert result.cdn_redirect.file_token == [u8(1), 2, 3]
	assert result.cdn_redirect.file_hashes.len == 1
	assert state.invocations == ['upload.getFile']
}

fn new_fake_client(state &FakeRuntimeState) Client {
	mut client := new_client(ClientConfig{
		app_id:     1
		app_hash:   'test-hash'
		dc_options: [
			DcOption{
				id:   2
				host: '149.154.167.50'
				port: 443
			},
		]
	}) or { panic(err) }
	client.runtime = FakeRuntime{
		state: state
	}
	client.runtime_ready = true
	return client
}

fn receive_event(subscription updates.Subscription) ?updates.Event {
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

struct FailingPumpRuntime {
mut:
	state &FakeRuntimeState
}

fn (f FailingPumpRuntime) is_connected() bool {
	return f.state.connected
}

fn (f FailingPumpRuntime) session_state() session.SessionState {
	return FakeRuntime{
		state: f.state
	}.session_state()
}

fn (mut f FailingPumpRuntime) connect() ! {
	f.state.connect_calls++
	f.state.connected = true
}

fn (mut f FailingPumpRuntime) disconnect() ! {
	f.state.disconnect_calls++
	f.state.connected = false
}

fn (mut f FailingPumpRuntime) invoke(function tl.Function, options rpc.CallOptions) !tl.Object {
	mut runtime := FakeRuntime{
		state: f.state
	}
	return runtime.invoke(function, options)
}

fn (mut f FailingPumpRuntime) pump_once() ! {
	f.state.pump_calls++
	return error('simulated transport failure')
}

fn (mut f FailingPumpRuntime) drain_updates() []tl.UpdatesType {
	return []tl.UpdatesType{}
}

fn make_test_user(username string, id i64, access_hash i64) tl.User {
	return tl.User{
		id:                       id
		access_hash:              access_hash
		has_access_hash_value:    true
		username:                 username
		has_username_value:       true
		photo:                    tl.UnknownUserProfilePhotoType{}
		has_photo_value:          false
		status:                   tl.UnknownUserStatusType{}
		has_status_value:         false
		emoji_status:             tl.UnknownEmojiStatusType{}
		has_emoji_status_value:   false
		stories_max_id:           tl.UnknownRecentStoryType{}
		has_stories_max_id_value: false
		color:                    tl.UnknownPeerColorType{}
		has_color_value:          false
		profile_color:            tl.UnknownPeerColorType{}
		has_profile_color_value:  false
	}
}

const test_srp_expected_m1_hex = '999DF906BDA2C6CBB52F503406EBA2D0D0503ACE0CC302C38F13EE5010AD4051'

fn srp_password_algo() tl.PasswordKdfAlgoSHA256SHA256PBKDF2HMACSHA512iter100000SHA256ModPow {
	return tl.PasswordKdfAlgoSHA256SHA256PBKDF2HMACSHA512iter100000SHA256ModPow{
		salt1: decode_hex('4D11FB6BEC38F9D2546BB0F61E4F1C99A1BC0DB8F0D5F35B1291B37B213123D7ED48F3C6794D495B')
		salt2: decode_hex('A1B181AAFE88188680AE32860D60BB01')
		g:     3
		p:     decode_hex('C71CAEB9C6B1C9048E6C522F70F13F73980D40238E3E21C14934D037563D930F48198A0AA7C14058229493D22530F4DBFA336F6E0AC925139543AED44CCE7C3720FD51F69458705AC68CD4FE6B6B13ABDC9746512969328454F18FAF8C595F642477FE96BB2A941D5BCD1D4AC8CC49880708FA9B378E3C4F3A9060BEE67CF9A4A4A695811051907E162753B56B0F6B410DBA74D8A84B2A14B3144E0EF1284754FD17ED950D5965B4B9DD46582DB1178D169C6BC465B0D6FF9CA3928FEF5B9AE4E418FC15E83EBEA0F87FA9FF5EED70050DED2849F47BF959D956850CE929851F0D8115F635B105EE2E4E15D04B2454BF6F4FADF034B10403119CD8E3B92FCC5B')
	}
}

fn srp_b_bytes() []u8 {
	return decode_hex('9C52401A6A8084EC82F01C3725D3FB448BD2F0C909F9D97726EAC4B7A74172D952F02466BE6734FA274D2B7429E27397F10372D66B400B80A5C5AE3F28B17BF3105D7A2D2A885998CDC2DEFC208AEC217AB58859A9ABC2374AD93DC285F4B3FBCAFF4143D7888F2425BD2FB711B25609CEB21757D935B1EF2F042173AD0CE2FE0E474DAC53914BD25A8A9AED4AEA8953D55CB88621DB37B871EA0D04393AC0987F68094CCC9DE8239251375D8FFFD263316CD528C097B7BC9FB919FBEDB76C525DF3413C374EE076D97A1E6D352BB7CC80FD13651B04B32E2E48C5268150842CFD07CF855958B1B5EA9C36FDAD697FE3AEC8DCC6B1EFEC36874AF226204676CF')
}

fn srp_random_bytes() []u8 {
	mut out := []u8{len: 256}
	out[255] = 1
	return out
}

fn srp_expected_a_bytes() []u8 {
	mut out := []u8{len: 256}
	out[255] = 3
	return out
}

fn decode_hex(value string) []u8 {
	return hex.decode(value) or { panic(err) }
}
