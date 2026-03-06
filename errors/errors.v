module errors

pub enum Kind {
	transport
	auth
	rpc
	schema
	session
	media
}

pub struct Info {
pub:
	kind    Kind
	code    string
	message string
}
