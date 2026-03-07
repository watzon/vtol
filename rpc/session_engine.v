module rpc

import crypto
import session
import time
import tl
import transport

pub enum MiddlewareActionKind {
	proceed
	retry
	fail
	migrate_dc
}

pub struct MiddlewareAction {
pub:
	kind     MiddlewareActionKind = .proceed
	delay_ms int
	dc_id    int
}

pub struct AttemptContext {
pub:
	function_name    string
	request_msg_id   i64
	attempt          int
	timeout_ms       int
	current_dc_id    int
	current_host     string
	current_port     int
	current_is_media bool
}

pub interface Middleware {
	before_send(context AttemptContext, function tl.Function) !
	after_result(context AttemptContext, result tl.Object) MiddlewareAction
	after_rpc_error(context AttemptContext, rpc_error tl.RpcError) MiddlewareAction
	after_transport_error(context AttemptContext, message string) MiddlewareAction
}

pub struct EngineConfig {
pub:
	default_timeout_ms int  = 10_000
	max_retry_attempts int  = 3
	auto_ack           bool = true
	auto_reconnect     bool = true
	middlewares        []Middleware
	debug_logger       DebugLogger = NoopDebugLogger{}
}

pub struct PendingCall {
pub:
	request_msg_id i64
	timeout_ms     int
	deadline_at_ms i64
}

pub struct EncryptedMessage {
pub:
	server_salt i64
	session_id  i64
	message     transport.WireMessage
	padding     []u8
}

struct PendingCallState {
	function_name string
	options       CallOptions
mut:
	done           bool
	response       tl.Object = tl.UnknownObject{}
	has_response   bool
	rpc_error      tl.RpcError
	has_rpc_error  bool
	transport_fail string
}

struct CallOutcome {
	has_result     bool
	result         tl.Object = tl.UnknownObject{}
	has_rpc_error  bool
	rpc_error      tl.RpcError
	transport_fail string
	timed_out      bool
}

pub struct SessionEngine {
pub:
	config EngineConfig
mut:
	transport       transport.Engine
	state           session.SessionState
	current_dc_id   int
	backend         crypto.Backend
	pending_calls   map[i64]PendingCallState
	inbound_updates []tl.UpdatesType
}

pub fn new_session_engine(transport_engine transport.Engine, state session.SessionState, config EngineConfig) !SessionEngine {
	if state.auth_key.len != crypto.auth_key_size {
		return error('session state auth key must be ${crypto.auth_key_size} bytes')
	}
	if state.session_id == 0 {
		return error('session state must define a non-zero session_id')
	}
	if config.default_timeout_ms <= 0 {
		return error('rpc engine default timeout must be greater than zero')
	}
	if config.max_retry_attempts <= 0 {
		return error('rpc engine max retry attempts must be greater than zero')
	}
	backend := crypto.default_backend()
	resolved_state := session.SessionState{
		dc_id:           state.dc_id
		auth_key:        state.auth_key.clone()
		auth_key_id:     if state.auth_key_id != 0 {
			state.auth_key_id
		} else {
			crypto.derive_auth_key_id(backend, state.auth_key)!
		}
		server_salt:     state.server_salt
		session_id:      state.session_id
		layer:           state.layer
		schema_revision: state.schema_revision
		created_at:      state.created_at
	}
	mut engine := transport_engine
	engine.state.server_salt = resolved_state.server_salt
	engine.state.session_id = resolved_state.session_id
	return SessionEngine{
		config:          config
		transport:       engine
		state:           resolved_state
		current_dc_id:   resolved_state.dc_id
		backend:         backend
		pending_calls:   map[i64]PendingCallState{}
		inbound_updates: []tl.UpdatesType{}
	}
}

pub fn new_session_engine_from_store(transport_engine transport.Engine, mut store session.Store, config EngineConfig) !SessionEngine {
	state := store.load()!
	return new_session_engine(transport_engine, state, config)!
}

