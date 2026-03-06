module session

pub struct SessionState {
pub:
	dc_id       int
	server_salt i64
	layer       int
}

pub interface Store {
	load() !SessionState
	save(state SessionState) !
}
