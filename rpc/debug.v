module rpc

import json
import os

pub enum DebugEventKind {
	request_started
	result_received
	rpc_error_received
	transport_error
	retry_scheduled
	dc_migration
	reconnect_started
	reconnect_succeeded
	reconnect_failed
}

pub struct DebugEvent {
pub:
	timestamp_ms      i64
	kind              DebugEventKind
	function_name     string
	request_msg_id    i64
	attempt           int
	timeout_ms        int
	current_dc_id     int
	current_host      string
	current_port      int
	current_is_media  bool
	object_name       string
	rpc_error_code    int
	rpc_error_message string
	transport_message string
	delay_ms          int
	target_dc_id      int
}

pub interface DebugLogger {
	emit(event DebugEvent)
}

pub struct NoopDebugLogger {}

pub fn (n NoopDebugLogger) emit(event DebugEvent) {}

pub struct JsonLineDebugLogger {
pub:
	prettify bool
}

pub fn (l JsonLineDebugLogger) emit(event DebugEvent) {
	println(json.encode(event))
}

pub fn emit_env_debug(event DebugEvent) {
	if os.getenv('VTOL_DEBUG_RPC') != '1' {
		return
	}
	eprintln(json.encode(event))
}

@[heap]
struct DebugRecorderState {
mut:
	events []DebugEvent
}

pub struct DebugRecorderConfig {
pub:
	capacity   int         = 64
	downstream DebugLogger = NoopDebugLogger{}
}

pub struct DebugRecorder {
pub:
	capacity   int
	downstream DebugLogger = NoopDebugLogger{}
mut:
	state &DebugRecorderState = unsafe { nil }
}

pub fn new_debug_recorder(config DebugRecorderConfig) DebugRecorder {
	capacity := if config.capacity > 0 { config.capacity } else { 0 }
	return DebugRecorder{
		capacity:   capacity
		downstream: config.downstream
		state:      &DebugRecorderState{
			events: []DebugEvent{cap: capacity}
		}
	}
}

pub fn (r DebugRecorder) emit(event DebugEvent) {
	if !isnil(r.state) && r.capacity > 0 {
		unsafe {
			if r.state.events.len >= r.capacity {
				r.state.events.delete(0)
			}
			r.state.events << event
		}
	}
	r.downstream.emit(event)
}

pub fn (r DebugRecorder) snapshot() []DebugEvent {
	if isnil(r.state) {
		return []DebugEvent{}
	}
	unsafe {
		return r.state.events.clone()
	}
}

pub fn (r DebugRecorder) clear() {
	if isnil(r.state) {
		return
	}
	unsafe {
		r.state.events = []DebugEvent{cap: r.capacity}
	}
}
