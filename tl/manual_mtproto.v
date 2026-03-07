module tl

import compress.gzip

pub const rpc_result_constructor_id = u32(0xf35c6d01)
pub const gzip_packed_constructor_id = u32(0x3072cfa1)

pub struct RpcResult {
pub:
	req_msg_id i64
	result     Object = UnknownObject{}
	raw_result []u8
}

pub fn (r RpcResult) constructor_id() u32 {
	return rpc_result_constructor_id
}

pub fn (r RpcResult) qualified_name() string {
	return 'rpc_result'
}

pub fn (r RpcResult) encode() ![]u8 {
	mut out := []u8{}
	append_u32(mut out, rpc_result_constructor_id)
	append_long(mut out, r.req_msg_id)
	if r.raw_result.len > 0 {
		out << r.raw_result.clone()
		return out
	}
	out << r.result.encode()!
	return out
}

pub struct GzipPacked {
pub:
	packed_data []u8
	object      Object = UnknownObject{}
	raw_payload []u8
}

pub fn (g GzipPacked) constructor_id() u32 {
	return gzip_packed_constructor_id
}

pub fn (g GzipPacked) qualified_name() string {
	return 'gzip_packed'
}

pub fn (g GzipPacked) encode() ![]u8 {
	mut out := []u8{}
	append_u32(mut out, gzip_packed_constructor_id)
	if g.packed_data.len > 0 {
		append_bytes(mut out, g.packed_data)
		return out
	}
	payload := if g.raw_payload.len > 0 {
		g.raw_payload.clone()
	} else {
		g.object.encode()!
	}
	append_bytes(mut out, gzip.compress(payload)!)
	return out
}

pub fn decode_mtproto_object(data []u8) !Object {
	mut decoder := new_decoder(data)
	object := decode_mtproto_object_from_decoder(mut decoder)!
	if decoder.remaining() != 0 {
		return error('unexpected trailing TL payload bytes: ' + decoder.remaining().str())
	}
	return object
}

pub fn decode_mtproto_object_prefix(data []u8) !(Object, int) {
	mut decoder := new_decoder(data)
	object := decode_mtproto_object_from_decoder(mut decoder)!
	return object, decoder.offset
}

fn decode_mtproto_object_from_decoder(mut decoder Decoder) !Object {
	if decoder.remaining() < 4 {
		return error('mtproto object payload must include a constructor')
	}
	constructor := decoder.read_u32()!
	decoder.offset -= 4
	match constructor {
		rpc_result_constructor_id {
			return decode_rpc_result_from_decoder(mut decoder)!
		}
		gzip_packed_constructor_id {
			return decode_gzip_packed_from_decoder(mut decoder)!
		}
		else {
			return decode_object_from_decoder(mut decoder)!
		}
	}
}

fn decode_rpc_result_from_decoder(mut decoder Decoder) !RpcResult {
	constructor := decoder.read_u32()!
	if constructor != rpc_result_constructor_id {
		return error('unexpected rpc_result constructor ${constructor:08x}')
	}
	req_msg_id := decoder.read_long()!
	raw_result := decoder.read_remaining()
	if raw_result.len == 0 {
		return error('rpc_result must include a nested result payload')
	}
	result := decode_mtproto_object(raw_result)!
	return RpcResult{
		req_msg_id: req_msg_id
		result:     result
		raw_result: raw_result
	}
}

fn decode_gzip_packed_from_decoder(mut decoder Decoder) !GzipPacked {
	constructor := decoder.read_u32()!
	if constructor != gzip_packed_constructor_id {
		return error('unexpected gzip_packed constructor ${constructor:08x}')
	}
	packed_data := decoder.read_bytes()!
	if packed_data.len == 0 {
		return error('gzip_packed must include compressed payload data')
	}
	raw_payload := gzip.decompress(packed_data)!
	object := decode_mtproto_object(raw_payload)!
	return GzipPacked{
		packed_data: packed_data
		object:      object
		raw_payload: raw_payload
	}
}
