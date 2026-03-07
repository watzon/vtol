module session

import os
import time

fn test_memory_store_roundtrips_state() {
	mut store := new_memory_store()
	state := session_state_fixture()

	store.save(state) or { panic(err) }
	loaded := store.load() or { panic(err) }

	assert loaded.dc_id == state.dc_id
	assert loaded.auth_key == state.auth_key
	assert loaded.auth_key_id == state.auth_key_id
	assert loaded.server_salt == state.server_salt
	assert loaded.session_id == state.session_id
	assert loaded.layer == state.layer
	assert loaded.schema_revision == state.schema_revision
	assert loaded.created_at == state.created_at
}

fn test_file_store_roundtrips_state() {
	base_dir := os.join_path(os.temp_dir(), 'vtol-session-store-${time.now().unix_nano()}')
	path := os.join_path(base_dir, 'session.json')
	mut store := new_file_store(path) or { panic(err) }
	state := session_state_fixture()

	store.save(state) or { panic(err) }
	loaded := store.load() or { panic(err) }

	assert os.exists(path)
	assert loaded.dc_id == state.dc_id
	assert loaded.auth_key == state.auth_key
	assert loaded.auth_key_id == state.auth_key_id
	assert loaded.server_salt == state.server_salt
	assert loaded.session_id == state.session_id
	assert loaded.layer == state.layer
	assert loaded.schema_revision == state.schema_revision
	assert loaded.created_at == state.created_at

	os.rmdir_all(base_dir) or {}
}

fn test_file_store_reports_empty_when_missing() {
	base_dir := os.join_path(os.temp_dir(), 'vtol-session-missing-${time.now().unix_nano()}')
	path := os.join_path(base_dir, 'session.json')
	mut store := new_file_store(path) or { panic(err) }

	store.load() or {
		assert err.msg() == 'session store is empty'
		return
	}
	assert false
}

fn test_file_store_rejects_invalid_payload() {
	base_dir := os.join_path(os.temp_dir(), 'vtol-session-invalid-${time.now().unix_nano()}')
	path := os.join_path(base_dir, 'session.json')
	os.mkdir_all(base_dir, mode: 0o700) or { panic(err) }
	os.write_file(path, '{"version":1,"auth_key_hex":"zz"}') or { panic(err) }
	mut store := new_file_store(path) or { panic(err) }

	store.load() or {
		assert err.msg().contains('invalid session store auth key')
		os.rmdir_all(base_dir) or {}
		return
	}
	assert false
}

fn session_state_fixture() SessionState {
	return SessionState{
		dc_id:           2
		auth_key:        []u8{len: 256, init: u8((index * 13 + 7) % 251)}
		auth_key_id:     77
		server_salt:     55
		session_id:      99
		layer:           201
		schema_revision: 'test-layer'
		created_at:      1_700_000_000
	}
}
