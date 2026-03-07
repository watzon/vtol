module main

import os
import tl
import vtol

const default_dc_host = '149.154.167.50'
const default_session_file = '.vtol.example.session.json'

fn main() {
	run() or {
		eprintln('send_message: ${err}')
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
	message := first_non_empty_env([
		'VTOL_EXAMPLE_MESSAGE',
	]) or { 'hello from VTOL' }

	mut client := new_example_client(session_file)!
	defer {
		client.disconnect() or {}
	}

	client.connect()!
	if !client.did_restore_session() {
		return error('no saved session was restored from ${session_file}; run examples/auth_basic first')
	}

	peer := client.resolve_input_peer(peer_key)!
	updates := client.send_message(peer, message)!
	println('sent message to ${peer_key}: ${message}')
	describe_updates(updates)
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

fn describe_updates(updates tl.UpdatesType) {
	match updates {
		tl.UpdateShortSentMessage {
			println('server acknowledged message id ${updates.id}')
		}
		tl.Updates {
			println('server returned updates with ${updates.updates.len} event(s)')
		}
		tl.UpdatesCombined {
			println('server returned a combined update batch with ${updates.updates.len} event(s)')
		}
		tl.UpdatesTooLong {
			println('server returned updatesTooLong')
		}
		else {
			println('server returned ${updates.qualified_name()}')
		}
	}
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
