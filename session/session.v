module session

import sync

pub struct SessionState {
pub:
	dc_id           int
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

pub fn new_memory_store() &MemoryStore {
	return &MemoryStore{}
}

pub fn (mut s MemoryStore) load() !SessionState {
	s.mu.@lock()
	defer {
		s.mu.unlock()
	}
	if !s.has_state {
		return error('session store is empty')
	}
	return SessionState{
		dc_id:           s.state.dc_id
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
