module main

import os
import vtol
import vtol.example_support

fn main() {
	run() or {
		eprintln('auth_basic: ${err}')
		exit(1)
	}
}

fn run() ! {
	session_file := example_support.session_file_from_env()
	mut client := example_support.new_client_from_env(session_file)!
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

	example_support.print_current_user(me)
	if client.did_restore_session() {
		println('restored session from ${session_file}')
	} else {
		println('session saved to ${session_file}')
	}
}

fn prompt_phone_number() !string {
	phone_number := example_support.first_non_empty_env(['VTOL_EXAMPLE_PHONE_NUMBER']) or { '' }
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
	bot_token := example_support.first_non_empty_env(['VTOL_EXAMPLE_BOT_TOKEN']) or { '' }
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
	mut code := example_support.first_non_empty_env(['VTOL_EXAMPLE_LOGIN_CODE']) or { '' }
	if code.len == 0 {
		code = os.input('enter the login code: ').trim_space()
	}
	if code.len == 0 {
		return error('login code must not be empty')
	}
	return code
}

fn prompt_password() !string {
	mut password := example_support.first_non_empty_env(['VTOL_EXAMPLE_PASSWORD']) or { '' }
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