pub fn (e SessionEngine) is_connected() bool {
	return e.transport.is_connected()
}

pub fn (e SessionEngine) pending_count() int {
	return e.pending_calls.len
}

pub fn (e SessionEngine) session_state() session.SessionState {
	return session.SessionState{
		dc_id:           e.current_dc_id
		auth_key:        e.state.auth_key.clone()
		auth_key_id:     e.state.auth_key_id
		server_salt:     e.transport.state.server_salt
		session_id:      e.transport.state.session_id
		layer:           e.state.layer
		schema_revision: e.state.schema_revision
		created_at:      e.state.created_at
	}
}

pub fn (mut e SessionEngine) connect() ! {
	if e.transport.is_connected() {
		return
	}
	_ = e.transport.connect()!
}

pub fn (mut e SessionEngine) disconnect() ! {
	e.transport.disconnect()!
}

pub fn (mut e SessionEngine) reconnect() ! {
	saved := e.session_state()
	if e.transport.is_connected() {
		_ = e.transport.reconnect(.requested)!
	} else {
		_ = e.transport.connect()!
	}
	e.transport.state.server_salt = saved.server_salt
	e.transport.state.session_id = saved.session_id
	e.resend_in_flight()!
	e.flush_acks()!
}

pub fn (mut e SessionEngine) pump_once() ! {
	e.connect()!
	e.flush_acks()!
	e.receive_once()!
	e.flush_acks()!
}

pub fn (mut e SessionEngine) drain_updates() []tl.UpdatesType {
	if e.inbound_updates.len == 0 {
		return []tl.UpdatesType{}
	}
	updates := e.inbound_updates.clone()
	e.inbound_updates = []tl.UpdatesType{}
	return updates
}

pub fn (mut e SessionEngine) begin_invoke(function tl.Function, options CallOptions) !PendingCall {
	normalized := e.normalized_options(options)
	return e.start_call(function, normalized, 1, false)!
}

pub fn (mut e SessionEngine) await_call(call PendingCall) !tl.Object {
	context := e.pending_call_context(call)
	outcome := e.await_call_outcome(call)!
	if outcome.has_result {
		e.emit_debug(DebugEvent{
			timestamp_ms:     time.now().unix_milli()
			kind:             .result_received
			function_name:    context.function_name
			request_msg_id:   context.request_msg_id
			attempt:          context.attempt
			timeout_ms:       context.timeout_ms
			current_dc_id:    context.current_dc_id
			current_host:     context.current_host
			current_port:     context.current_port
			current_is_media: context.current_is_media
			object_name:      outcome.result.qualified_name()
		})
		return outcome.result
	}
	if outcome.has_rpc_error {
		e.emit_debug(DebugEvent{
			timestamp_ms:      time.now().unix_milli()
			kind:              .rpc_error_received
			function_name:     context.function_name
			request_msg_id:    context.request_msg_id
			attempt:           context.attempt
			timeout_ms:        context.timeout_ms
			current_dc_id:     context.current_dc_id
			current_host:      context.current_host
			current_port:      context.current_port
			current_is_media:  context.current_is_media
			rpc_error_code:    outcome.rpc_error.error_code
			rpc_error_message: outcome.rpc_error.error_message
		})
		return IError(new_rpc_error(outcome.rpc_error))
	}
	if outcome.timed_out {
		e.emit_debug(DebugEvent{
			timestamp_ms:      time.now().unix_milli()
			kind:              .transport_error
			function_name:     context.function_name
			request_msg_id:    context.request_msg_id
			attempt:           context.attempt
			timeout_ms:        context.timeout_ms
			current_dc_id:     context.current_dc_id
			current_host:      context.current_host
			current_port:      context.current_port
			current_is_media:  context.current_is_media
			transport_message: TimeoutError{
				request_msg_id: call.request_msg_id
				timeout_ms:     call.timeout_ms
			}.msg()
		})
		return IError(TimeoutError{
			request_msg_id: call.request_msg_id
			timeout_ms:     call.timeout_ms
		})
	}
	e.emit_debug(DebugEvent{
		timestamp_ms:      time.now().unix_milli()
		kind:              .transport_error
		function_name:     context.function_name
		request_msg_id:    context.request_msg_id
		attempt:           context.attempt
		timeout_ms:        context.timeout_ms
		current_dc_id:     context.current_dc_id
		current_host:      context.current_host
		current_port:      context.current_port
		current_is_media:  context.current_is_media
		transport_message: outcome.transport_fail
	})
	return IError(TransportError{
		message: outcome.transport_fail
	})
}

