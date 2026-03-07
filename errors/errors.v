module errors

// Kind classifies top-level VTOL error categories.
pub enum Kind {
	transport
	auth
	rpc
	schema
	session
	media
}

// Info stores structured error metadata for surfaced VTOL failures.
pub struct Info {
pub:
	kind    Kind
	code    string
	message string
}
