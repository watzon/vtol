module rpc

import crypto
import session
import time
import tl
import transport

struct ScriptedStream {
mut:
	read_buffer  []u8
	write_buffer []u8
	closed       bool
}

fn (mut s ScriptedStream) read(mut buf []u8) !int {
	if s.closed {
		return error('closed')
	}
	if s.read_buffer.len == 0 {
		return error('eof')
	}
	count := if buf.len < s.read_buffer.len { buf.len } else { s.read_buffer.len }
	for index in 0 .. count {
		buf[index] = s.read_buffer[index]
	}
	s.read_buffer = s.read_buffer[count..].clone()
	return count
}

fn (mut s ScriptedStream) write(data []u8) !int {
	if s.closed {
		return error('closed')
	}
	s.write_buffer << data.clone()
	return data.len
}

fn (mut s ScriptedStream) close() ! {
	s.closed = false
}

fn (mut s ScriptedStream) push_server_payload(payload []u8) {
	mut frame := []u8{}
	tl.append_u32(mut frame, u32(payload.len))
	frame << payload.clone()
	s.read_buffer << frame
}

struct FixedDialer {
	streams map[int]&ScriptedStream
}

fn (d FixedDialer) dial(endpoint transport.Endpoint, timeouts transport.Timeouts) !transport.Stream {
	if endpoint.id !in d.streams {
		return error('no scripted stream configured for endpoint ${endpoint.id}')
	}
	return d.streams[endpoint.id]
}

fn test_pack_and_unpack_encrypted_message_roundtrip() {
	state := make_test_session_state()
	message := transport.WireMessage{
		msg_id: 100
		seq_no: 1
		body:   tl.Ping{
			ping_id: 55
		}.encode() or { panic(err) }
	}

	payload := pack_encrypted_message(state, message) or { panic(err) }
	decoded := unpack_encrypted_message_with_direction(state, payload, crypto.default_backend(),
		true) or { panic(err) }

	assert decoded.server_salt == state.server_salt
	assert decoded.session_id == state.session_id
	assert decoded.message.msg_id == message.msg_id
	assert decoded.message.seq_no == message.seq_no
	assert decoded.message.body == message.body
	assert decoded.padding.len >= 12
}

fn test_begin_invoke_restores_session_from_store_and_correlates_rpc_result() {
	state := make_test_session_state()
	mut store := session.new_memory_store()
	store.save(state) or { panic(err) }
	mut stream := &ScriptedStream{}
	mut engine := new_test_rpc_engine_from_store(mut store, {
		1: stream
	})

	call := engine.begin_invoke(tl.Ping{
		ping_id: 77
	}, CallOptions{
		timeout_ms: 250
	}) or { panic(err) }

	response := tl.RpcResult{
		req_msg_id: call.request_msg_id
		result:     tl.Pong{
			msg_id:  call.request_msg_id
			ping_id: 77
		}
	}
	stream.push_server_payload(server_payload(state, transport.WireMessage{
		msg_id: server_message_id(1_000)
		seq_no: 1
		body:   response.encode() or { panic(err) }
	}))

	result := engine.await_call(call) or { panic(err) }
	match result {
		tl.Pong {
			assert result.msg_id == call.request_msg_id
			assert result.ping_id == 77
		}
		else {
			assert false
		}
	}
	assert engine.pending_count() == 0
	assert engine.session_state().session_id == state.session_id
}

fn test_auto_ack_flushes_after_processing_inbound_container() {
	state := make_test_session_state()
	mut stream := &ScriptedStream{}
	mut engine := new_test_rpc_engine(state, {
		1: stream
	})

	call := engine.begin_invoke(tl.Ping{
		ping_id: 88
	}, CallOptions{
		timeout_ms: 250
	}) or { panic(err) }

	reply_message_id := server_message_id(1_000)
	aux_message_id := server_message_id(2_000)
	container := transport.MessageContainer{
		messages: [
			transport.WireMessage{
				msg_id: reply_message_id
				seq_no: 1
				body:   tl.RpcResult{
					req_msg_id: call.request_msg_id
					result:     tl.Pong{
						msg_id:  call.request_msg_id
						ping_id: 88
					}
				}.encode() or { panic(err) }
			},
			transport.WireMessage{
				msg_id: aux_message_id
				seq_no: 1
				body:   tl.Pong{
					msg_id:  500
					ping_id: 999
				}.encode() or { panic(err) }
			},
		]
	}
	stream.push_server_payload(server_payload(state, transport.WireMessage{
		msg_id: server_message_id(3_000)
		seq_no: 1
		body:   container.encode()
	}))

	_ = engine.await_call(call) or { panic(err) }
	next_call := engine.begin_invoke(tl.Ping{
		ping_id: 99
	}, CallOptions{
		timeout_ms: 250
	}) or { panic(err) }
	assert next_call.request_msg_id != 0

	client_payloads := decode_client_payloads(stream.write_buffer) or { panic(err) }
	assert client_payloads.len == 3

	ack_packet := unpack_encrypted_message_with_direction(state, client_payloads[1], crypto.default_backend(),
		true) or { panic(err) }
	ack_object := tl.decode_mtproto_object(ack_packet.message.body) or { panic(err) }
	match ack_object {
		tl.MsgsAck {
			assert ack_object.msg_ids == [reply_message_id, aux_message_id]
		}
		else {
			assert false
		}
	}
}

