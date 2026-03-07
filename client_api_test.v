module vtol

import rpc
import session
import tl

@[heap]
struct FakeRuntimeState {
mut:
	connect_calls    int
	disconnect_calls int
	connected        bool
	invocations      []string
	functions        []tl.Function
	responses        []tl.Object
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
				current_algo:           tl.UnknownPasswordKdfAlgoType{}
				new_algo:               tl.UnknownPasswordKdfAlgoType{}
				new_secure_algo:        tl.UnknownSecurePasswordKdfAlgoType{}
				secure_random:          []u8{}
				has_password:           false
				has_current_algo_value: false
				has_srp_b_value:        false
				has_srp_id_value:       false
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

	password := client.get_password_challenge() or { panic(err) }
	match password {
		tl.AccountPassword {
			assert !password.has_password
		}
		else {
			assert false
		}
	}

	_ = client.check_password(tl.UnknownInputCheckPasswordSRPType{}) or { panic(err) }
	_ = client.login_bot('123:bot-token') or { panic(err) }

	assert state.connect_calls == 1
	assert state.invocations == [
		'auth.sendCode',
		'auth.signIn',
		'account.getPassword',
		'auth.checkPassword',
		'auth.importBotAuthorization',
	]

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
