module transport

pub enum Mode {
	abridged
	intermediate
	full
}

pub struct Endpoint {
pub:
	id       int
	host     string
	port     int
	is_media bool
}

pub struct RetryPolicy {
pub:
	max_attempts int = 3
	backoff_ms   int = 250
}
