module session

import db.sqlite
import encoding.base64
import encoding.hex
import json
import os
import strconv
import sync
import tl

const empty_store_message = 'session store is empty'
const sqlite_session_version = 1
const string_session_version = 1
const sqlite_magic_header = 'SQLite format 3'

// SessionState stores the MTProto authorization state persisted for a client.
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

// PeerRecord stores a cached peer entry persisted alongside session state.
pub struct PeerRecord {
pub:
	cache_key  string
	key        string
	username   string
	peer       tl.PeerType
	input_peer tl.InputPeerType
}

// SessionData bundles the persisted session state and peer cache.
pub struct SessionData {
pub:
	state SessionState
	peers []PeerRecord
}

// Store persists and restores SessionData.
pub interface Store {
mut:
	load() !SessionData
	save(data SessionData) !
}

// MemorySession keeps session data in process memory only.
pub struct MemorySession {
mut:
	mu       sync.Mutex
	has_data bool
	data     SessionData
}

// StringSession persists session data as an encoded string payload.
pub struct StringSession {
mut:
	base  MemorySession
	value string
}

// SQLiteSession persists session data in a SQLite database file.
pub struct SQLiteSession {
pub:
	path string
mut:
	mu sync.Mutex
}

struct SessionPayloadRecord {
	version int
	state   SessionStateRecord
	peers   []PeerRecordPayload
}

