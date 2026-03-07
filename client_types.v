module vtol

import auth
import crypto
import rpc
import tl
import transport

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
	app_id                  int
	app_hash                string
	device_model            string = 'vtol'
	system_version          string = 'unknown'
	app_version             string = '0.1.0'
	system_lang_code        string = 'en'
	lang_pack               string
	lang_code               string        = 'en'
	transport               TransportMode = .abridged
	dc_options              []DcOption
	public_keys             []crypto.PublicKey
	transport_retry         transport.RetryPolicy = transport.RetryPolicy{}
	transport_timeouts      transport.Timeouts    = transport.Timeouts{}
	rpc_config              rpc.EngineConfig      = rpc.EngineConfig{}
	rpc_event_history_limit int                   = 64
	default_call_options    rpc.CallOptions       = rpc.CallOptions{}
	test_mode               bool
	padding_mode            auth.RsaPaddingMode = .auto
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
	Error
pub:
	rpc_code       int
	message        string
	raw            tl.RpcError
	wait_seconds   int
	premium_wait   bool
	has_rate_limit bool
}

pub fn (e RpcError) msg() string {
	if e.has_rate_limit {
		wait_kind := if e.premium_wait { 'premium flood wait' } else { 'flood wait' }
		return 'rpc error ${e.rpc_code}: ${e.message} (${wait_kind} ${e.wait_seconds}s)'
	}
	return 'rpc error ${e.rpc_code}: ${e.message}'
}

pub fn (e RpcError) code() int {
	return e.rpc_code
}

pub fn (e RpcError) is_rate_limited() bool {
	return e.has_rate_limit
}

pub fn (e RpcError) retry_after_ms() int {
	if !e.has_rate_limit {
		return 0
	}
	return e.wait_seconds * 1_000
}

pub fn (e RpcError) is(name string) bool {
	return e.message == name
}

pub fn (e RpcError) migration_dc_id() ?int {
	return rpc.migration_dc_id(e.raw)
}

pub enum AuthErrorKind {
	unknown
	password_required
	code_invalid
	code_expired
	phone_number_invalid
	code_hash_invalid
	code_empty
	password_invalid
	bot_token_invalid
}

pub struct AuthError {
	Error
pub:
	kind      AuthErrorKind = .unknown
	auth_code string
	message   string
	raw       RpcError
}

pub fn (e AuthError) msg() string {
	return e.message
}

pub fn (e AuthError) code() int {
	return e.raw.rpc_code
}

pub fn (e AuthError) is(name string) bool {
	return e.auth_code == name
}

pub fn (e AuthError) requires_password() bool {
	return e.kind == .password_required
}

pub fn (e AuthError) is_code_invalid() bool {
	return e.kind == .code_invalid
}

pub fn (e AuthError) is_code_expired() bool {
	return e.kind == .code_expired
}

pub fn (e AuthError) is_password_invalid() bool {
	return e.kind == .password_invalid
}

pub struct LoginCodeRequest {
pub:
	phone_number      string
	phone_code_hash   string
	sent_code         tl.AuthSentCodeType
	authorization     tl.AuthAuthorizationType = tl.UnknownAuthAuthorizationType{}
	authorization_now bool
}

pub enum AuthPromptKind {
	phone_number
	bot_token
	code
	password
}

pub type PhoneCallback = fn () !string

pub type BotTokenCallback = fn () !string

pub type CodeCallback = fn (request LoginCodeRequest) !string

pub type PasswordCallback = fn () !string

pub type CodeSentCallback = fn (request LoginCodeRequest)

pub type InvalidAuthCallback = fn (kind AuthPromptKind, err AuthError)

pub struct StartOptions {
pub:
	phone_number          PhoneCallback       = unsafe { nil }
	bot_token             BotTokenCallback    = unsafe { nil }
	code                  CodeCallback        = unsafe { nil }
	password              PasswordCallback    = unsafe { nil }
	code_sent_callback    CodeSentCallback    = unsafe { nil }
	invalid_auth_callback InvalidAuthCallback = unsafe { nil }
	code_settings         tl.CodeSettingsType = tl.CodeSettings{
		allow_app_hash: true
	}
}

pub struct ResolvedPeer {
pub:
	key        string
	username   string
	peer       tl.PeerType
	input_peer tl.InputPeerType
	users      []tl.UserType
	chats      []tl.ChatType
}

pub struct DialogPageOptions {
pub:
	limit               int = 50
	offset_date         int
	offset_id           int
	offset_peer         tl.InputPeerType = tl.InputPeerEmpty{}
	exclude_pinned      bool
	folder_id           int
	has_folder_id_value bool
	hash                i64
	max_pages           int
	max_items           int
}

pub struct DialogPage {
pub:
	response     tl.MessagesDialogsType
	dialogs      []tl.DialogType
	messages     []tl.MessageType
	chats        []tl.ChatType
	users        []tl.UserType
	total_count  int
	has_more     bool
	next_options DialogPageOptions
}

pub struct DialogBatch {
pub mut:
	pages    []DialogPage
	dialogs  []tl.DialogType
	messages []tl.MessageType
	chats    []tl.ChatType
	users    []tl.UserType
}

pub struct HistoryPageOptions {
pub:
	limit       int = 50
	offset_id   int
	offset_date int
	add_offset  int
	max_id      int
	min_id      int
	hash        i64
	max_pages   int
	max_items   int
}

pub struct HistoryPage {
pub:
	response     tl.MessagesMessagesType
	messages     []tl.MessageType
	topics       []tl.ForumTopicType
	chats        []tl.ChatType
	users        []tl.UserType
	total_count  int
	has_more     bool
	next_options HistoryPageOptions
}

pub struct HistoryBatch {
pub mut:
	pages    []HistoryPage
	messages []tl.MessageType
	topics   []tl.ForumTopicType
	chats    []tl.ChatType
	users    []tl.UserType
}

pub type DialogPageCallback = fn (page DialogPage) !

pub type HistoryPageCallback = fn (page HistoryPage) !
