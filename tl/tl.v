module tl

// Object is the common interface implemented by all decoded TL objects.
pub interface Object {
	encode() ![]u8
	constructor_id() u32
	qualified_name() string
}

// Function is the interface implemented by callable TL methods.
pub interface Function {
	Object
	method_name() string
	result_type_name() string
}

// FunctionInfo summarizes a generated TL function.
pub struct FunctionInfo {
pub:
	method_name      string
	constructor_id   u32
	result_type_name string
}

// LayerInfo describes the generated TL schema revision currently compiled into VTOL.
pub struct LayerInfo {
pub:
	layer             int
	schema_revision   string
	constructor_count int
	function_count    int
}

// SchemaSource identifies one source input used to build a schema snapshot.
pub struct SchemaSource {
pub:
	name         string
	download_url string
	blob_sha     string
	raw_path     string
}

// SchemaSnapshot describes the normalized schema revision bundled with VTOL.
pub struct SchemaSnapshot {
pub:
	layer           int
	schema_revision string
	normalized_path string
	sources         []SchemaSource
}

// UnknownObject preserves undecoded TL payloads whose constructor is not recognized.
pub struct UnknownObject {
pub:
	constructor u32
	name        string
	raw_payload []u8
}

// encode reserializes the preserved unknown TL payload.
pub fn (o UnknownObject) encode() ![]u8 {
	mut out := []u8{}
	append_u32(mut out, o.constructor)
	out << o.raw_payload.clone()
	return out
}

// constructor_id returns the raw TL constructor id.
pub fn (o UnknownObject) constructor_id() u32 {
	return o.constructor
}

// qualified_name returns the preserved schema name or a constructor-based fallback.
pub fn (o UnknownObject) qualified_name() string {
	if o.name.len > 0 {
		return o.name
	}
	return 'unknown#${o.constructor:08x}'
}

// decode_object_prefix decodes one TL object and returns the consumed byte count.
pub fn decode_object_prefix(data []u8) !(Object, int) {
	mut decoder := new_decoder(data)
	object := decode_object_from_decoder(mut decoder)!
	return object, decoder.offset
}
