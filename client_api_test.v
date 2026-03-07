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
	errors           map[int]IError
	update_batches   []tl.UpdatesType
}

struct FakeRuntime {
mut:
	state &FakeRuntimeState
}

struct ErrorRuntime {}

fn (f FakeRuntime) is_connected() bool {
	return f.state.connected
}

fn (e ErrorRuntime) is_connected() bool {
	return true
}

fn (f FakeRuntime) session_state() session.SessionState {
	return session.SessionState{
		dc_id:       2
		session_id:  99
		auth_key:    []u8{len: 256, init: u8(1)}
		auth_key_id: 77
	}
}

fn (e ErrorRuntime) session_state() session.SessionState {
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

fn (mut e ErrorRuntime) connect() ! {}

fn (mut f FakeRuntime) disconnect() ! {
	f.state.disconnect_calls++
	f.state.connected = false
}

fn (mut e ErrorRuntime) disconnect() ! {}

fn (mut f FakeRuntime) invoke(function tl.Function, options rpc.CallOptions) !tl.Object {
	leaf_function := unwrap_client_function(function)
	invocation_index := f.state.invocations.len
	f.state.invocations << leaf_function.method_name()
	f.state.functions << leaf_function
	if invocation_index in f.state.errors {
		return f.state.errors[invocation_index]
	}
	if f.state.responses.len == 0 {
		return error('no fake response queued for ${leaf_function.method_name()}')
	}
	response := f.state.responses[0]
	f.state.responses = f.state.responses[1..].clone()
	return response
}

fn (mut e ErrorRuntime) invoke(function tl.Function, options rpc.CallOptions) !tl.Object {
	return IError(rpc.new_rpc_error(tl.RpcError{
		error_code:    420
		error_message: 'FLOOD_WAIT_7'
	}))
}

fn (mut f FakeRuntime) pump_once() ! {
	f.state.pump_calls++
}

fn (mut e ErrorRuntime) pump_once() ! {}

fn (mut f FakeRuntime) drain_updates() []tl.UpdatesType {
	if f.state.update_batches.len == 0 {
		return []tl.UpdatesType{}
	}
	batches := f.state.update_batches.clone()
	f.state.update_batches = []tl.UpdatesType{}
	return batches
}

fn (mut e ErrorRuntime) drain_updates() []tl.UpdatesType {
	return []tl.UpdatesType{}
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

fn test_client_wraps_rate_limit_errors_with_public_metadata() {
	mut client := Client{
		config:         ClientConfig{
			app_id:     1
			app_hash:   'test-hash'
			dc_options: [
				DcOption{
					id:   2
					host: '149.154.167.50'
					port: 443
				},
			]
		}
		runtime:        ErrorRuntime{}
		runtime_ready:  true
		state:          .connected
		store:          session.new_memory_store()
		peer_cache:     map[string]CachedPeer{}
		update_manager: updates.new_manager(updates.ManagerConfig{})
	}

	client.invoke(tl.Ping{
		ping_id: 1
	}) or {
		if err is RpcError {
			assert err.rpc_code == 420
			assert err.is_rate_limited()
			assert err.wait_seconds == 7
			assert err.retry_after_ms() == 7_000
			assert err.raw.error_message == 'FLOOD_WAIT_7'
			return
		}
		assert false
	}
	assert false
}

fn test_refresh_dc_options_discovers_additional_endpoints() {
	mut state := &FakeRuntimeState{
		responses: [
			tl.Object(tl.Config{
				test_mode:         false
				this_dc:           2
				reactions_default: tl.UnknownReactionType{}
				dc_options:        [
					tl.DcOption{
						id:         1
						ip_address: '149.154.175.50'
						port:       443
					},
					tl.DcOption{
						id:         2
						ip_address: '149.154.167.51'
						port:       443
					},
					tl.DcOption{
						id:         3
						ip_address: '149.154.175.100'
						port:       443
						media_only: true
					},
				]
			}),
		]
	}
	mut client := new_fake_client(state)

	client.refresh_dc_options() or { panic(err) }

	assert state.invocations == ['help.getConfig']
	assert client.dc_options.len == 5

	dc1 := client.dc_option_by_id(1) or { panic('missing dc 1') }
	assert dc1.host == '149.154.175.50'
	assert dc1.port == 443
	assert !dc1.is_media

	dc2 := client.dc_option_by_id(2) or { panic('missing dc 2') }
	assert dc2.host == '149.154.167.50'

	dc3 := client.dc_option_by_id(3) or { panic('missing dc 3') }
	assert dc3.host == '149.154.175.100'
	assert !dc3.is_media
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

fn test_sign_in_code_wraps_password_required_as_auth_error() {
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
		]
		errors:    {
			1: IError(RpcError{
				rpc_code: 401
				message:  'SESSION_PASSWORD_NEEDED'
				raw:      tl.RpcError{
					error_code:    401
					error_message: 'SESSION_PASSWORD_NEEDED'
				}
			})
		}
	}
	mut client := new_fake_client(state)

	request := client.send_login_code('+15551234567') or { panic(err) }
	client.sign_in_code(request, '123456') or {
		if err is AuthError {
			assert err.kind == .password_required
			assert err.requires_password()
			assert err.auth_code == 'SESSION_PASSWORD_NEEDED'
			assert err.raw.is('SESSION_PASSWORD_NEEDED')
			return
		}
		assert false
	}
	assert false
}

fn test_complete_login_uses_password_when_required() {
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
		]
		errors:    {
			1: IError(RpcError{
				rpc_code: 401
				message:  'SESSION_PASSWORD_NEEDED'
				raw:      tl.RpcError{
					error_code:    401
					error_message: 'SESSION_PASSWORD_NEEDED'
				}
			})
		}
	}
	mut client := new_fake_client(state)

	request := client.send_login_code('+15551234567') or { panic(err) }
	authorization := client.complete_login(request, '123456', '123123') or { panic(err) }

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

	assert state.invocations == [
		'auth.sendCode',
		'auth.signIn',
		'account.getPassword',
		'auth.checkPassword',
	]
}

