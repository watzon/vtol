module client

// Lifecycle describes the state of the lightweight public client runtime snapshot.
pub enum Lifecycle {
	constructed
	connecting
	connected
	disconnecting
	disconnected
}

// Runtime exposes lightweight runtime status for embedding or inspection.
pub struct Runtime {
pub:
	session_loaded bool
	lifecycle      Lifecycle = .constructed
}
