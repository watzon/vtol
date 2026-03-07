module rpc

// Envelope stores a serialized message ready for encrypted transport handling.
pub struct Envelope {
pub:
	message_id i64
	seq_no     int
	body       []u8
}

// CallOptions configures timeout and retry behavior for an RPC invocation.
pub struct CallOptions {
pub:
	timeout_ms   int  = 10_000
	requires_ack bool = true
	can_retry    bool = true
}
