module rpc

pub struct Envelope {
pub:
	message_id i64
	seq_no     int
	body       []u8
}

pub struct CallOptions {
pub:
	timeout_ms   int  = 10_000
	requires_ack bool = true
	can_retry    bool = true
}
