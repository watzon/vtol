module crypto

pub struct Capability {
pub:
	name      string
	available bool
}

pub struct KeyMaterial {
pub:
	auth_key []u8
	msg_key  []u8
}
