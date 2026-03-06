module tl

pub interface Object {
	encode() ![]u8
}

pub interface Function {
	method_name() string
}

pub struct LayerInfo {
pub:
	layer           int
	schema_revision string
}
