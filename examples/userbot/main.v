module main

import vtol
import vtol.example_support

const command_prefix = '!'

fn main() {
	run() or {
		eprintln('userbot: ${err}')
		exit(1)
	}
}

fn run() ! {
	session_file := example_support.session_file_from_env()

	mut client := example_support.new_client_from_env(session_file)!
	defer {
		client.disconnect() or {}
	}

	client.connect()!
	example_support.require_restored_session(client, session_file)!

	handler_id := client.on_new_message_with_config(vtol.NewMessageHandlerConfig{
		outgoing: true
		forwards: false
		pattern:  '^!'
	}, fn (event vtol.NewMessageEvent) ! {
		handle_command(event)!
	})!
	defer {
		client.remove_event_handler(handler_id)
	}

	println('userbot ready; try !ping, !echo hello, or !help')
	client.run_until_disconnected()!
}

fn handle_command(event vtol.NewMessageEvent) ! {
	command, arguments := parse_command(event.text)
	if command.len == 0 {
		return
	}

	response := match command {
		'ping' {
			'pong'
		}
		'echo' {
			if arguments.len > 0 { arguments } else { 'usage: !echo <text>' }
		}
		'help' {
			'commands: !ping, !echo <text>, !help'
		}
		else {
			'unknown command `${command}`; try !help'
		}
	}

	event.reply(response)!
	println('handled ${event.text} in ${event.chat.key}')
}

fn parse_command(text string) (string, string) {
	trimmed := text.trim_space()
	if trimmed.len <= command_prefix.len || !trimmed.starts_with(command_prefix) {
		return '', ''
	}
	body := trimmed[command_prefix.len..].trim_space()
	if body.len == 0 {
		return '', ''
	}
	separator := body.index(' ') or { -1 }
	if separator < 0 {
		return body.to_lower(), ''
	}
	command := body[..separator].to_lower()
	arguments := body[separator + 1..].trim_space()
	return command, arguments
}
