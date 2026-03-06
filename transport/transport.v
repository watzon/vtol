module transport

import hash.crc32
import net
import time
import tl

pub const abridged_transport_marker = u8(0xef)
pub const intermediate_transport_marker = u32(0xeeeeeeee)
pub const full_transport_marker = u32(0xdddddddd)
pub const msg_container_constructor_id = u32(0x73f1f8dc)

pub enum Mode {
	abridged
	intermediate
	full
}

pub enum EventKind {
	frame_sent
	frame_received
	reconnect_attempt
	reconnect_succeeded
	reconnect_failed
	failover
	pending_acked
	pending_resend
	salt_updated
	clock_skew_adjusted
}

pub enum DisconnectReason {
	requested
	remote_closed
	dial_failed
	timeout
	protocol_error
	io_error
}

pub struct Endpoint {
pub:
	id       int
	host     string
	port     int
	is_media bool
}

pub struct RetryPolicy {
pub:
	max_attempts int = 3
	backoff_ms   int = 250
}

pub struct Timeouts {
pub:
	connect_ms int = 5_000
	read_ms    int = 15_000
	write_ms   int = 15_000
}

pub struct Event {
pub:
	kind        EventKind
	endpoint_id int
	bytes       int
	attempt     int
	reason      string
	message_id  i64
	seq_no      int
	offset_ms   i64
}

pub interface Observer {
	emit(event Event)
}

struct NoopObserver {}

fn (n NoopObserver) emit(event Event) {}

pub interface Stream {
mut:
	read(mut []u8) !int
	write([]u8) !int
	close() !
}

pub interface Dialer {
	dial(endpoint Endpoint, timeouts Timeouts) !Stream
}

struct NullStream {}

fn (mut s NullStream) read(mut buf []u8) !int {
	return error('transport stream is not connected')
}

fn (mut s NullStream) write(data []u8) !int {
	return error('transport stream is not connected')
}

fn (mut s NullStream) close() ! {}

struct TcpStream {
mut:
	conn &net.TcpConn
}

fn (mut s TcpStream) read(mut buf []u8) !int {
	return s.conn.read(mut buf)!
}

fn (mut s TcpStream) write(data []u8) !int {
	return s.conn.write(data)!
}

fn (mut s TcpStream) close() ! {
	s.conn.close()!
}

pub struct TcpDialer {}

pub fn (d TcpDialer) dial(endpoint Endpoint, timeouts Timeouts) !Stream {
	address := '${endpoint.host}:${endpoint.port}'
	mut conn := net.dial_tcp(address)!
	if timeouts.read_ms > 0 {
		conn.set_read_timeout(time.Duration(timeouts.read_ms) * time.millisecond)
	}
	if timeouts.write_ms > 0 {
		conn.set_write_timeout(time.Duration(timeouts.write_ms) * time.millisecond)
	}
	return TcpStream{
		conn: conn
	}
}

pub struct WireMessage {
pub:
	msg_id i64
	seq_no int
	body   []u8
}

pub struct PendingMessage {
pub:
	message      WireMessage
	requires_ack bool
	sent_at_ms   i64
mut:
	resend_count int
}

pub struct UnencryptedPacket {
pub:
	auth_key_id i64
	message_id  i64
	body        []u8
}

pub struct MessageContainer {
pub:
	messages []WireMessage
}

pub struct MessageState {
pub mut:
	server_salt    i64
	session_id     i64
	time_offset_ms i64
mut:
	content_related_count int
	last_msg_id           i64
	last_server_msg_id    i64
	pending               map[i64]PendingMessage
	pending_acks          []i64
}

pub struct EngineConfig {
pub:
	endpoints []Endpoint
	mode      Mode        = .abridged
	retry     RetryPolicy = RetryPolicy{}
	timeouts  Timeouts    = Timeouts{}
}

pub struct Engine {
pub:
	mode     Mode
	retry    RetryPolicy
	timeouts Timeouts
mut:
	endpoints      []Endpoint
	endpoint_index int
	codec          FrameCodec
	stream         Stream   = NullStream{}
	dialer         Dialer   = TcpDialer{}
	observer       Observer = NoopObserver{}
	connected      bool
pub mut:
	state MessageState
}

