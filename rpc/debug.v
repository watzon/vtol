module rpc

import json
import os

// DebugEventKind classifies the debug events emitted by the RPC engine.
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

// DebugEvent records one step in the lifecycle of an RPC call.
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

// DebugLogger receives emitted RPC debug events.
pub interface DebugLogger {
	emit(event DebugEvent)
}

// NoopDebugLogger discards emitted debug events.
pub struct NoopDebugLogger {}

// emit discards the debug event.
pub fn (n NoopDebugLogger) emit(event DebugEvent) {}

// JsonLineDebugLogger prints each debug event as a JSON line.
pub struct JsonLineDebugLogger {
pub:
	prettify bool
}

// emit writes the debug event as JSON to stdout.
pub fn (l JsonLineDebugLogger) emit(event DebugEvent) {
	println(json.encode(event))
}

// emit_env_debug writes the event to stderr when VTOL_DEBUG_RPC=1.
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

// DebugRecorderConfig configures in-memory debug event buffering.
pub struct DebugRecorderConfig {
pub:
	capacity   int         = 64
	downstream DebugLogger = NoopDebugLogger{}
}

// DebugRecorder stores a bounded in-memory history of debug events.
pub struct DebugRecorder {
pub:
	capacity   int
	downstream DebugLogger = NoopDebugLogger{}
mut:
	state &DebugRecorderState = unsafe { nil }
}

// new_debug_recorder creates a DebugRecorder with normalized capacity.
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

// emit appends the event to the recorder and forwards it downstream.
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

// snapshot returns a copy of the buffered debug events.
pub fn (r DebugRecorder) snapshot() []DebugEvent {
	if isnil(r.state) {
		return []DebugEvent{}
	}
	unsafe {
		return r.state.events.clone()
	}
}

// clear removes all buffered debug events.
pub fn (r DebugRecorder) clear() {
	if isnil(r.state) {
		return
	}
	unsafe {
		r.state.events = []DebugEvent{cap: r.capacity}
	}
}
