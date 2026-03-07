module rpc

import json

pub enum DebugEventKind {
	request_started
	result_received
	rpc_error_received
	transport_error
	retry_scheduled
	dc_migration
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
