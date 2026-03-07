module rpc

import tl

pub struct RateLimitInfo {
pub:
	wait_seconds int
	premium      bool
}

pub struct RpcError {
	Error
pub:
	rpc_code       int
	message        string
	raw            tl.RpcError
	wait_seconds   int
	premium_wait   bool
	has_rate_limit bool
}

pub fn new_rpc_error(raw tl.RpcError) RpcError {
	if info := rate_limit_info(raw) {
		return RpcError{
			rpc_code:       raw.error_code
			message:        raw.error_message
			raw:            raw
			wait_seconds:   info.wait_seconds
			premium_wait:   info.premium
			has_rate_limit: true
		}
	}
	return RpcError{
		rpc_code: raw.error_code
		message:  raw.error_message
		raw:      raw
	}
}

pub fn (e RpcError) msg() string {
	if e.has_rate_limit {
		wait_kind := if e.premium_wait { 'premium flood wait' } else { 'flood wait' }
		return 'rpc error ${e.rpc_code}: ${e.message} (${wait_kind} ${e.wait_seconds}s)'
	}
	return 'rpc error ${e.rpc_code}: ${e.message}'
}

pub fn (e RpcError) code() int {
	return e.rpc_code
}

pub fn (e RpcError) is_rate_limited() bool {
	return e.has_rate_limit
}

pub fn (e RpcError) retry_after_ms() int {
	if !e.has_rate_limit {
		return 0
	}
	return e.wait_seconds * 1_000
}

pub struct TimeoutError {
	Error
pub:
	request_msg_id i64
	timeout_ms     int
}

pub fn (e TimeoutError) msg() string {
	return 'rpc request ${e.request_msg_id} timed out after ${e.timeout_ms}ms'
}

pub fn (e TimeoutError) code() int {
	return 0
}

pub struct TransportError {
	Error
pub:
	message string
}

pub fn (e TransportError) msg() string {
	return e.message
}

pub fn (e TransportError) code() int {
	return 0
}

pub fn rate_limit_info(rpc_error tl.RpcError) ?RateLimitInfo {
	if wait_seconds := parse_suffix_number(rpc_error.error_message, 'FLOOD_WAIT_') {
		return RateLimitInfo{
			wait_seconds: wait_seconds
		}
	}
	if wait_seconds := parse_suffix_number(rpc_error.error_message, 'FLOOD_PREMIUM_WAIT_') {
		return RateLimitInfo{
			wait_seconds: wait_seconds
			premium:      true
		}
	}
	return none
}

pub fn migration_dc_id(rpc_error tl.RpcError) ?int {
	for prefix in ['PHONE_MIGRATE_', 'NETWORK_MIGRATE_', 'USER_MIGRATE_', 'FILE_MIGRATE_'] {
		if dc_id := parse_suffix_number(rpc_error.error_message, prefix) {
			return dc_id
		}
	}
	return none
}