fn test_reconnect_resends_in_flight_messages() {
	state := make_test_session_state()
	mut stream := &ScriptedStream{}
	mut engine := new_test_rpc_engine(state, {
		1: stream
	})

	call := engine.begin_invoke(tl.Ping{
		ping_id: 123
	}, CallOptions{
		timeout_ms: 250
	}) or { panic(err) }
	engine.reconnect() or { panic(err) }

	client_payloads := decode_client_payloads(stream.write_buffer) or { panic(err) }
	assert client_payloads.len == 2
	resend_packet := unpack_encrypted_message_with_direction(state, client_payloads[1],
		crypto.default_backend(), true) or { panic(err) }
	assert resend_packet.message.msg_id == call.request_msg_id
	resend_object := tl.decode_mtproto_object(resend_packet.message.body) or { panic(err) }
	match resend_object {
		tl.Ping {
			assert resend_object.ping_id == 123
		}
		else {
			assert false
		}
	}
}

fn test_rpc_result_with_gzip_payload_is_unwrapped() {
	state := make_test_session_state()
	mut stream := &ScriptedStream{}
	mut engine := new_test_rpc_engine(state, {
		1: stream
	})

	call := engine.begin_invoke(tl.Ping{
		ping_id: 66
	}, CallOptions{
		timeout_ms: 250
	}) or { panic(err) }
	stream.push_server_payload(server_payload(state, transport.WireMessage{
		msg_id: server_message_id(1_000)
		seq_no: 1
		body:   tl.RpcResult{
			req_msg_id: call.request_msg_id
			result:     tl.GzipPacked{
				object: tl.Pong{
					msg_id:  call.request_msg_id
					ping_id: 66
				}
			}
		}.encode() or { panic(err) }
	}))

	result := engine.await_call(call) or { panic(err) }
	match result {
		tl.Pong {
			assert result.ping_id == 66
		}
		else {
			assert false
		}
	}
}

fn test_pump_once_collects_inbound_updates() {
	state := make_test_session_state()
	mut stream := &ScriptedStream{}
	mut engine := new_test_rpc_engine(state, {
		1: stream
	})

	stream.push_server_payload(server_payload(state, transport.WireMessage{
		msg_id: server_message_id(1_000)
		seq_no: 1
		body:   tl.UpdateShortSentMessage{
			id:              7
			pts:             1
			pts_count:       1
			date:            123
			media:           tl.UnknownMessageMediaType{}
			has_media_value: false
		}.encode() or { panic(err) }
	}))

	engine.pump_once() or { panic(err) }
	inbound := engine.drain_updates()

	assert inbound.len == 1
	first := inbound[0]
	match first {
		tl.UpdateShortSentMessage {
			assert first.pts == 1
			assert first.date == 123
		}
		else {
			assert false
		}
	}
}

fn make_test_session_state() session.SessionState {
	auth_key := []u8{len: crypto.auth_key_size, init: u8((index * 17 + 3) % 251)}
	auth_key_id := crypto.derive_auth_key_id(crypto.default_backend(), auth_key) or { panic(err) }
	layer := tl.current_layer_info()
	return session.SessionState{
		dc_id:           1
		auth_key:        auth_key
		auth_key_id:     auth_key_id
		server_salt:     55
		session_id:      99
		layer:           layer.layer
		schema_revision: layer.schema_revision
		created_at:      time.now().unix()
	}
}

fn new_test_rpc_engine(state session.SessionState, streams map[int]&ScriptedStream) SessionEngine {
	mut engine := transport.new_engine(transport.EngineConfig{
		endpoints: [
			transport.Endpoint{
				id:   1
				host: '127.0.0.1'
				port: 443
			},
		]
		mode:      .intermediate
		retry:     transport.RetryPolicy{
			max_attempts: 1
			backoff_ms:   0
		}
	}) or { panic(err) }
	engine.set_dialer(FixedDialer{
		streams: streams.clone()
	})
	return new_session_engine(engine, state, EngineConfig{
		default_timeout_ms: 250
		max_retry_attempts: 2
	}) or { panic(err) }
}

fn new_test_rpc_engine_from_store(mut store session.Store, streams map[int]&ScriptedStream) SessionEngine {
	mut engine := transport.new_engine(transport.EngineConfig{
		endpoints: [
			transport.Endpoint{
				id:   1
				host: '127.0.0.1'
				port: 443
			},
		]
		mode:      .intermediate
		retry:     transport.RetryPolicy{
			max_attempts: 1
			backoff_ms:   0
		}
	}) or { panic(err) }
	engine.set_dialer(FixedDialer{
		streams: streams.clone()
	})
	return new_session_engine_from_store(engine, mut store, EngineConfig{
		default_timeout_ms: 250
		max_retry_attempts: 2
	}) or { panic(err) }
}

fn server_payload(state session.SessionState, message transport.WireMessage) []u8 {
	return pack_encrypted_message_with_direction(state, message, crypto.default_backend(),
		false) or { panic(err) }
}

fn server_message_id(offset_ms int) i64 {
	return transport.message_id_from_unix_milli(time.now().unix_milli() + offset_ms)
}

fn decode_client_payloads(buffer []u8) ![][]u8 {
	if buffer.len < 4 {
		return error('client write buffer is missing the intermediate transport marker')
	}
	mut offset := 0
	mut payloads := [][]u8{}
	for offset < buffer.len {
		if offset + 4 <= buffer.len
			&& (u32(buffer[offset]) | (u32(buffer[offset + 1]) << 8) | (u32(buffer[offset + 2]) << 16) | (u32(buffer[offset + 3]) << 24)) == transport.intermediate_transport_marker {
			offset += 4
			continue
		}
		if offset + 4 > buffer.len {
			return error('client write buffer ended before frame length')
		}
		length := int(u32(buffer[offset]) | (u32(buffer[offset + 1]) << 8) | (u32(buffer[offset + 2]) << 16) | (u32(buffer[
			offset + 3]) << 24))
		offset += 4
		if offset + length > buffer.len {
			return error('client write buffer ended before frame payload')
		}
		payloads << buffer[offset..offset + length].clone()
		offset += length
	}
	return payloads
}