pub fn (mut e SessionEngine) invoke(function tl.Function, options CallOptions) !tl.Object {
	normalized := e.normalized_options(options)
	for attempt in 1 .. e.config.max_retry_attempts + 1 {
		call := e.start_call(function, normalized, attempt, true)!
		context := e.build_attempt_context(function.method_name(), call.request_msg_id,
			attempt, normalized.timeout_ms)
		outcome := e.await_call_outcome(call)!
		if outcome.has_result {
			e.emit_debug(DebugEvent{
				timestamp_ms:     time.now().unix_milli()
				kind:             .result_received
				function_name:    context.function_name
				request_msg_id:   context.request_msg_id
				attempt:          context.attempt
				timeout_ms:       context.timeout_ms
				current_dc_id:    context.current_dc_id
				current_host:     context.current_host
				current_port:     context.current_port
				current_is_media: context.current_is_media
				object_name:      outcome.result.qualified_name()
			})
			action := e.apply_result_hooks(context, outcome.result)
			if action.kind == .retry && normalized.can_retry
				&& attempt < e.config.max_retry_attempts {
				e.emit_debug(DebugEvent{
					timestamp_ms:     time.now().unix_milli()
					kind:             .retry_scheduled
					function_name:    context.function_name
					request_msg_id:   context.request_msg_id
					attempt:          context.attempt
					timeout_ms:       context.timeout_ms
					current_dc_id:    context.current_dc_id
					current_host:     context.current_host
					current_port:     context.current_port
					current_is_media: context.current_is_media
					delay_ms:         action.delay_ms
				})
				e.prepare_retry(action)!
				continue
			}
			if action.kind == .migrate_dc && attempt < e.config.max_retry_attempts {
				e.emit_debug(DebugEvent{
					timestamp_ms:     time.now().unix_milli()
					kind:             .dc_migration
					function_name:    context.function_name
					request_msg_id:   context.request_msg_id
					attempt:          context.attempt
					timeout_ms:       context.timeout_ms
					current_dc_id:    context.current_dc_id
					current_host:     context.current_host
					current_port:     context.current_port
					current_is_media: context.current_is_media
					target_dc_id:     action.dc_id
				})
				e.apply_dc_migration(action.dc_id)!
				continue
			}
			return outcome.result
		}
		if outcome.has_rpc_error {
			e.emit_debug(DebugEvent{
				timestamp_ms:      time.now().unix_milli()
				kind:              .rpc_error_received
				function_name:     context.function_name
				request_msg_id:    context.request_msg_id
				attempt:           context.attempt
				timeout_ms:        context.timeout_ms
				current_dc_id:     context.current_dc_id
				current_host:      context.current_host
				current_port:      context.current_port
				current_is_media:  context.current_is_media
				rpc_error_code:    outcome.rpc_error.error_code
				rpc_error_message: outcome.rpc_error.error_message
			})
			action := e.resolve_rpc_error_action(context, outcome.rpc_error, normalized.can_retry)
			match action.kind {
				.retry {
					if !normalized.can_retry || attempt >= e.config.max_retry_attempts {
						return IError(new_rpc_error(outcome.rpc_error))
					}
					e.emit_debug(DebugEvent{
						timestamp_ms:     time.now().unix_milli()
						kind:             .retry_scheduled
						function_name:    context.function_name
						request_msg_id:   context.request_msg_id
						attempt:          context.attempt
						timeout_ms:       context.timeout_ms
						current_dc_id:    context.current_dc_id
						current_host:     context.current_host
						current_port:     context.current_port
						current_is_media: context.current_is_media
						delay_ms:         action.delay_ms
					})
					e.prepare_retry(action)!
					continue
				}
				.migrate_dc {
					if attempt >= e.config.max_retry_attempts {
						return IError(new_rpc_error(outcome.rpc_error))
					}
					e.emit_debug(DebugEvent{
						timestamp_ms:     time.now().unix_milli()
						kind:             .dc_migration
						function_name:    context.function_name
						request_msg_id:   context.request_msg_id
						attempt:          context.attempt
						timeout_ms:       context.timeout_ms
						current_dc_id:    context.current_dc_id
						current_host:     context.current_host
						current_port:     context.current_port
						current_is_media: context.current_is_media
						target_dc_id:     action.dc_id
					})
					e.apply_dc_migration(action.dc_id)!
					continue
				}
				else {
					return IError(new_rpc_error(outcome.rpc_error))
				}
			}
		}
		message := if outcome.timed_out {
			TimeoutError{
				request_msg_id: call.request_msg_id
				timeout_ms:     call.timeout_ms
			}.msg()
		} else {
			outcome.transport_fail
		}
		e.emit_debug(DebugEvent{
			timestamp_ms:      time.now().unix_milli()
			kind:              .transport_error
			function_name:     context.function_name
			request_msg_id:    context.request_msg_id
			attempt:           context.attempt
			timeout_ms:        context.timeout_ms
			current_dc_id:     context.current_dc_id
			current_host:      context.current_host
			current_port:      context.current_port
			current_is_media:  context.current_is_media
			transport_message: message
		})
		action := e.resolve_transport_error_action(context, message, normalized.can_retry)
		if action.kind == .retry && normalized.can_retry && attempt < e.config.max_retry_attempts {
			e.emit_debug(DebugEvent{
				timestamp_ms:     time.now().unix_milli()
				kind:             .retry_scheduled
				function_name:    context.function_name
				request_msg_id:   context.request_msg_id
				attempt:          context.attempt
				timeout_ms:       context.timeout_ms
				current_dc_id:    context.current_dc_id
				current_host:     context.current_host
				current_port:     context.current_port
				current_is_media: context.current_is_media
				delay_ms:         action.delay_ms
			})
			e.prepare_retry(action)!
			continue
		}
		if outcome.timed_out {
			return IError(TimeoutError{
				request_msg_id: call.request_msg_id
				timeout_ms:     call.timeout_ms
			})
		}
		return IError(TransportError{
			message: message
		})
	}
	return IError(TransportError{
		message: 'rpc invoke exhausted retry attempts'
	})
}

