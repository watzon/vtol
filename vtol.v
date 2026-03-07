module vtol

pub enum TransportMode {
	abridged
	intermediate
	full
}

pub enum ClientState {
	disconnected
	connecting
	connected
}

pub struct DcOption {
pub:
	id       int
	host     string
	port     int
	is_media bool
}

pub struct ClientConfig {
pub:
	app_id           int
	app_hash         string
	device_model     string = 'vtol'
	system_version   string = 'unknown'
	app_version      string = '0.1.0'
	system_lang_code string = 'en'
	lang_pack        string
	lang_code        string        = 'en'
	transport        TransportMode = .abridged
	dc_options       []DcOption
}

pub struct Session {
pub:
	dc_id           int
	auth_key        []u8
	auth_key_id     i64
	server_salt     i64
	session_id      i64
	layer           int
	schema_revision string
	created_at      i64
}

pub struct Update {
pub:
	name    string
	payload []u8
}

pub struct RpcError {
pub:
	code    int
	message string
}

pub fn (e RpcError) msg() string {
	return e.message
}

pub struct AuthError {
pub:
	code    string
	message string
}

pub fn (e AuthError) msg() string {
	return e.message
}

pub struct Client {
pub:
	config ClientConfig
mut:
	state ClientState
}

pub fn new_client(config ClientConfig) !Client {
	if config.app_id <= 0 {
		return error('client config app_id must be greater than zero')
	}
	if config.app_hash.len == 0 {
		return error('client config app_hash must not be empty')
	}
	if config.dc_options.len == 0 {
		return error('client config must define at least one dc option')
	}
	return Client{
		config: config
		state:  .disconnected
	}
}

pub fn (c Client) client_state() ClientState {
	return c.state
}

pub fn (c Client) primary_dc() ?DcOption {
	if c.config.dc_options.len == 0 {
		return none
	}
	return c.config.dc_options[0]
}