struct SessionStateRecord {
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

struct PeerRecordPayload {
	cache_key      string
	key            string
	username       string
	peer_hex       string
	input_peer_hex string
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

// new_memory_session creates an empty in-memory session store.
pub fn new_memory_session() &MemorySession {
	return &MemorySession{}
}

// new_string_session creates a string-backed session store from an optional encoded payload.
pub fn new_string_session(value string) !&StringSession {
	mut store := &StringSession{}
	if value.len == 0 {
		return store
	}
	data := decode_string_payload(value)!
	store.base.save(data)!
	store.value = encode_string_payload(data)!
	return store
}

// new_sqlite_session creates a SQLite-backed session store.
pub fn new_sqlite_session(path string) !&SQLiteSession {
	if path.len == 0 {
		return error('session store path must not be empty')
	}
	return &SQLiteSession{
		path: path
	}
}

// new_memory_store is an alias for new_memory_session.
pub fn new_memory_store() &MemorySession {
	return new_memory_session()
}

// new_file_store is an alias for new_sqlite_session.
pub fn new_file_store(path string) !&SQLiteSession {
	return new_sqlite_session(path)!
}

// load restores session data from memory.
pub fn (mut s MemorySession) load() !SessionData {
	s.mu.@lock()
	defer {
		s.mu.unlock()
	}
	if !s.has_data {
		return error(empty_store_message)
	}
	return clone_session_data(s.data)
}

// save persists session data into memory.
pub fn (mut s MemorySession) save(data SessionData) ! {
	s.mu.@lock()
	defer {
		s.mu.unlock()
	}
	s.data = clone_session_data(data)
	s.has_data = true
}

// load restores session data from the encoded string session.
pub fn (mut s StringSession) load() !SessionData {
	return s.base.load()!
}

// save persists session data into the encoded string session.
pub fn (mut s StringSession) save(data SessionData) ! {
	s.base.save(data)!
	s.value = encode_string_payload(data)!
}

// encoded returns the current encoded string payload.
pub fn (s StringSession) encoded() string {
	return s.value
}

// string returns the encoded payload so StringSession satisfies string interpolation naturally.
pub fn (s StringSession) string() string {
	return s.value
}

// load restores session data from the SQLite database file.
pub fn (mut s SQLiteSession) load() !SessionData {
	s.mu.@lock()
	defer {
		s.mu.unlock()
	}
	if !os.exists(s.path) {
		return error(empty_store_message)
	}
	s.migrate_legacy_json_if_needed()!
	mut db := s.open_db()!
	defer {
		db.close() or {}
	}
	ensure_sqlite_schema(mut db)!
	return load_sqlite_session_data(mut db, s.path)!
}

// save persists session data into the SQLite database file.
pub fn (mut s SQLiteSession) save(data SessionData) ! {
	s.mu.@lock()
	defer {
		s.mu.unlock()
	}
	s.migrate_legacy_json_if_needed()!
	mut db := s.open_db()!
	defer {
		db.close() or {}
	}
	ensure_sqlite_schema(mut db)!
	save_sqlite_session_data(mut db, clone_session_data(data), s.path)!
}

fn (s SQLiteSession) open_db() !sqlite.DB {
	dir := os.dir(s.path)
	if dir.len > 0 && dir != '.' {
		os.mkdir_all(dir, mode: 0o700)!
	}
	mut db := sqlite.connect(s.path)!
	db.busy_timeout(5_000)
	return db
}

fn (s SQLiteSession) migrate_legacy_json_if_needed() ! {
	if !os.exists(s.path) {
		return
	}
	bytes := os.read_bytes(s.path) or { return err }
	if bytes.len == 0 {
		os.rm(s.path)!
		return
	}
	if bytes.len >= sqlite_magic_header.len
		&& bytes[..sqlite_magic_header.len].bytestr() == sqlite_magic_header {
		return
	}
	content := bytes.bytestr()
	data := session_data_from_legacy_json(content, s.path)!
	os.rm(s.path)!
	mut db := s.open_db()!
	defer {
		db.close() or {}
	}
	ensure_sqlite_schema(mut db)!
	save_sqlite_session_data(mut db, data, s.path)!
}

fn clone_session_data(data SessionData) SessionData {
	return SessionData{
		state: clone_session_state(data.state)
		peers: clone_peer_records(data.peers)
	}
}

fn clone_session_state(state SessionState) SessionState {
	return SessionState{
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
}

fn clone_peer_records(records []PeerRecord) []PeerRecord {
	mut peers := []PeerRecord{cap: records.len}
	for record in records {
		peers << PeerRecord{
			cache_key:  record.cache_key
			key:        record.key
			username:   record.username
			peer:       record.peer
			input_peer: record.input_peer
		}
	}
	return peers
}

fn encode_string_payload(data SessionData) !string {
	payload := SessionPayloadRecord{
		version: string_session_version
		state:   session_state_record_from_state(data.state)
		peers:   peer_payloads_from_records(data.peers)!
	}
	return base64.url_encode(json.encode(payload).bytes())
}

fn decode_string_payload(value string) !SessionData {
	if value.len == 0 {
		return error(empty_store_message)
	}
	decoded := base64.url_decode(value)
	if decoded.len == 0 {
		return error('invalid string session payload')
	}
	payload := json.decode(SessionPayloadRecord, decoded.bytestr()) or {
		return error('invalid string session payload: ${err.msg()}')
	}
	if payload.version != string_session_version {
		return error('unsupported string session version ${payload.version}')
	}
	return session_data_from_payload_record(payload, 'string session')!
}

fn session_state_record_from_state(state SessionState) SessionStateRecord {
	return SessionStateRecord{
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
}

fn session_state_from_record(source string, record SessionStateRecord) !SessionState {
	auth_key := hex.decode(record.auth_key_hex) or {
		return error('invalid session auth key for ${source}: ${err.msg()}')
	}
	return SessionState{
		dc_id:           record.dc_id
		dc_address:      record.dc_address
		dc_port:         record.dc_port
		auth_key:        auth_key
		auth_key_id:     parse_i64_field(source, 'auth_key_id', record.auth_key_id)!
		server_salt:     parse_i64_field(source, 'server_salt', record.server_salt)!
		session_id:      parse_i64_field(source, 'session_id', record.session_id)!
		layer:           record.layer
		schema_revision: record.schema_revision
		created_at:      parse_i64_field(source, 'created_at', record.created_at)!
	}
}

fn peer_payloads_from_records(records []PeerRecord) ![]PeerRecordPayload {
	mut payloads := []PeerRecordPayload{cap: records.len}
	for record in records {
		payloads << PeerRecordPayload{
			cache_key:      record.cache_key
			key:            record.key
			username:       record.username
			peer_hex:       hex.encode(record.peer.encode()!)
			input_peer_hex: hex.encode(record.input_peer.encode()!)
		}
	}
	return payloads
}

fn peer_record_from_payload(payload PeerRecordPayload) !PeerRecord {
	peer_bytes := hex.decode(payload.peer_hex) or {
		return error('invalid stored peer payload for ${payload.cache_key}: ${err.msg()}')
	}
	input_peer_bytes := hex.decode(payload.input_peer_hex) or {
		return error('invalid stored input peer payload for ${payload.cache_key}: ${err.msg()}')
	}
	return PeerRecord{
		cache_key:  payload.cache_key
		key:        payload.key
		username:   payload.username
		peer:       tl.decode_peer_type(peer_bytes)!
		input_peer: tl.decode_input_peer_type(input_peer_bytes)!
	}
}

fn session_data_from_payload_record(payload SessionPayloadRecord, source string) !SessionData {
	mut peers := []PeerRecord{cap: payload.peers.len}
	for peer_payload in payload.peers {
		peers << peer_record_from_payload(peer_payload)!
	}
	return SessionData{
		state: session_state_from_record(source, payload.state)!
		peers: peers
	}
}

fn session_data_from_legacy_json(content string, path string) !SessionData {
	record := json.decode(FileStoreRecord, content) or {
		legacy := json.decode(LegacyFileStoreRecord, content) or {
			return error('invalid legacy session store at ${path}: ${err.msg()}')
		}
		return SessionData{
			state: session_state_from_legacy_record(legacy, path)!
			peers: []PeerRecord{}
		}
	}
	return SessionData{
		state: session_state_from_record(path, SessionStateRecord{
			dc_id:           record.dc_id
			dc_address:      record.dc_address
			dc_port:         record.dc_port
			auth_key_hex:    record.auth_key_hex
			auth_key_id:     record.auth_key_id
			server_salt:     record.server_salt
			session_id:      record.session_id
			layer:           record.layer
			schema_revision: record.schema_revision
			created_at:      record.created_at
		})!
		peers: []PeerRecord{}
	}
}

fn session_state_from_legacy_record(record LegacyFileStoreRecord, path string) !SessionState {
	if record.version != 1 {
		return error('unsupported session store version ${record.version} at ${path}')
	}
	auth_key := hex.decode(record.auth_key_hex) or {
		return error('invalid session store auth key at ${path}: ${err.msg()}')
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

fn ensure_sqlite_schema(mut db sqlite.DB) ! {
	db.exec('create table if not exists meta (key text primary key, value text not null)')!
	db.exec('create table if not exists session_state (singleton integer primary key, dc_id integer not null, dc_address text not null, dc_port integer not null, auth_key_hex text not null, auth_key_id text not null, server_salt text not null, session_id text not null, layer integer not null, schema_revision text not null, created_at text not null)')!
	db.exec('create table if not exists peers (cache_key text primary key, key text not null, username text not null, peer_hex text not null, input_peer_hex text not null)')!
	db.exec_param_many('insert or ignore into meta(key, value) values (?, ?)', [
		'version',
		sqlite_session_version.str(),
	])!
}

fn load_sqlite_session_data(mut db sqlite.DB, path string) !SessionData {
	state_rows := db.exec('select dc_id, dc_address, dc_port, auth_key_hex, auth_key_id, server_salt, session_id, layer, schema_revision, created_at from session_state where singleton = 1')!
	if state_rows.len == 0 {
		return error(empty_store_message)
	}
	state_row := state_rows[0]
	if state_row.vals.len != 10 {
		return error('invalid sqlite session state at ${path}')
	}
	state := session_state_from_record(path, SessionStateRecord{
		dc_id:           state_row.vals[0].int()
		dc_address:      state_row.vals[1]
		dc_port:         state_row.vals[2].int()
		auth_key_hex:    state_row.vals[3]
		auth_key_id:     state_row.vals[4]
		server_salt:     state_row.vals[5]
		session_id:      state_row.vals[6]
		layer:           state_row.vals[7].int()
		schema_revision: state_row.vals[8]
		created_at:      state_row.vals[9]
	})!
	peer_rows := db.exec('select cache_key, key, username, peer_hex, input_peer_hex from peers order by cache_key')!
	mut peers := []PeerRecord{cap: peer_rows.len}
	for row in peer_rows {
		if row.vals.len != 5 {
			return error('invalid sqlite session peer row at ${path}')
		}
		peers << peer_record_from_payload(PeerRecordPayload{
			cache_key:      row.vals[0]
			key:            row.vals[1]
			username:       row.vals[2]
			peer_hex:       row.vals[3]
			input_peer_hex: row.vals[4]
		})!
	}
	return SessionData{
		state: state
		peers: peers
	}
}

fn save_sqlite_session_data(mut db sqlite.DB, data SessionData, path string) ! {
	db.exec('begin immediate')!
	state := session_state_record_from_state(data.state)
	if _ := db.exec('delete from session_state') {
	} else {
		db.exec('rollback') or {}
		return error('failed to reset sqlite session state at ${path}')
	}
	if _ := db.exec('delete from peers') {
	} else {
		db.exec('rollback') or {}
		return error('failed to reset sqlite session peers at ${path}')
	}
	db.exec_param_many('insert into session_state(singleton, dc_id, dc_address, dc_port, auth_key_hex, auth_key_id, server_salt, session_id, layer, schema_revision, created_at) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
		[
		'1',
		state.dc_id.str(),
		state.dc_address,
		state.dc_port.str(),
		state.auth_key_hex,
		state.auth_key_id,
		state.server_salt,
		state.session_id,
		state.layer.str(),
		state.schema_revision,
		state.created_at,
	]) or {
		db.exec('rollback') or {}
		return err
	}
	for peer in peer_payloads_from_records(data.peers)! {
		db.exec_param_many('insert into peers(cache_key, key, username, peer_hex, input_peer_hex) values (?, ?, ?, ?, ?)',
			[
			peer.cache_key,
			peer.key,
			peer.username,
			peer.peer_hex,
			peer.input_peer_hex,
		]) or {
			db.exec('rollback') or {}
			return err
		}
	}
	db.exec('commit')!
}

fn parse_i64_field(source string, field_name string, value string) !i64 {
	if value.len == 0 {
		return error('invalid session payload for ${source}: missing ${field_name}')
	}
	return strconv.atoi64(value) or {
		return error('invalid session payload for ${source}: invalid ${field_name}')
	}
}