fn (mut e SessionEngine) start_call(function tl.Function, options CallOptions, attempt int, use_hooks bool) !PendingCall {
	e.connect()!
	e.flush_acks()!
	wire := e.transport.state.record_outbound(function.encode()!, true, options.requires_ack)
	context := e.build_attempt_context(function.method_name(), wire.msg_id, attempt, options.timeout_ms)
	if use_hooks {
		e.run_before_send_hooks(context, function)!
	}
	e.pending_calls[wire.msg_id] = PendingCallState{
		function_name: function.method_name()
		options:       options
	}
	e.emit_debug(DebugEvent{
		timestamp_ms:     time.now().unix_milli()
		kind:             .request_started
		function_name:    context.function_name
		request_msg_id:   context.request_msg_id
		attempt:          context.attempt
		timeout_ms:       context.timeout_ms
		current_dc_id:    context.current_dc_id
		current_host:     context.current_host
		current_port:     context.current_port
		current_is_media: context.current_is_media
		object_name:      function.qualified_name()
	})
	e.send_wire_message(wire)!
	return PendingCall{
		request_msg_id: wire.msg_id
		timeout_ms:     options.timeout_ms
		deadline_at_ms: time.now().unix_milli() + options.timeout_ms
	}
}

pub fn pack_encrypted_message(state session.SessionState, message transport.WireMessage) ![]u8 {
	if state.auth_key.len != crypto.auth_key_size {
		return error('session state auth key must be ${crypto.auth_key_size} bytes')
	}
	if state.session_id == 0 {
		return error('session state session_id must be non-zero')
	}
	backend := crypto.default_backend()
	return pack_encrypted_message_with_direction(state, message, backend, true)!
}

