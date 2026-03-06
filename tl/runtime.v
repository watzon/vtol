module tl

import math

pub const vector_constructor_id = u32(0x1cb5c415)
pub const bool_false_constructor_id = u32(0xbc799737)
pub const bool_true_constructor_id = u32(0x997275b5)

pub struct Decoder {
	data []u8
mut:
	offset int
}

pub fn new_decoder(data []u8) Decoder {
	return Decoder{
		data: data.clone()
	}
}

pub fn (d Decoder) remaining() int {
	return d.data.len - d.offset
}

pub fn (mut d Decoder) read_remaining() []u8 {
	remaining := d.data[d.offset..].clone()
	d.offset = d.data.len
	return remaining
}

fn (mut d Decoder) read_exact(length int) ![]u8 {
	if length < 0 {
		return error('decoder length must not be negative')
	}
	if d.offset + length > d.data.len {
		return error('decoder expected ${length} bytes but only ${d.remaining()} remain')
	}
	chunk := d.data[d.offset..d.offset + length].clone()
	d.offset += length
	return chunk
}

pub fn (mut d Decoder) read_raw(length int) ![]u8 {
	return d.read_exact(length)!
}

pub fn (mut d Decoder) read_u32() !u32 {
	chunk := d.read_exact(4)!
	return u32(chunk[0]) | (u32(chunk[1]) << 8) | (u32(chunk[2]) << 16) | (u32(chunk[3]) << 24)
}

pub fn (mut d Decoder) read_int() !int {
	return int(i32(d.read_u32()!))
}

pub fn (mut d Decoder) read_long() !i64 {
	chunk := d.read_exact(8)!
	value := u64(chunk[0]) | (u64(chunk[1]) << 8) | (u64(chunk[2]) << 16) | (u64(chunk[3]) << 24) | (u64(chunk[4]) << 32) | (u64(chunk[5]) << 40) | (u64(chunk[6]) << 48) | (u64(chunk[7]) << 56)
	return i64(value)
}

pub fn (mut d Decoder) read_double() !f64 {
	return math.f64_from_bits(d.read_u64()!)
}

fn (mut d Decoder) read_u64() !u64 {
	chunk := d.read_exact(8)!
	return u64(chunk[0]) | (u64(chunk[1]) << 8) | (u64(chunk[2]) << 16) | (u64(chunk[3]) << 24) | (u64(chunk[4]) << 32) | (u64(chunk[5]) << 40) | (u64(chunk[6]) << 48) | (u64(chunk[7]) << 56)
}

pub fn (mut d Decoder) read_bytes() ![]u8 {
	first := d.read_exact(1)![0]
	mut length := 0
	mut header_len := 1
	if first < 254 {
		length = int(first)
	} else {
		header := d.read_exact(3)!
		header_len = 4
		length = int(u32(header[0]) | (u32(header[1]) << 8) | (u32(header[2]) << 16))
	}
	payload := d.read_exact(length)!
	padding := tl_padding(header_len + length)
	if padding > 0 {
		_ = d.read_exact(padding)!
	}
	return payload
}

pub fn (mut d Decoder) read_string() !string {
	return d.read_bytes()!.bytestr()
}

pub fn (mut d Decoder) read_int128() ![]u8 {
	return d.read_exact(16)!
}

pub fn (mut d Decoder) read_int256() ![]u8 {
	return d.read_exact(32)!
}

pub fn (mut d Decoder) read_bool() !bool {
	constructor := d.read_u32()!
	match constructor {
		bool_false_constructor_id { return false }
		bool_true_constructor_id { return true }
		else { return error('unexpected Bool constructor ${constructor:08x}') }
	}
}

pub fn (mut d Decoder) read_vector_len() !int {
	constructor := d.read_u32()!
	if constructor != vector_constructor_id {
		return error('unexpected vector constructor ${constructor:08x}')
	}
	return d.read_int()!
}

pub fn append_u32(mut out []u8, value u32) {
	out << u8(value & 0xff)
	out << u8((value >> 8) & 0xff)
	out << u8((value >> 16) & 0xff)
	out << u8((value >> 24) & 0xff)
}

pub fn append_int(mut out []u8, value int) {
	append_u32(mut out, u32(i32(value)))
}

pub fn append_long(mut out []u8, value i64) {
	for shift in [0, 8, 16, 24, 32, 40, 48, 56] {
		out << u8((u64(value) >> shift) & 0xff)
	}
}

pub fn append_double(mut out []u8, value f64) {
	append_u64(mut out, math.f64_bits(value))
}

fn append_u64(mut out []u8, value u64) {
	for shift in [0, 8, 16, 24, 32, 40, 48, 56] {
		out << u8((value >> shift) & 0xff)
	}
}

pub fn append_bytes(mut out []u8, value []u8) {
	mut header_len := 1
	if value.len < 254 {
		out << u8(value.len)
	} else {
		header_len = 4
		out << u8(254)
		out << u8(value.len & 0xff)
		out << u8((value.len >> 8) & 0xff)
		out << u8((value.len >> 16) & 0xff)
	}
	out << value.clone()
	padding := tl_padding(header_len + value.len)
	for _ in 0 .. padding {
		out << u8(0)
	}
}

pub fn append_string(mut out []u8, value string) {
	append_bytes(mut out, value.bytes())
}

pub fn append_int128(mut out []u8, value []u8) ! {
	if value.len != 16 {
		return error('int128 values must be exactly 16 bytes')
	}
	out << value.clone()
}

pub fn append_int256(mut out []u8, value []u8) ! {
	if value.len != 32 {
		return error('int256 values must be exactly 32 bytes')
	}
	out << value.clone()
}

pub fn append_bool(mut out []u8, value bool) {
	append_u32(mut out, if value { bool_true_constructor_id } else { bool_false_constructor_id })
}

fn tl_padding(length int) int {
	padding := length % 4
	if padding == 0 {
		return 0
	}
	return 4 - padding
}
