module client

pub enum Lifecycle {
	constructed
	connecting
	connected
	disconnecting
	disconnected
}

pub struct Runtime {
pub:
	session_loaded bool
	lifecycle      Lifecycle = .constructed
}