fn pack_encrypted_message_with_direction(state session.SessionState, message transport.WireMessage, backend crypto.Backend, outgoing bool) ![]u8 {
	auth_key_id := if state.auth_key_id != 0 {
		state.auth_key_id
	} else {
		crypto.derive_auth_key_id(backend, state.auth_key)!
	}
	mut plaintext := []u8{}
	tl.append_long(mut plaintext, state.server_salt)
	tl.append_long(mut plaintext, state.session_id)
	tl.append_long(mut plaintext, message.msg_id)
	tl.append_int(mut plaintext, message.seq_no)
	tl.append_int(mut plaintext, message.body.len)
	plaintext << message.body.clone()
	padding_len := encrypted_padding_length(plaintext.len)
	plaintext << backend.random_bytes(padding_len)!
	msg_key := derive_message_key(backend, state.auth_key, plaintext, outgoing)!
	key_iv := crypto.derive_message_aes_key_iv(backend, state.auth_key, msg_key, outgoing)!
	encrypted := backend.aes_ige_encrypt(plaintext, key_iv.key, key_iv.iv)!
	mut out := []u8{}
	tl.append_long(mut out, auth_key_id)
	out << msg_key
	out << encrypted
	return out
}

pub fn unpack_encrypted_message(state session.SessionState, payload []u8) !EncryptedMessage {
	if state.auth_key.len != crypto.auth_key_size {
		return error('session state auth key must be ${crypto.auth_key_size} bytes')
	}
	if payload.len < 8 + crypto.msg_key_size + crypto.aes_block_size {
		return error('encrypted MTProto payload is too short')
	}
	backend := crypto.default_backend()
	return unpack_encrypted_message_with_direction(state, payload, backend, false)!
}

fn unpack_encrypted_message_with_direction(state session.SessionState, payload []u8, backend crypto.Backend, outgoing bool) !EncryptedMessage {
	mut decoder := tl.new_decoder(payload)
	auth_key_id := decoder.read_long()!
	expected_auth_key_id := if state.auth_key_id != 0 {
		state.auth_key_id
	} else {
		crypto.derive_auth_key_id(backend, state.auth_key)!
	}
	if auth_key_id != expected_auth_key_id {
		return error('encrypted payload auth_key_id mismatch')
	}
	msg_key := decoder.read_raw(crypto.msg_key_size)!
	encrypted_data := decoder.read_remaining()
	if encrypted_data.len == 0 || encrypted_data.len % crypto.aes_block_size != 0 {
		return error('encrypted MTProto payload must be a non-empty 16-byte multiple')
	}
	key_iv := crypto.derive_message_aes_key_iv(backend, state.auth_key, msg_key, outgoing)!
	plaintext := backend.aes_ige_decrypt(encrypted_data, key_iv.key, key_iv.iv)!
	expected_msg_key := derive_message_key(backend, state.auth_key, plaintext, outgoing)!
	if expected_msg_key != msg_key {
		return error('encrypted payload msg_key mismatch')
	}
	mut plain_decoder := tl.new_decoder(plaintext)
	server_salt := plain_decoder.read_long()!
	session_id := plain_decoder.read_long()!
	if session_id != state.session_id {
		return error('encrypted payload session_id mismatch')
	}
	msg_id := plain_decoder.read_long()!
	seq_no := plain_decoder.read_int()!
	body_len := plain_decoder.read_int()!
	if body_len < 0 || body_len > plain_decoder.remaining() {
		return error('encrypted payload message body length is invalid')
	}
	body := plain_decoder.read_raw(body_len)!
	padding := plain_decoder.read_remaining()
	if padding.len < 12 || padding.len > 1024 {
		return error('encrypted payload padding must be between 12 and 1024 bytes')
	}
	return EncryptedMessage{
		server_salt: server_salt
		session_id:  session_id
		message:     transport.WireMessage{
			msg_id: msg_id
			seq_no: seq_no
			body:   body
		}
		padding:     padding
	}
}

