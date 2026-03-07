module main

import vtol.example_support

fn main() {
	run() or {
		eprintln('send_message: ${err}')
		exit(1)
	}
}

fn run() ! {
	session_file := example_support.session_file_from_env()
	peer_key := example_support.first_non_empty_env([
		'VTOL_EXAMPLE_PEER',
	]) or { 'me' }
	message := example_support.first_non_empty_env([
		'VTOL_EXAMPLE_MESSAGE',
	]) or { 'hello from VTOL' }

	mut client := example_support.new_client_from_env(session_file)!
	defer {
		client.disconnect() or {}
	}

	client.connect()!
	example_support.require_restored_session(client, session_file)!

	sent := client.send_message(peer_key, message)!
	println('sent message to ${peer_key}: ${message}')
	println(example_support.describe_updates(sent.updates))
}
