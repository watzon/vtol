module session

import os
import time
import tl

fn test_memory_session_roundtrips_state_and_peers() {
	mut store := new_memory_session()
	data := session_data_fixture()

	store.save(data) or { panic(err) }
	loaded := store.load() or { panic(err) }

	assert_session_data_eq(loaded, data)
}

fn test_string_session_roundtrips_state_and_peers() {
	data := session_data_fixture()
	mut store := new_string_session('') or { panic(err) }

	store.save(data) or { panic(err) }
	encoded := store.encoded()
	assert encoded.len > 0

	mut restored := new_string_session(encoded) or { panic(err) }
	loaded := restored.load() or { panic(err) }

	assert_session_data_eq(loaded, data)
}

fn test_sqlite_session_roundtrips_state_and_peers() {
	base_dir := os.join_path(os.temp_dir(), 'vtol-sqlite-session-${time.now().unix_nano()}')
	path := os.join_path(base_dir, 'session.sqlite')
	mut store := new_sqlite_session(path) or { panic(err) }
	data := session_data_fixture()

	store.save(data) or { panic(err) }
	loaded := store.load() or { panic(err) }

	assert os.exists(path)
	assert_session_data_eq(loaded, data)

	os.rmdir_all(base_dir) or {}
}

fn test_sqlite_session_reports_empty_when_missing() {
	base_dir := os.join_path(os.temp_dir(), 'vtol-sqlite-missing-${time.now().unix_nano()}')
	path := os.join_path(base_dir, 'session.sqlite')
	mut store := new_sqlite_session(path) or { panic(err) }

	store.load() or {
		assert err.msg() == empty_store_message
		return
	}
	assert false
}

fn test_sqlite_session_migrates_legacy_json_payload() {
	base_dir := os.join_path(os.temp_dir(), 'vtol-sqlite-legacy-${time.now().unix_nano()}')
	path := os.join_path(base_dir, 'session.json')
	os.mkdir_all(base_dir, mode: 0o700) or { panic(err) }
	os.write_file(path, '{"version":2,"dc_id":2,"dc_address":"149.154.167.50","dc_port":443,"auth_key_hex":"0102","auth_key_id":"77","server_salt":"55","session_id":"99","layer":201,"schema_revision":"test-layer","created_at":"1700000000"}') or {
		panic(err)
	}
	mut store := new_sqlite_session(path) or { panic(err) }

	loaded := store.load() or { panic(err) }
	bytes := os.read_bytes(path) or { panic(err) }

	assert loaded.state.auth_key == [u8(1), 2]
	assert loaded.state.dc_address == '149.154.167.50'
	assert loaded.state.dc_port == 443
	assert bytes[..sqlite_magic_header.len].bytestr() == sqlite_magic_header

	os.rmdir_all(base_dir) or {}
}

fn session_data_fixture() SessionData {
	return SessionData{
		state: session_state_fixture()
		peers: [
			PeerRecord{
				cache_key:  'alice'
				key:        'user:42'
				username:   'alice'
				peer:       tl.PeerUser{
					user_id: 42
				}
				input_peer: tl.InputPeerUser{
					user_id:     42
					access_hash: 77
				}
			},
			PeerRecord{
				cache_key:  'me'
				key:        'me'
				username:   'me'
				peer:       tl.PeerUser{
					user_id: 99
				}
				input_peer: tl.InputPeerSelf{}
			},
		]
	}
}

fn session_state_fixture() SessionState {
	return SessionState{
		dc_id:           2
		dc_address:      '149.154.167.50'
		dc_port:         443
		auth_key:        []u8{len: 256, init: u8((index * 13 + 7) % 251)}
		auth_key_id:     i64(8329384496770802671)
		server_salt:     i64(5914947868849297421)
		session_id:      i64(1483665640623532111)
		layer:           201
		schema_revision: 'test-layer'
		created_at:      1_700_000_000
	}
}

fn assert_session_data_eq(actual SessionData, expected SessionData) {
	assert actual.state.dc_id == expected.state.dc_id
	assert actual.state.dc_address == expected.state.dc_address
	assert actual.state.dc_port == expected.state.dc_port
	assert actual.state.auth_key == expected.state.auth_key
	assert actual.state.auth_key_id == expected.state.auth_key_id
	assert actual.state.server_salt == expected.state.server_salt
	assert actual.state.session_id == expected.state.session_id
	assert actual.state.layer == expected.state.layer
	assert actual.state.schema_revision == expected.state.schema_revision
	assert actual.state.created_at == expected.state.created_at
	assert actual.peers.len == expected.peers.len
	for index, peer in actual.peers {
		expected_peer := expected.peers[index]
		assert peer.cache_key == expected_peer.cache_key
		assert peer.key == expected_peer.key
		assert peer.username == expected_peer.username
		assert peer.peer.encode() or { panic(err) } == expected_peer.peer.encode() or { panic(err) }
		assert peer.input_peer.encode() or { panic(err) } == expected_peer.input_peer.encode() or {
			panic(err)
		}
	}
}