fn (mut e SessionEngine) await_call_outcome(call PendingCall) !CallOutcome {
	for {
		if outcome := e.take_call_outcome(call.request_msg_id) {
			return outcome
		}
		if time.now().unix_milli() >= call.deadline_at_ms {
			e.drop_call(call.request_msg_id)
			return CallOutcome{
				timed_out: true
			}
		}
		e.flush_acks()!
		e.receive_once() or { e.fail_call(call.request_msg_id, err.msg()) }
	}
	return error('unreachable rpc await state')
}

fn (mut e SessionEngine) take_call_outcome(request_msg_id i64) ?CallOutcome {
	if request_msg_id !in e.pending_calls {
		return none
	}
	state := e.pending_calls[request_msg_id]
	if !state.done {
		return none
	}
	e.pending_calls.delete(request_msg_id)
	e.transport.state.mark_acknowledged([request_msg_id])
	return CallOutcome{
		has_result:     state.has_response
		result:         state.response
		has_rpc_error:  state.has_rpc_error
		rpc_error:      state.rpc_error
		transport_fail: state.transport_fail
	}
}

fn (mut e SessionEngine) fail_call(request_msg_id i64, message string) {
	if request_msg_id !in e.pending_calls {
		return
	}
	mut state := e.pending_calls[request_msg_id]
	state.transport_fail = message
	state.done = true
	e.pending_calls[request_msg_id] = state
}

fn (mut e SessionEngine) drop_call(request_msg_id i64) {
	if request_msg_id in e.pending_calls {
		e.pending_calls.delete(request_msg_id)
	}
	e.transport.state.mark_acknowledged([request_msg_id])
}

fn (mut e SessionEngine) receive_once() ! {
	payload := e.transport.receive_frame()!
	incoming := unpack_encrypted_message(e.session_state(), payload)!
	e.transport.state.server_salt = incoming.server_salt
	e.transport.state.observe_server_message(incoming.message.msg_id)
	e.handle_wire_message(incoming.message)!
}

fn (mut e SessionEngine) handle_wire_message(message transport.WireMessage) ! {
	if is_message_container(message.body) {
		container := transport.decode_message_container(message.body)!
		for inner in container.messages {
			e.handle_wire_message(inner)!
		}
		return
	}
	if e.config.auto_ack && message.requires_ack() {
		e.transport.state.queue_ack(message.msg_id)
	}
	object := tl.decode_mtproto_object(message.body)!
	e.handle_object(message, object)!
}

