module main

import os
import vtol
import vtol.rpc
import vtol.tl

const default_dc_host = '149.154.167.50'
const default_session_file = '.vtol.example.session.json'
const default_timeout_ms = 30_000

fn main() {
	run() or {
		eprintln('auth_basic: ${err}')
		exit(1)
	}
}

fn run() ! {
	session_file := env_or_default('VTOL_EXAMPLE_SESSION_FILE', default_session_file)
	mut client := new_example_client(session_file)!
	defer {
		client.disconnect() or {}
	}

	me := client.start(vtol.StartOptions{
		phone_number:          prompt_phone_number
		bot_token:             prompt_bot_token
		code:                  prompt_code
		password:              prompt_password
		code_sent_callback:    on_code_sent
		invalid_auth_callback: on_invalid_auth
	})!

	print_current_user(me)
	if client.did_restore_session() {
		println('restored session from ${session_file}')
	} else {
		println('session saved to ${session_file}')
	}
}

fn new_example_client(session_file string) !vtol.Client {
	app_id := required_env('VTOL_EXAMPLE_API_ID')!.int()
	app_hash := required_env('VTOL_EXAMPLE_API_HASH')!
	dc_host := env_or_default('VTOL_EXAMPLE_DC_HOST', default_dc_host)
	timeout_ms := env_int_or_default('VTOL_EXAMPLE_TIMEOUT_MS', default_timeout_ms)
	if env_bool('VTOL_DEBUG_RPC') {
		eprintln('auth_basic: rpc debug logging enabled')
	}
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
		test_mode:            env_bool('VTOL_EXAMPLE_TEST_MODE')
	}, session_file)
}

fn prompt_phone_number() !string {
	phone_number := os.getenv('VTOL_EXAMPLE_PHONE_NUMBER').trim_space()
	if phone_number.len > 0 {
		eprintln('auth_basic: using phone login')
		return phone_number
	}
	value := os.input('enter the phone number (leave blank for bot login): ').trim_space()
	if value.len > 0 {
		eprintln('auth_basic: requesting login code')
	}
	return value
}

fn prompt_bot_token() !string {
	bot_token := os.getenv('VTOL_EXAMPLE_BOT_TOKEN').trim_space()
	if bot_token.len > 0 {
		eprintln('auth_basic: using bot login')
		return bot_token
	}
	value := os.input('enter the bot token (leave blank for user login): ').trim_space()
	if value.len > 0 {
		eprintln('auth_basic: attempting bot login')
	}
	return value
}

fn prompt_code(request vtol.LoginCodeRequest) !string {
	eprintln('auth_basic: waiting for login code (${request.sent_code.qualified_name()})')
	mut code := os.getenv('VTOL_EXAMPLE_LOGIN_CODE').trim_space()
	if code.len == 0 {
		code = os.input('enter the login code: ').trim_space()
	}
	if code.len == 0 {
		return error('login code must not be empty')
	}
	return code
}

fn prompt_password() !string {
	mut password := os.getenv('VTOL_EXAMPLE_PASSWORD').trim_space()
	if password.len == 0 {
		password = os.input('enter the 2FA password: ').trim_space()
	}
	if password.len == 0 {
		return error('2FA password must not be empty')
	}
	return password
}

fn on_code_sent(request vtol.LoginCodeRequest) {
	eprintln('auth_basic: login code requested successfully (${request.sent_code.qualified_name()})')
}

fn on_invalid_auth(kind vtol.AuthPromptKind, err vtol.AuthError) {
	eprintln('auth_basic: ${kind} rejected: ${err.msg()}')
}

fn print_current_user(me tl.UsersUserFullType) {
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

fn required_env(name string) !string {
	value := os.getenv(name).trim_space()
	if value.len > 0 {
		return value
	}
	return error('missing required environment variable: ${name}')
}

fn env_or_default(name string, fallback string) string {
	value := os.getenv(name).trim_space()
	if value.len > 0 {
		return value
	}
	return fallback
}

fn env_bool(name string) bool {
	value := os.getenv(name).trim_space().to_lower()
	return value == '1' || value == 'true' || value == 'yes'
}

fn env_int_or_default(name string, fallback int) int {
	value := os.getenv(name).trim_space()
	if value.len == 0 {
		return fallback
	}
	return value.int()
}
