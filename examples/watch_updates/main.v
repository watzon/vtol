module main

import time
import vtol
import vtol.example_support

const default_idle_notice_every = 30
const default_pump_interval_ms = 250

@[heap]
struct MessageCounter {
mut:
	count int
}

fn main() {
	run() or {
		eprintln('watch_updates: ${err}')
		exit(1)
	}
}

fn run() ! {
	session_file := example_support.session_file_from_env()
	pump_interval_ms := example_support.env_int([
		'VTOL_EXAMPLE_PUMP_INTERVAL_MS',
	], default_pump_interval_ms)
	max_pumps := example_support.env_int([
		'VTOL_EXAMPLE_MAX_PUMPS',
	], 0)

	mut client := example_support.new_client_from_env(session_file)!
	defer {
		client.disconnect() or {}
	}

	client.connect()!
	example_support.require_restored_session(client, session_file)!

	counter := &MessageCounter{}
	handler_id := client.on_new_message(fn [counter] (event vtol.NewMessageEvent) ! {
		sender := if event.has_sender_value && event.sender.key.len > 0 {
			event.sender.key
		} else {
			'unknown-sender'
		}
		unsafe {
			counter.count++
		}
		println('[${event.kind}] ${event.chat.key} <- ${sender}: ${event.text}')
	})!
	defer {
		client.remove_event_handler(handler_id)
	}
	if state := client.update_state() {
		println('watching updates from pts=${state.pts} qts=${state.qts} seq=${state.seq}')
	}
	if max_pumps > 0 {
		println('running ${max_pumps} update pump cycle(s)')
	} else {
		println('watching updates until interrupted')
		client.idle()!
		return
	}

	mut cycles := 0
	mut idle_cycles := 0
	mut seen_messages := 0
	for {
		client.pump_updates_once()!
		cycles++
		current_count := unsafe { counter.count }
		if current_count > seen_messages {
			seen_messages = current_count
			idle_cycles = 0
		} else {
			idle_cycles++
		}
		if idle_cycles > 0 && (idle_cycles == 1 || idle_cycles % default_idle_notice_every == 0) {
			println('no matching message events yet (cycle ${cycles})')
		}
		if max_pumps > 0 && cycles >= max_pumps {
			println('completed ${cycles} pump cycle(s)')
			break
		}
		if pump_interval_ms > 0 {
			time.sleep(time.Duration(pump_interval_ms) * time.millisecond)
		}
	}
}
