module tl

import encoding.hex
import os

fn test_current_layer_info_exposes_snapshot_metadata() {
	info := current_layer_info()
	assert info.layer == 222
	assert info.constructor_count > 1500
	assert info.function_count > 700
	assert info.schema_revision.contains('telethon-v1-layer-222')

	snapshot := current_schema_snapshot()
	assert snapshot.layer == info.layer
	assert snapshot.sources.len == 2
	assert snapshot.normalized_path.ends_with('tl/schema/normalized.tl')
}

fn test_generated_input_peer_user_matches_golden_fixture() {
	object := InputPeerUser{
		user_id:     i64(42)
		access_hash: i64(99)
	}
	encoded := object.encode() or { panic(err) }
	expected := load_hex_fixture('input_peer_user.hex')
	assert hex.encode(encoded) == hex.encode(expected)

	decoded := decode_object(expected) or { panic(err) }
	match decoded {
		InputPeerUser {
			assert decoded.user_id == 42
			assert decoded.access_hash == 99
		}
		else {
			assert false
		}
	}
}

fn test_generated_flag_object_matches_golden_fixture() {
	object := UserStatusRecently{
		by_me: true
	}
	encoded := object.encode() or { panic(err) }
	expected := load_hex_fixture('user_status_recently.hex')
	assert hex.encode(encoded) == hex.encode(expected)

	decoded := decode_user_status_type(expected) or { panic(err) }
	match decoded {
		UserStatusRecently {
			assert decoded.by_me
		}
		else {
			assert false
		}
	}
}

fn test_decode_object_preserves_unknown_top_level_constructor() {
	payload := [u8(0x78), 0x56, 0x34, 0x12, 0xaa, 0xbb, 0xcc]
	decoded := decode_object(payload) or { panic(err) }
	match decoded {
		UnknownObject {
			assert decoded.constructor == u32(0x12345678)
			assert decoded.raw_payload == [u8(0xaa), 0xbb, 0xcc]
			reencoded := decoded.encode() or { panic(err) }
			assert reencoded == payload
		}
		else {
			assert false
		}
	}
}

fn test_typed_decoders_reject_unknown_constructors() {
	payload := [u8(0x78), 0x56, 0x34, 0x12]
	_ := decode_input_peer_type(payload) or {
		assert err.msg().contains('expected InputPeer')
		return
	}
	assert false
}

fn load_hex_fixture(name string) []u8 {
	root := os.real_path(os.join_path(os.dir(@FILE), '..'))
	path := os.join_path(root, 'tests', 'fixtures', 'tl', name)
	content := os.read_file(path) or { panic(err) }
	return hex.decode(content.trim_space()) or { panic(err) }
}