pub struct FrameCodec {
pub:
	mode Mode
mut:
	wrote_client_marker bool
	full_send_seq_no    int
}

pub fn new_frame_codec(mode Mode) FrameCodec {
	return FrameCodec{
		mode: mode
	}
}

pub fn new_message_state(session_id i64) MessageState {
	return MessageState{
		session_id: session_id
		pending:    map[i64]PendingMessage{}
	}
}

pub fn new_engine(config EngineConfig) !Engine {
	if config.endpoints.len == 0 {
		return error('transport engine requires at least one endpoint')
	}
	return Engine{
		mode:      config.mode
		retry:     config.retry
		timeouts:  config.timeouts
		endpoints: config.endpoints.clone()
		codec:     new_frame_codec(config.mode)
		state:     new_message_state(0)
	}
}

pub fn (mut e Engine) set_dialer(dialer Dialer) {
	e.dialer = dialer
}

pub fn (mut e Engine) set_observer(observer Observer) {
	e.observer = observer
}

pub fn (e Engine) current_endpoint() ?Endpoint {
	if e.endpoints.len == 0 {
		return none
	}
	return e.endpoints[e.endpoint_index]
}

pub fn (mut e Engine) connect() !Endpoint {
	for offset in 0 .. e.endpoints.len {
		index := (e.endpoint_index + offset) % e.endpoints.len
		endpoint := e.endpoints[index]
		for attempt in 1 .. e.retry.max_attempts + 1 {
			e.observer.emit(Event{
				kind:        .reconnect_attempt
				endpoint_id: endpoint.id
				attempt:     attempt
			})
			stream := e.dialer.dial(endpoint, e.timeouts) or {
				e.observer.emit(Event{
					kind:        .reconnect_failed
					endpoint_id: endpoint.id
					attempt:     attempt
					reason:      err.msg()
				})
				if attempt < e.retry.max_attempts && e.retry.backoff_ms > 0 {
					time.sleep(time.Duration(e.retry.backoff_ms) * time.millisecond)
				}
				continue
			}
			e.stream = stream
			e.endpoint_index = index
			e.connected = true
			e.codec = new_frame_codec(e.mode)
			e.observer.emit(Event{
				kind:        .reconnect_succeeded
				endpoint_id: endpoint.id
				attempt:     attempt
			})
			return endpoint
		}
		e.observer.emit(Event{
			kind:        .failover
			endpoint_id: endpoint.id
			reason:      'endpoint exhausted retry policy'
		})
	}
	return error('transport engine could not connect to any configured endpoint')
}

pub fn (mut e Engine) reconnect(reason DisconnectReason) !Endpoint {
	if e.connected {
		e.disconnect() or {}
	}
	return e.connect() or { return error('transport reconnect failed: ${reason}') }
}

pub fn (mut e Engine) disconnect() ! {
	if !e.connected {
		return
	}
	e.stream.close()!
	e.connected = false
	e.stream = NullStream{}
}

pub fn (mut e Engine) send_frame(payload []u8) ! {
	if !e.connected {
		return error('transport engine is not connected')
	}
	frame := e.codec.encode_frame(payload)!
	write_all(mut e.stream, frame)!
	endpoint_id := if endpoint := e.current_endpoint() { endpoint.id } else { 0 }
	e.observer.emit(Event{
		kind:        .frame_sent
		endpoint_id: endpoint_id
		bytes:       payload.len
	})
}

pub fn (mut e Engine) receive_frame() ![]u8 {
	if !e.connected {
		return error('transport engine is not connected')
	}
	payload := e.codec.read_frame(mut e.stream)!
	endpoint_id := if endpoint := e.current_endpoint() { endpoint.id } else { 0 }
	e.observer.emit(Event{
		kind:        .frame_received
		endpoint_id: endpoint_id
		bytes:       payload.len
	})
	return payload
}