fn test_start_uses_callbacks_for_phone_code_and_password() {
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
			tl.Object(tl.UsersUserFull{
				full_user: tl.UnknownUserFullType{}
				chats:     []tl.ChatType{}
				users:     [
					tl.UserType(make_test_user('alice', 42, 77)),
				]
			}),
		]
		errors:    {
			1: IError(RpcError{
				rpc_code: 401
				message:  'SESSION_PASSWORD_NEEDED'
				raw:      tl.RpcError{
					error_code:    401
					error_message: 'SESSION_PASSWORD_NEEDED'
				}
			})
		}
	}
	mut client := new_fake_client(state)

	me := client.start(StartOptions{
		phone_number: start_test_phone
		code:         start_test_code
		password:     start_test_password
	}) or { panic(err) }

	match me {
		tl.UsersUserFull {
			assert me.users.len == 1
		}
		else {
			assert false
		}
	}

	assert state.invocations == [
		'auth.sendCode',
		'auth.signIn',
		'account.getPassword',
		'auth.checkPassword',
		'users.getFullUser',
	]
}

fn test_start_uses_bot_token_when_phone_is_missing() {
	mut state := &FakeRuntimeState{
		responses: [
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
			tl.Object(tl.UsersUserFull{
				full_user: tl.UnknownUserFullType{}
				chats:     []tl.ChatType{}
				users:     [
					tl.UserType(make_test_user('bot', 99, 88)),
				]
			}),
		]
	}
	mut client := new_fake_client(state)

	me := client.start(StartOptions{
		phone_number: start_test_empty_phone
		bot_token:    start_test_bot_token
	}) or { panic(err) }

	match me {
		tl.UsersUserFull {
			assert me.users.len == 1
		}
		else {
			assert false
		}
	}

	assert state.invocations == [
		'auth.importBotAuthorization',
		'users.getFullUser',
	]
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

fn test_build_runtime_restores_peer_cache_from_store() {
	mut store := session.new_memory_session()
	store.save(session.SessionData{
		state: session.SessionState{
			dc_id:           2
			dc_address:      '149.154.167.50'
			dc_port:         443
			auth_key:        []u8{len: 256, init: u8(1)}
			auth_key_id:     77
			server_salt:     55
			session_id:      99
			layer:           201
			schema_revision: 'test-layer'
			created_at:      1_700_000_000
		}
		peers: [
			session.PeerRecord{
				cache_key:  'alice'
				key:        'user:42'
				username:   'alice'
				peer:       tl.PeerUser{
					user_id: 42
				}
				input_peer: tl.InputPeerUser{
					user_id:     42
					access_hash: 77
				}
			},
		]
	}) or { panic(err) }
	mut client := new_client_with_store(ClientConfig{
		app_id:     1
		app_hash:   'test-hash'
		dc_options: [
			DcOption{
				id:   2
				host: '149.154.167.50'
				port: 443
			},
		]
	}, store) or { panic(err) }

	runtime, restored := client.build_runtime() or { panic(err) }

	assert restored
	client.runtime = runtime
	client.runtime_ready = true

	peer := client.cached_input_peer('alice') or { panic('expected restored peer cache entry') }
	match peer {
		tl.InputPeerUser {
			assert peer.user_id == 42
			assert peer.access_hash == 77
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

fn test_resolve_peer_supports_cached_keys_and_self_aliases() {
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
		]
	}
	mut client := new_fake_client(state)

	resolved := client.resolve_peer('@Alice') or { panic(err) }
	cached := client.resolve_peer('user:42') or { panic(err) }
	me := client.resolve_peer('self') or { panic(err) }

	assert resolved.key == 'user:42'
	assert cached.username == 'alice'
	match cached.input_peer {
		tl.InputPeerUser {
			assert cached.input_peer.user_id == 42
			assert cached.input_peer.access_hash == 77
		}
		else {
			assert false
		}
	}
	match me.input_peer {
		tl.InputPeerSelf {
			assert true
		}
		else {
			assert false
		}
	}
	assert state.invocations == ['contacts.resolveUsername']
}

fn test_collect_dialogs_paginates_and_caches_page_peers() {
	first_user := make_test_user('alice', 42, 77)
	second_user := make_test_user('bob', 43, 88)
	mut state := &FakeRuntimeState{
		responses: [
			tl.Object(tl.MessagesDialogsSlice{
				count:    2
				dialogs:  [
					tl.DialogType(tl.Dialog{
						peer:            tl.PeerUser{
							user_id: 42
						}
						top_message:     100
						notify_settings: tl.PeerNotifySettings{}
					}),
				]
				messages: [
					tl.MessageType(tl.Message{
						id:              100
						peer_id:         tl.PeerUser{
							user_id: 42
						}
						date:            1_700_000_100
						message:         'first'
						media:           tl.UnknownMessageMediaType{}
						has_media_value: false
					}),
				]
				chats:    []tl.ChatType{}
				users:    [
					tl.UserType(first_user),
				]
			}),
			tl.Object(tl.MessagesDialogs{
				dialogs:  [
					tl.DialogType(tl.Dialog{
						peer:            tl.PeerUser{
							user_id: 43
						}
						top_message:     90
						notify_settings: tl.PeerNotifySettings{}
					}),
				]
				messages: [
					tl.MessageType(tl.Message{
						id:              90
						peer_id:         tl.PeerUser{
							user_id: 43
						}
						date:            1_700_000_090
						message:         'second'
						media:           tl.UnknownMessageMediaType{}
						has_media_value: false
					}),
				]
				chats:    []tl.ChatType{}
				users:    [
					tl.UserType(second_user),
				]
			}),
		]
	}
	mut client := new_fake_client(state)

	batch := client.collect_dialogs(DialogPageOptions{
		limit:     1
		max_pages: 2
	}) or { panic(err) }

	assert batch.pages.len == 2
	assert batch.dialogs.len == 2
	assert batch.messages.len == 2
	assert state.invocations == ['messages.getDialogs', 'messages.getDialogs']

	first_call := state.functions[0]
	match first_call {
		tl.MessagesGetDialogs {
			assert first_call.limit == 1
			assert first_call.offset_id == 0
			assert first_call.offset_date == 0
			match first_call.offset_peer {
				tl.InputPeerEmpty {
					assert true
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

	second_call := state.functions[1]
	match second_call {
		tl.MessagesGetDialogs {
			assert second_call.limit == 1
			assert second_call.offset_id == 100
			assert second_call.offset_date == 1_700_000_100
			match second_call.offset_peer {
				tl.InputPeerUser {
					assert second_call.offset_peer.user_id == 42
					assert second_call.offset_peer.access_hash == 77
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

	if cached := client.cached_peer('user:43') {
		match cached.input_peer {
			tl.InputPeerUser {
				assert cached.input_peer.user_id == 43
				assert cached.input_peer.access_hash == 88
			}
			else {
				assert false
			}
		}
	} else {
		assert false
	}
}

fn test_collect_history_paginates_and_deduplicates_pages() {
	mut state := &FakeRuntimeState{
		responses: [
			tl.Object(tl.MessagesMessagesSlice{
				count:    2
				messages: [
					tl.MessageType(tl.Message{
						id:              100
						peer_id:         tl.PeerUser{
							user_id: 42
						}
						date:            1_700_000_100
						message:         'first'
						media:           tl.UnknownMessageMediaType{}
						has_media_value: false
					}),
				]
				topics:   []tl.ForumTopicType{}
				chats:    []tl.ChatType{}
				users:    [
					tl.UserType(make_test_user('alice', 42, 77)),
				]
			}),
			tl.Object(tl.MessagesMessages{
				messages: [
					tl.MessageType(tl.Message{
						id:              90
						peer_id:         tl.PeerUser{
							user_id: 42
						}
						date:            1_700_000_090
						message:         'second'
						media:           tl.UnknownMessageMediaType{}
						has_media_value: false
					}),
				]
				topics:   []tl.ForumTopicType{}
				chats:    []tl.ChatType{}
				users:    [
					tl.UserType(make_test_user('alice', 42, 77)),
				]
			}),
		]
	}
	mut client := new_fake_client(state)

	batch := client.collect_history(tl.InputPeerSelf{}, HistoryPageOptions{
		limit:     1
		max_pages: 2
	}) or { panic(err) }

	assert batch.pages.len == 2
	assert batch.messages.len == 2
	assert batch.users.len == 1
	assert state.invocations == ['messages.getHistory', 'messages.getHistory']

	first_call := state.functions[0]
	match first_call {
		tl.MessagesGetHistory {
			assert first_call.limit == 1
			assert first_call.offset_id == 0
			assert first_call.offset_date == 0
		}
		else {
			assert false
		}
	}

	second_call := state.functions[1]
	match second_call {
		tl.MessagesGetHistory {
			assert second_call.limit == 1
			assert second_call.offset_id == 100
			assert second_call.offset_date == 1_700_000_100
		}
		else {
			assert false
		}
	}
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

fn test_client_exposes_bounded_rpc_debug_events() {
	mut client := Client{
		config:         ClientConfig{
			app_id:                  1
			app_hash:                'test-hash'
			rpc_event_history_limit: 2
			dc_options:              [
				DcOption{
					id:   2
					host: '149.154.167.50'
					port: 443
				},
			]
		}
		debug_recorder: rpc.new_debug_recorder(rpc.DebugRecorderConfig{
			capacity: 2
		})
		store:          session.new_memory_store()
		peer_cache:     map[string]CachedPeer{}
		update_manager: updates.new_manager(updates.ManagerConfig{})
	}

	client.debug_recorder.emit(rpc.DebugEvent{
		kind: .retry_scheduled
	})
	client.debug_recorder.emit(rpc.DebugEvent{
		kind: .dc_migration
	})
	client.debug_recorder.emit(rpc.DebugEvent{
		kind: .reconnect_succeeded
	})

	events := client.rpc_debug_events()
	assert events.len == 2
	assert events[0].kind == .dc_migration
	assert events[1].kind == .reconnect_succeeded

	client.clear_rpc_debug_events()
	assert client.rpc_debug_events().len == 0
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

fn test_upload_file_bytes_resume_uses_big_file_parts_for_large_transfers() {
	payload := []u8{len: media.big_file_threshold + 4096, init: u8((index % 251) + 1)}
	part_size := 512 * 1024
	total_parts := (payload.len + part_size - 1) / part_size
	mut state := &FakeRuntimeState{
		responses: [
			tl.Object(tl.BoolTrue{}),
		]
	}
	mut client := new_fake_client(state)

	uploaded := client.upload_file_bytes('video.mp4', payload, media.UploadOptions{
		file_id:     77
		part_size:   part_size
		resume_part: total_parts - 1
	}) or { panic(err) }

	assert uploaded.is_big
	assert state.invocations == ['upload.saveBigFilePart']
	resume_call := state.functions[0]
	match resume_call {
		tl.UploadSaveBigFilePart {
			assert resume_call.file_id == 77
			assert resume_call.file_part == total_parts - 1
			assert resume_call.file_total_parts == total_parts
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

fn test_download_file_resumes_from_previous_offset_window() {
	mut state := &FakeRuntimeState{
		responses: [
			tl.Object(tl.UploadFile{
				type_value: tl.StorageFileUnknown{}
				mtime:      0
				bytes:      [u8(8), 9, 10]
			}),
		]
	}
	mut client := new_fake_client(state)

	result := client.download_file(tl.InputDocumentFileLocation{
		id:             17
		access_hash:    21
		file_reference: [u8(3), 2, 1]
		thumb_size:     ''
	}, media.DownloadOptions{
		offset:    4096
		max_bytes: 3
		part_size: 4096
	}) or { panic(err) }

	assert result.completed
	assert result.start_offset == 4096
	assert result.end_offset == 4099
	assert result.bytes == [u8(8), 9, 10]
	download_call := state.functions[0]
	match download_call {
		tl.UploadGetFile {
			assert download_call.offset == 4096
			assert download_call.limit == 3
		}
		else {
			assert false
		}
	}
}

fn test_download_file_reference_reuses_media_reference_wrapper() {
	mut state := &FakeRuntimeState{
		responses: [
			tl.Object(tl.UploadFile{
				type_value: tl.StorageFileUnknown{}
				mtime:      0
				bytes:      [u8(1), 2]
			}),
		]
	}
	mut client := new_fake_client(state)

	result := client.download_file_reference(media.new_document_file_reference(55, 66,
		[u8(7), 8], 'thumb'), media.DownloadOptions{
		part_size: 4096
	}) or { panic(err) }

	assert result.bytes == [u8(1), 2]
	download_call := state.functions[0]
	match download_call {
		tl.UploadGetFile {
			match download_call.location {
				tl.InputDocumentFileLocation {
					assert download_call.location.id == 55
					assert download_call.location.access_hash == 66
					assert download_call.location.file_reference == [u8(7), 8]
					assert download_call.location.thumb_size == 'thumb'
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

fn test_file_hash_client_helpers_decode_vector_responses() {
	hashes := [
		tl.FileHashType(tl.FileHash{
			offset: 0
			limit:  4096
			hash:   [u8(1), 2, 3]
		}),
		tl.FileHashType(tl.FileHash{
			offset: 4096
			limit:  1024
			hash:   [u8(4), 5, 6]
		}),
	]
	mut state := &FakeRuntimeState{
		responses: [
			file_hash_vector_object(hashes),
			file_hash_vector_object(hashes[1..]),
			file_hash_vector_object(hashes[..1]),
		]
	}
	mut client := new_fake_client(state)

	file_hashes := client.get_file_hashes(tl.InputDocumentFileLocation{
		id:             1
		access_hash:    2
		file_reference: [u8(3)]
		thumb_size:     ''
	}, 0) or { panic(err) }
	cdn_hashes := client.get_cdn_file_hashes([u8(9), 9], 4096) or { panic(err) }
	reuploaded := client.reupload_cdn_file([u8(9), 9], [u8(7), 7]) or { panic(err) }

	assert file_hashes.len == 2
	assert cdn_hashes.len == 1
	assert reuploaded.len == 1
	assert state.invocations == ['upload.getFileHashes', 'upload.getCdnFileHashes',
		'upload.reuploadCdnFile']
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

fn unwrap_client_function(function tl.Function) tl.Function {
	match function {
		tl.InvokeWithLayer {
			match function.query {
				tl.InitConnection {
					match function.query.query {
						FunctionObjectAdapter {
							return function.query.query.function
						}
						else {}
					}
				}
				else {}
			}
		}
		else {}
	}
	return function
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

fn start_test_phone() !string {
	return '+15551234567'
}

fn start_test_empty_phone() !string {
	return ''
}

fn start_test_bot_token() !string {
	return '123:bot-token'
}

fn start_test_code(request LoginCodeRequest) !string {
	return '123456'
}

fn start_test_password() !string {
	return '123123'
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

fn file_hash_vector_object(hashes []tl.FileHashType) tl.Object {
	mut raw := []u8{}
	tl.append_int(mut raw, hashes.len)
	for hash in hashes {
		raw << hash.encode() or { panic(err) }
	}
	return tl.Object(tl.UnknownObject{
		constructor: tl.vector_constructor_id
		raw_payload: raw
	})
}
