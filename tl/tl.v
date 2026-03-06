module tl

pub interface Object {
	encode() ![]u8
	constructor_id() u32
	qualified_name() string
}

pub interface Function {
	Object
	method_name() string
	result_type_name() string
}

pub struct LayerInfo {
pub:
	layer             int
	schema_revision   string
	constructor_count int
	function_count    int
}

pub struct SchemaSource {
pub:
	name         string
	download_url string
	blob_sha     string
	raw_path     string
}

pub struct SchemaSnapshot {
pub:
	layer           int
	schema_revision string
	normalized_path string
	sources         []SchemaSource
}

pub struct UnknownObject {
pub:
	constructor u32
	name        string
	raw_payload []u8
}

pub fn (o UnknownObject) encode() ![]u8 {
	mut out := []u8{}
	append_u32(mut out, o.constructor)
	out << o.raw_payload.clone()
	return out
}

pub fn (o UnknownObject) constructor_id() u32 {
	return o.constructor
}

pub fn (o UnknownObject) qualified_name() string {
	if o.name.len > 0 {
		return o.name
	}
	return 'unknown#${o.constructor:08x}'
}
