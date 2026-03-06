module config

pub struct LogConfig {
pub:
	enabled  bool
	wire     bool
	redacted bool = true
}

pub struct RetryConfig {
pub:
	max_attempts  int = 3
	base_delay_ms int = 250
	max_delay_ms  int = 5_000
}