fn (mut e SessionEngine) handle_object(message transport.WireMessage, object tl.Object) ! {
	match object {
		tl.GzipPacked {
			e.handle_object(message, object.object)!
		}
		tl.MsgsAck {
			e.transport.state.mark_acknowledged(object.msg_ids)
		}
		tl.BadServerSalt {
			resends := e.transport.state.apply_bad_server_salt(object)
			e.send_resend_messages(resends)!
		}
		tl.BadMsgNotification {
			resends := e.transport.state.apply_bad_msg_notification(object)
			e.send_resend_messages(resends)!
		}
		tl.NewSessionCreated {
			e.transport.state.apply_new_session(object)
		}
		tl.MsgResendReq {
			mut resends := []transport.WireMessage{}
			for message_id in object.msg_ids {
				if resend := e.transport.state.resend_pending(message_id) {
					resends << resend
				}
			}
			e.send_resend_messages(resends)!
		}
		tl.RpcResult {
			e.transport.state.mark_acknowledged([object.req_msg_id])
			e.resolve_rpc_result(object)
		}
		tl.Pong {
			e.transport.state.mark_acknowledged([object.msg_id])
		}
		tl.UpdateShort {
			e.inbound_updates << object
		}
		tl.UpdateShortMessage {
			e.inbound_updates << object
		}
		tl.UpdateShortChatMessage {
			e.inbound_updates << object
		}
		tl.UpdateShortSentMessage {
			e.inbound_updates << object
		}
		tl.Updates {
			e.inbound_updates << object
		}
		tl.UpdatesCombined {
			e.inbound_updates << object
		}
		tl.UpdatesTooLong {
			e.inbound_updates << object
		}
		else {}
	}
}

fn (mut e SessionEngine) resolve_rpc_result(result tl.RpcResult) {
	if result.req_msg_id !in e.pending_calls {
		return
	}
	mut pending := e.pending_calls[result.req_msg_id]
	match result.result {
		tl.GzipPacked {
			pending.response = result.result.object
			pending.has_response = true
		}
		tl.RpcError {
			pending.rpc_error = result.result
			pending.has_rpc_error = true
		}
		else {
			pending.response = result.result
			pending.has_response = true
		}
	}
	pending.done = true
	e.pending_calls[result.req_msg_id] = pending
}

fn (mut e SessionEngine) flush_acks() ! {
	if !e.config.auto_ack {
		return
	}
	ack_ids := e.transport.state.drain_ack_ids()
	if ack_ids.len == 0 {
		return
	}
	ack_message := e.transport.state.build_object_message(tl.MsgsAck{
		msg_ids: ack_ids
	}, false, false)!
	e.send_wire_message(ack_message)!
}

fn (mut e SessionEngine) send_resend_messages(messages []transport.WireMessage) ! {
	for message in messages {
		e.send_wire_message(message)!
	}
}

fn (mut e SessionEngine) send_wire_message(message transport.WireMessage) ! {
	payload := pack_encrypted_message(e.session_state(), message)!
	e.transport.send_frame(payload)!
}

fn (mut e SessionEngine) resend_in_flight() ! {
	resends := e.transport.state.resend_all_pending()
	e.send_resend_messages(resends)!
}

fn (e SessionEngine) normalized_options(options CallOptions) CallOptions {
	return CallOptions{
		timeout_ms:   if options.timeout_ms > 0 {
			options.timeout_ms
		} else {
			e.config.default_timeout_ms
		}
		requires_ack: options.requires_ack
		can_retry:    options.can_retry
	}
}

fn (e SessionEngine) build_attempt_context(function_name string, request_msg_id i64, attempt int, timeout_ms int) AttemptContext {
	if endpoint := e.transport.current_endpoint() {
		return AttemptContext{
			function_name:    function_name
			request_msg_id:   request_msg_id
			attempt:          attempt
			timeout_ms:       timeout_ms
			current_dc_id:    endpoint.id
			current_host:     endpoint.host
			current_port:     endpoint.port
			current_is_media: endpoint.is_media
		}
	}
	return AttemptContext{
		function_name:  function_name
		request_msg_id: request_msg_id
		attempt:        attempt
		timeout_ms:     timeout_ms
		current_dc_id:  e.state.dc_id
	}
}

fn (e SessionEngine) pending_call_context(call PendingCall) AttemptContext {
	if call.request_msg_id in e.pending_calls {
		pending := e.pending_calls[call.request_msg_id]
		return e.build_attempt_context(pending.function_name, call.request_msg_id, 1,
			call.timeout_ms)
	}
	return e.build_attempt_context('', call.request_msg_id, 1, call.timeout_ms)
}

