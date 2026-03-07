module transport

import tl

struct MemoryStream {
mut:
	read_buffer  []u8
	write_buffer []u8
	closed       bool
}

fn (mut s MemoryStream) read(mut buf []u8) !int {
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

fn (mut s MemoryStream) write(data []u8) !int {
	if s.closed {
		return error('closed')
	}
	s.write_buffer << data.clone()
	return data.len
}

fn (mut s MemoryStream) close() ! {
	s.closed = true
}

struct StubDialer {
	fail_endpoint_ids []int
	streams           map[int]MemoryStream
}

fn (d StubDialer) dial(endpoint Endpoint, timeouts Timeouts) !Stream {
	if endpoint.id in d.fail_endpoint_ids {
		return error('dial failed for endpoint ${endpoint.id}')
	}
	return d.streams[endpoint.id]
}

fn test_abridged_frame_codec_encodes_transport_marker_once() {
	mut codec := new_frame_codec(.abridged)
	payload := [u8(1), 2, 3, 4]
	frame_one := codec.encode_frame(payload) or { panic(err) }
	frame_two := codec.encode_frame(payload) or { panic(err) }

	assert frame_one == [u8(0xef), 1, 1, 2, 3, 4]
	assert frame_two == [u8(1), 1, 2, 3, 4]
}

fn test_abridged_frame_codec_reads_short_frame() {
	mut codec := new_frame_codec(.abridged)
	mut stream := MemoryStream{
		read_buffer: [u8(1), 9, 8, 7, 6]
	}

	payload := codec.read_frame(mut stream) or { panic(err) }
	assert payload == [u8(9), 8, 7, 6]
}

fn test_intermediate_frame_codec_roundtrips_payload() {
	mut codec := new_frame_codec(.intermediate)
	payload := [u8(4), 3, 2, 1, 0]
	frame := codec.encode_frame(payload) or { panic(err) }

	assert frame[..8] == [u8(0xee), 0xee, 0xee, 0xee, 5, 0, 0, 0]

	mut stream := MemoryStream{
		read_buffer: frame[4..].clone()
	}
	decoded := codec.read_frame(mut stream) or { panic(err) }
	assert decoded == payload
}

fn test_full_frame_codec_roundtrips_and_verifies_crc() {
	mut codec := new_frame_codec(.full)
	payload := [u8(10), 20, 30, 40]
	frame := codec.encode_frame(payload) or { panic(err) }

	assert frame[..4] == [u8(0xdd), 0xdd, 0xdd, 0xdd]

	mut stream := MemoryStream{
		read_buffer: frame[4..].clone()
	}
	decoded := codec.read_frame(mut stream) or { panic(err) }
	assert decoded == payload
}

fn test_wire_message_and_packet_roundtrip() {
	message := WireMessage{
		msg_id: 100
		seq_no: 3
		body:   [u8(7), 7, 7, 7]
	}
	decoded_message := decode_wire_message(message.encode()) or { panic(err) }
	assert decoded_message.msg_id == 100
	assert decoded_message.seq_no == 3
	assert decoded_message.body == [u8(7), 7, 7, 7]

	packet := UnencryptedPacket{
		auth_key_id: 0
		message_id:  100
		body:        message.encode()
	}
	decoded_packet := decode_unencrypted_packet(packet.encode()) or { panic(err) }
	assert decoded_packet.message_id == 100
	assert decoded_packet.body == message.encode()
}

fn test_message_container_roundtrip() {
	ping_a := tl.Ping{
		ping_id: 11
	}
	ping_b := tl.Ping{
		ping_id: 22
	}
	container := MessageContainer{
		messages: [
			WireMessage{
				msg_id: 1
				seq_no: 1
				body:   ping_a.encode() or { panic(err) }
			},
			WireMessage{
				msg_id: 2
				seq_no: 3
				body:   ping_b.encode() or { panic(err) }
			},
		]
	}

	decoded := decode_message_container(container.encode()) or { panic(err) }
	assert decoded.messages.len == 2
	assert decoded.messages[0].msg_id == 1
	assert decoded.messages[1].seq_no == 3
	assert tl.decode_object(decoded.messages[0].body) or { panic(err) } is tl.Ping
}

fn test_message_state_tracks_seq_acks_and_clock_skew() {
	mut state := new_message_state(123)
	content_message := state.record_outbound([u8(1), 2, 3, 4], true, true)
	control_message := state.record_outbound([u8(5), 6, 7, 8], false, false)

	assert content_message.seq_no == 1
	assert control_message.seq_no == 2
	assert state.pending_count() == 1

	state.queue_ack(99)
	state.queue_ack(99)
	assert state.drain_ack_ids() == [i64(99)]

	server_message_id := message_id_from_unix_milli(1_700_000_000_000)
	offset_ms := state.observe_server_message(server_message_id)
	assert state.last_server_msg_id == server_message_id
	assert offset_ms == state.time_offset_ms

	acked := state.mark_acknowledged([content_message.msg_id])
	assert acked == 1
	assert state.pending_count() == 0
}

fn test_message_state_resends_bad_messages_and_salt_updates() {
	mut state := new_message_state(0)
	message := state.record_outbound([u8(1), 1, 1, 1], true, true)

	resends := state.apply_bad_server_salt(tl.BadServerSalt{
		bad_msg_id:      message.msg_id
		bad_msg_seqno:   message.seq_no
		error_code:      48
		new_server_salt: 55
	})

	assert state.server_salt == 55
	assert resends.len == 1
	assert resends[0].msg_id != message.msg_id
	assert resends[0].seq_no != message.seq_no
	assert resends[0].body == message.body
}

fn test_message_state_regenerates_bad_msg_notifications() {
	mut state := new_message_state(0)
	message := state.record_outbound([u8(9), 9, 9, 9], true, true)

	resends := state.apply_bad_msg_notification(tl.BadMsgNotification{
		bad_msg_id:    message.msg_id
		bad_msg_seqno: message.seq_no
		error_code:    16
	})

	assert resends.len == 1
	assert resends[0].msg_id != message.msg_id
	assert resends[0].seq_no != message.seq_no
	assert resends[0].body == message.body
}

fn test_message_id_conversion_roundtrips_large_timestamps() {
	unix_ms := i64(1_700_000_000_000)
	message_id := message_id_from_unix_milli(unix_ms)

	assert message_id > i64(1_000_000_000_000_000_000)
	assert message_id % 4 == 0
	assert unix_milli_from_message_id(message_id) == unix_ms
}

fn test_engine_failover_uses_next_endpoint() {
	mut engine := new_engine(EngineConfig{
		endpoints: [
			Endpoint{
				id:   1
				host: '127.0.0.1'
				port: 443
			},
			Endpoint{
				id:   2
				host: '127.0.0.2'
				port: 443
			},
		]
		retry:     RetryPolicy{
			max_attempts: 1
			backoff_ms:   0
		}
	}) or { panic(err) }
	dialer := StubDialer{
		fail_endpoint_ids: [1]
		streams:           {
			2: MemoryStream{}
		}
	}
	engine.set_dialer(dialer)

	endpoint := engine.connect() or { panic(err) }
	assert endpoint.id == 2
}
