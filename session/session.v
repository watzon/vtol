module session

import encoding.hex
import json
import os
import strconv
import sync

const empty_store_message = 'session store is empty'
const file_store_version = 2

pub struct SessionState {
pub:
	dc_id           int
	dc_address      string
	dc_port         int
	auth_key        []u8
	auth_key_id     i64
	server_salt     i64
	session_id      i64
	layer           int
	schema_revision string
	created_at      i64
}

pub interface Store {
mut:
	load() !SessionState
	save(state SessionState) !
}

pub struct MemoryStore {
mut:
	mu        sync.Mutex
	has_state bool
	state     SessionState
}

pub struct FileStore {
pub:
	path string
mut:
	mu sync.Mutex
}

struct FileStoreRecord {
	version         int
	dc_id           int
	dc_address      string
	dc_port         int
	auth_key_hex    string
	auth_key_id     string
	server_salt     string
	session_id      string
	layer           int
	schema_revision string
	created_at      string
}

struct LegacyFileStoreRecord {
	version         int
	dc_id           int
	auth_key_hex    string
	auth_key_id     i64
	server_salt     i64
	session_id      i64
	layer           int
	schema_revision string
	created_at      i64
}

pub fn new_memory_store() &MemoryStore {
	return &MemoryStore{}
}

pub fn new_file_store(path string) !&FileStore {
	if path.len == 0 {
		return error('session store path must not be empty')
	}
	return &FileStore{
		path: path
	}
}

pub fn (mut s MemoryStore) load() !SessionState {
	s.mu.@lock()
	defer {
		s.mu.unlock()
	}
	if !s.has_state {
		return error(empty_store_message)
	}
	return SessionState{
		dc_id:           s.state.dc_id
		dc_address:      s.state.dc_address
		dc_port:         s.state.dc_port
		auth_key:        s.state.auth_key.clone()
		auth_key_id:     s.state.auth_key_id
		server_salt:     s.state.server_salt
		session_id:      s.state.session_id
		layer:           s.state.layer
		schema_revision: s.state.schema_revision
		created_at:      s.state.created_at
	}
}

pub fn (mut s MemoryStore) save(state SessionState) ! {
	s.mu.@lock()
	defer {
		s.mu.unlock()
	}
	s.state = SessionState{
		dc_id:           state.dc_id
		dc_address:      state.dc_address
		dc_port:         state.dc_port
		auth_key:        state.auth_key.clone()
		auth_key_id:     state.auth_key_id
		server_salt:     state.server_salt
		session_id:      state.session_id
		layer:           state.layer
		schema_revision: state.schema_revision
		created_at:      state.created_at
	}
	s.has_state = true
}

pub fn (mut s FileStore) load() !SessionState {
	s.mu.@lock()
	defer {
		s.mu.unlock()
	}
	if !os.exists(s.path) {
		return error(empty_store_message)
	}
	content := os.read_file(s.path) or {
		if !os.exists(s.path) {
			return error(empty_store_message)
		}
		return err
	}
	record := json.decode(FileStoreRecord, content) or {
		legacy := json.decode(LegacyFileStoreRecord, content) or {
			return error('invalid session store at ${s.path}: ${err.msg()}')
		}
		return session_state_from_legacy_record(legacy)
	}
	if record.version == 1 {
		legacy := json.decode(LegacyFileStoreRecord, content) or {
			return error('invalid session store at ${s.path}: ${err.msg()}')
		}
		return session_state_from_legacy_record(legacy)
	}
	if record.version != file_store_version {
		return error('unsupported session store version ${record.version}')
	}
	auth_key := hex.decode(record.auth_key_hex) or {
		return error('invalid session store auth key: ${err.msg()}')
	}
	return SessionState{
		dc_id:           record.dc_id
		dc_address:      record.dc_address
		dc_port:         record.dc_port
		auth_key:        auth_key
		auth_key_id:     parse_file_store_i64(s.path, 'auth_key_id', record.auth_key_id)!
		server_salt:     parse_file_store_i64(s.path, 'server_salt', record.server_salt)!
		session_id:      parse_file_store_i64(s.path, 'session_id', record.session_id)!
		layer:           record.layer
		schema_revision: record.schema_revision
		created_at:      parse_file_store_i64(s.path, 'created_at', record.created_at)!
	}
}

pub fn (mut s FileStore) save(state SessionState) ! {
	s.mu.@lock()
	defer {
		s.mu.unlock()
	}
	dir := os.dir(s.path)
	if dir.len > 0 && dir != '.' {
		os.mkdir_all(dir, mode: 0o700)!
	}
	record := FileStoreRecord{
		version:         file_store_version
		dc_id:           state.dc_id
		dc_address:      state.dc_address
		dc_port:         state.dc_port
		auth_key_hex:    hex.encode(state.auth_key)
		auth_key_id:     state.auth_key_id.str()
		server_salt:     state.server_salt.str()
		session_id:      state.session_id.str()
		layer:           state.layer
		schema_revision: state.schema_revision
		created_at:      state.created_at.str()
	}
	tmp_path := s.path + '.tmp'
	os.write_file(tmp_path, json.encode(record))!
	$if !windows {
		os.chmod(tmp_path, 0o600) or {}
	}
	os.mv(tmp_path, s.path, overwrite: true)!
	$if !windows {
		os.chmod(s.path, 0o600) or {}
	}
}

fn parse_file_store_i64(path string, field_name string, value string) !i64 {
	if value.len == 0 {
		return error('invalid session store at ${path}: missing ${field_name}')
	}
	return strconv.atoi64(value) or {
		return error('invalid session store at ${path}: invalid ${field_name}')
	}
}

fn session_state_from_legacy_record(record LegacyFileStoreRecord) !SessionState {
	if record.version != 1 {
		return error('unsupported session store version ${record.version}')
	}
	auth_key := hex.decode(record.auth_key_hex) or {
		return error('invalid session store auth key: ${err.msg()}')
	}
	return SessionState{
		dc_id:           record.dc_id
		dc_address:      ''
		dc_port:         0
		auth_key:        auth_key
		auth_key_id:     record.auth_key_id
		server_salt:     record.server_salt
		session_id:      record.session_id
		layer:           record.layer
		schema_revision: record.schema_revision
		created_at:      record.created_at
	}
}