pub fn (mut e Engine) send_packet(packet UnencryptedPacket) ! {
	e.send_frame(packet.encode())!
}

pub fn (mut e Engine) receive_packet() !UnencryptedPacket {
	payload := e.receive_frame()!
	return decode_unencrypted_packet(payload)!
}

pub fn (m WireMessage) requires_ack() bool {
	return (m.seq_no % 2) == 1
}

pub fn (m WireMessage) encode() []u8 {
	mut out := []u8{}
	tl.append_long(mut out, m.msg_id)
	tl.append_int(mut out, m.seq_no)
	tl.append_int(mut out, m.body.len)
	out << m.body.clone()
	return out
}

pub fn decode_wire_message(data []u8) !WireMessage {
	mut decoder := tl.new_decoder(data)
	msg_id := decoder.read_long()!
	seq_no := decoder.read_int()!
	length := decoder.read_int()!
	if length < 0 {
		return error('wire message length must not be negative')
	}
	body := decoder.read_remaining()
	if body.len != length {
		return error('wire message body length mismatch: expected ${length}, got ${body.len}')
	}
	return WireMessage{
		msg_id: msg_id
		seq_no: seq_no
		body:   body
	}
}

pub fn (p UnencryptedPacket) encode() []u8 {
	mut out := []u8{}
	tl.append_long(mut out, p.auth_key_id)
	tl.append_long(mut out, p.message_id)
	tl.append_int(mut out, p.body.len)
	out << p.body.clone()
	return out
}

pub fn decode_unencrypted_packet(data []u8) !UnencryptedPacket {
	mut decoder := tl.new_decoder(data)
	auth_key_id := decoder.read_long()!
	message_id := decoder.read_long()!
	body_length := decoder.read_int()!
	body := decoder.read_remaining()
	if body_length < 0 {
		return error('unencrypted packet body length must not be negative')
	}
	if body.len != body_length {
		return error('unencrypted packet body length mismatch: expected ${body_length}, got ${body.len}')
	}
	return UnencryptedPacket{
		auth_key_id: auth_key_id
		message_id:  message_id
		body:        body
	}
}

pub fn (c MessageContainer) encode() []u8 {
	mut out := []u8{}
	tl.append_u32(mut out, msg_container_constructor_id)
	tl.append_int(mut out, c.messages.len)
	for message in c.messages {
		out << message.encode()
	}
	return out
}

pub fn decode_message_container(data []u8) !MessageContainer {
	mut decoder := tl.new_decoder(data)
	constructor := decoder.read_u32()!
	if constructor != msg_container_constructor_id {
		return error('unexpected message container constructor ${constructor:08x}')
	}
	count := decoder.read_int()!
	if count < 0 {
		return error('message container count must not be negative')
	}
	mut messages := []WireMessage{cap: count}
	for _ in 0 .. count {
		msg_id := decoder.read_long()!
		seq_no := decoder.read_int()!
		body_len := decoder.read_int()!
		if body_len < 0 || body_len > decoder.remaining() {
			return error('message container body length is invalid')
		}
		body := decoder.read_raw(body_len)!
		messages << WireMessage{
			msg_id: msg_id
			seq_no: seq_no
			body:   body
		}
	}
	if decoder.remaining() != 0 {
		return error('message container has trailing bytes')
	}
	return MessageContainer{
		messages: messages
	}
}

pub fn unix_milli_from_message_id(message_id i64) i64 {
	return i64((u64(message_id) * u64(1000)) >> 32)
}

pub fn message_id_from_unix_milli(unix_ms i64) i64 {
	mut message_id := i64((u64(unix_ms) << 32) / u64(1000))
	message_id &= i64(~u64(3))
	return message_id
}

pub fn (mut s MessageState) next_message_id() i64 {
	now_ms := time.now().unix_milli() + s.time_offset_ms
	mut next := message_id_from_unix_milli(now_ms)
	if next <= s.last_msg_id {
		next = s.last_msg_id + 4
	}
	s.last_msg_id = next
	return next
}

