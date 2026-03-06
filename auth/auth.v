module auth

pub enum HandshakeState {
	idle
	waiting_pq
	waiting_dh_params
	waiting_dh_gen
	complete
	failed
}

pub struct AuthKeyMeta {
pub:
	dc_id      int
	key_id     i64
	created_at i64
}