fn (e SessionEngine) run_before_send_hooks(context AttemptContext, function tl.Function) ! {
	for middleware in e.config.middlewares {
		middleware.before_send(context, function)!
	}
}

fn (e SessionEngine) apply_result_hooks(context AttemptContext, result tl.Object) MiddlewareAction {
	mut action := MiddlewareAction{}
	for middleware in e.config.middlewares {
		candidate := middleware.after_result(context, result)
		if candidate.kind != .proceed {
			action = candidate
		}
	}
	return action
}

fn (e SessionEngine) resolve_rpc_error_action(context AttemptContext, rpc_error tl.RpcError, can_retry bool) MiddlewareAction {
	mut action := default_rpc_error_action(rpc_error, can_retry)
	for middleware in e.config.middlewares {
		candidate := middleware.after_rpc_error(context, rpc_error)
		if candidate.kind != .proceed {
			action = candidate
		}
	}
	return action
}

fn (e SessionEngine) resolve_transport_error_action(context AttemptContext, message string, can_retry bool) MiddlewareAction {
	mut action := if can_retry {
		MiddlewareAction{
			kind: .retry
		}
	} else {
		MiddlewareAction{
			kind: .fail
		}
	}
	for middleware in e.config.middlewares {
		candidate := middleware.after_transport_error(context, message)
		if candidate.kind != .proceed {
			action = candidate
		}
	}
	return action
}

fn (e SessionEngine) emit_debug(event DebugEvent) {
	e.config.debug_logger.emit(event)
}

fn (mut e SessionEngine) prepare_retry(action MiddlewareAction) ! {
	if action.delay_ms > 0 {
		time.sleep(time.Duration(action.delay_ms) * time.millisecond)
	}
	if action.kind == .migrate_dc {
		e.apply_dc_migration(action.dc_id)!
		return
	}
	if !e.transport.is_connected() {
		e.connect()!
		return
	}
	if e.config.auto_reconnect {
		e.reconnect()!
	}
}

fn (mut e SessionEngine) apply_dc_migration(dc_id int) ! {
	if dc_id == 0 {
		return error('dc migration target must be non-zero')
	}
	_ = e.transport.select_endpoint(dc_id)!
	e.current_dc_id = dc_id
	e.reconnect()!
}

fn default_rpc_error_action(rpc_error tl.RpcError, can_retry bool) MiddlewareAction {
	if info := rate_limit_info(rpc_error) {
		if can_retry {
			return MiddlewareAction{
				kind:     .retry
				delay_ms: info.wait_seconds * 1_000
			}
		}
	}
	if dc_id := migration_dc_id(rpc_error) {
		return MiddlewareAction{
			kind:  .migrate_dc
			dc_id: dc_id
		}
	}
	return MiddlewareAction{
		kind: .fail
	}
}

fn parse_suffix_number(value string, prefix string) ?int {
	if !value.starts_with(prefix) {
		return none
	}
	suffix := value[prefix.len..]
	if suffix.len == 0 {
		return none
	}
	number := suffix.int()
	if number <= 0 {
		return none
	}
	return number
}

fn is_message_container(data []u8) bool {
	return data.len >= 4
		&& (u32(data[0]) | (u32(data[1]) << 8) | (u32(data[2]) << 16) | (u32(data[3]) << 24)) == transport.msg_container_constructor_id
}

fn derive_message_key(backend crypto.Backend, auth_key []u8, plaintext []u8, outgoing bool) ![]u8 {
	if auth_key.len != crypto.auth_key_size {
		return error('auth key must be ${crypto.auth_key_size} bytes')
	}
	x := if outgoing { 0 } else { 8 }
	mut input := auth_key[88 + x..88 + x + 32].clone()
	input << plaintext
	hash := backend.sha256(input)!
	return hash[8..24].clone()
}

fn encrypted_padding_length(plaintext_len int) int {
	mut padding_len := 12
	for (plaintext_len + padding_len) % crypto.aes_block_size != 0 {
		padding_len++
	}
	return padding_len
}