pub fn (mut s MessageState) observe_server_message(message_id i64) i64 {
	s.last_server_msg_id = message_id
	server_ms := unix_milli_from_message_id(message_id)
	offset_ms := server_ms - time.now().unix_milli()
	s.time_offset_ms = offset_ms
	return offset_ms
}

pub fn (mut s MessageState) record_outbound(body []u8, content_related bool, requires_ack bool) WireMessage {
	seq_no := if content_related {
		value := s.content_related_count * 2 + 1
		s.content_related_count++
		value
	} else {
		s.content_related_count * 2
	}
	message := WireMessage{
		msg_id: s.next_message_id()
		seq_no: seq_no
		body:   body.clone()
	}
	if requires_ack {
		s.pending[message.msg_id] = PendingMessage{
			message:      message
			requires_ack: requires_ack
			sent_at_ms:   time.now().unix_milli()
		}
	}
	return message
}

pub fn (mut s MessageState) build_object_message(object tl.Object, content_related bool, requires_ack bool) !WireMessage {
	return s.record_outbound(object.encode()!, content_related, requires_ack)
}

pub fn (mut s MessageState) mark_acknowledged(message_ids []i64) int {
	mut acked := 0
	for message_id in message_ids {
		if message_id in s.pending {
			s.pending.delete(message_id)
			acked++
		}
	}
	return acked
}

pub fn (s MessageState) pending_count() int {
	return s.pending.len
}

pub fn (mut s MessageState) queue_ack(message_id i64) {
	if message_id !in s.pending_acks {
		s.pending_acks << message_id
	}
}

pub fn (mut s MessageState) drain_ack_ids() []i64 {
	acked := s.pending_acks.clone()
	s.pending_acks = []i64{}
	return acked
}

pub fn (mut s MessageState) resend_pending(message_id i64) ?WireMessage {
	if message_id !in s.pending {
		return none
	}
	mut pending := s.pending[message_id]
	pending.resend_count++
	s.pending[message_id] = pending
	return pending.message
}

pub fn (mut s MessageState) resend_all_pending() []WireMessage {
	mut messages := []WireMessage{}
	for message_id in s.pending.keys() {
		if message := s.resend_pending(message_id) {
			messages << message
		}
	}
	messages.sort(a.msg_id < b.msg_id)
	return messages
}

pub fn (mut s MessageState) apply_new_session(created tl.NewSessionCreated) {
	s.server_salt = created.server_salt
}

pub fn (mut s MessageState) apply_bad_server_salt(event tl.BadServerSalt) []WireMessage {
	s.server_salt = event.new_server_salt
	if resend := s.resend_pending(event.bad_msg_id) {
		return [resend]
	}
	return []WireMessage{}
}

pub fn (mut s MessageState) apply_bad_msg_notification(event tl.BadMsgNotification) []WireMessage {
	match event.error_code {
		16 {
			if s.last_server_msg_id != 0 {
				s.observe_server_message(s.last_server_msg_id)
			} else {
				s.time_offset_ms += 30_000
			}
		}
		17 {
			if s.last_server_msg_id != 0 {
				s.observe_server_message(s.last_server_msg_id)
			} else {
				s.time_offset_ms -= 30_000
			}
		}
		else {}
	}
	match event.error_code {
		16, 17, 32, 33, 34, 35, 48 {
			if resend := s.resend_pending(event.bad_msg_id) {
				return [resend]
			}
		}
		else {}
	}
	return []WireMessage{}
}

pub fn (mut c FrameCodec) encode_frame(payload []u8) ![]u8 {
	match c.mode {
		.abridged { return c.encode_abridged_frame(payload)! }
		.intermediate { return c.encode_intermediate_frame(payload)! }
		.full { return c.encode_full_frame(payload)! }
	}
}

pub fn (mut c FrameCodec) read_frame(mut stream Stream) ![]u8 {
	match c.mode {
		.abridged { return c.read_abridged_frame(mut stream)! }
		.intermediate { return c.read_intermediate_frame(mut stream)! }
		.full { return c.read_full_frame(mut stream)! }
	}
}

