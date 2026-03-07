module main

import vtol
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
	]) or { '*hello* from `VTOL`' }

	mut client := example_support.new_client_from_env(session_file)!
	defer {
		client.disconnect() or {}
	}

	client.connect()!
	example_support.require_restored_session(client, session_file)!

	formatted := vtol.parse_markdown(message) or { vtol.plain_text(message) }
	sent := client.send_text(peer_key, formatted)!
	println('sent message ${sent.id} to ${sent.peer.key}: ${sent.text}')
	if sent.has_entities_value {
		println('formatting entities: ${sent.entities.len}')
	}
	println(example_support.describe_updates(sent.updates))
}