fn (mut c FrameCodec) encode_abridged_frame(payload []u8) ![]u8 {
	if payload.len % 4 != 0 {
		return error('abridged transport payload length must be divisible by 4')
	}
	mut frame := []u8{}
	if !c.wrote_client_marker {
		frame << abridged_transport_marker
		c.wrote_client_marker = true
	}
	words := payload.len / 4
	if words < 127 {
		frame << u8(words)
	} else {
		frame << u8(127)
		frame << u8(words & 0xff)
		frame << u8((words >> 8) & 0xff)
		frame << u8((words >> 16) & 0xff)
	}
	frame << payload.clone()
	return frame
}

fn (mut c FrameCodec) read_abridged_frame(mut stream Stream) ![]u8 {
	header := read_exact(mut stream, 1)!
	mut words := int(header[0])
	if words == 127 {
		extra := read_exact(mut stream, 3)!
		words = int(extra[0]) | int(u32(extra[1]) << 8) | int(u32(extra[2]) << 16)
	}
	if words <= 0 {
		return error('abridged transport frame length must be positive')
	}
	return read_exact(mut stream, words * 4)!
}

fn (mut c FrameCodec) encode_intermediate_frame(payload []u8) ![]u8 {
	mut frame := []u8{}
	if !c.wrote_client_marker {
		tl.append_u32(mut frame, intermediate_transport_marker)
		c.wrote_client_marker = true
	}
	tl.append_u32(mut frame, u32(payload.len))
	frame << payload.clone()
	return frame
}

fn (mut c FrameCodec) read_intermediate_frame(mut stream Stream) ![]u8 {
	header := read_exact(mut stream, 4)!
	length := decode_u32(header)
	if length == 0 {
		return error('intermediate transport frame length must be positive')
	}
	return read_exact(mut stream, int(length))!
}

fn (mut c FrameCodec) encode_full_frame(payload []u8) ![]u8 {
	mut frame := []u8{}
	if !c.wrote_client_marker {
		tl.append_u32(mut frame, full_transport_marker)
		c.wrote_client_marker = true
	}
	total_length := payload.len + 12
	mut packet := []u8{}
	tl.append_u32(mut packet, u32(total_length))
	tl.append_int(mut packet, c.full_send_seq_no)
	packet << payload.clone()
	checksum := crc32.sum(packet)
	tl.append_u32(mut packet, checksum)
	c.full_send_seq_no++
	frame << packet
	return frame
}

fn (mut c FrameCodec) read_full_frame(mut stream Stream) ![]u8 {
	header := read_exact(mut stream, 8)!
	total_length := int(decode_u32(header[..4]))
	if total_length < 12 {
		return error('full transport frame length ${total_length} is too small')
	}
	payload_length := total_length - 12
	payload := read_exact(mut stream, payload_length)!
	checksum_bytes := read_exact(mut stream, 4)!
	mut checksum_input := []u8{}
	checksum_input << header
	checksum_input << payload
	expected := crc32.sum(checksum_input)
	actual := decode_u32(checksum_bytes)
	if actual != expected {
		return error('full transport crc32 mismatch')
	}
	return payload
}

fn decode_u32(data []u8) u32 {
	return u32(data[0]) | (u32(data[1]) << 8) | (u32(data[2]) << 16) | (u32(data[3]) << 24)
}

fn read_exact(mut stream Stream, length int) ![]u8 {
	if length < 0 {
		return error('read length must not be negative')
	}
	mut buf := []u8{len: length}
	mut read_total := 0
	for read_total < length {
		read_now := stream.read(mut buf[read_total..]) or {
			return error('transport stream read failed: ${err.msg()}')
		}
		if read_now <= 0 {
			return error('transport stream closed before reading ${length} bytes')
		}
		read_total += read_now
	}
	return buf
}

fn write_all(mut stream Stream, data []u8) ! {
	mut written_total := 0
	for written_total < data.len {
		written_now := stream.write(data[written_total..]) or {
			return error('transport stream write failed: ${err.msg()}')
		}
		if written_now <= 0 {
			return error('transport stream write returned ${written_now}')
		}
		written_total += written_now
	}
}
