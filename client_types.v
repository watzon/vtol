module vtol

import auth
import crypto
import media
import rpc
import tl
import transport
import updates

// TransportMode selects the MTProto transport framing used by the client.
pub enum TransportMode {
	abridged
	intermediate
	full
}

// ClientState describes the high-level connection state of a Client.
pub enum ClientState {
	disconnected
	connecting
	connected
}

// DcOption describes a Telegram datacenter endpoint.
pub struct DcOption {
pub:
	id       int
	host     string
	port     int
	is_media bool
}

// ClientConfig configures the high-level VTOL client.
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

// Session is the exported view of the active MTProto authorization state.
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

// Update is a lightweight named update payload.
pub struct Update {
pub:
	name    string
	payload []u8
}

// RpcError wraps a Telegram RPC error in the public vtol module.
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

// msg returns a human-readable error string.
pub fn (e RpcError) msg() string {
	if e.has_rate_limit {
		wait_kind := if e.premium_wait { 'premium flood wait' } else { 'flood wait' }
		return 'rpc error ${e.rpc_code}: ${e.message} (${wait_kind} ${e.wait_seconds}s)'
	}
	return 'rpc error ${e.rpc_code}: ${e.message}'
}

// code returns the Telegram RPC error code.
pub fn (e RpcError) code() int {
	return e.rpc_code
}

// is_rate_limited reports whether the error carries flood-wait metadata.
pub fn (e RpcError) is_rate_limited() bool {
	return e.has_rate_limit
}

// retry_after_ms returns the flood-wait delay in milliseconds when present.
pub fn (e RpcError) retry_after_ms() int {
	if !e.has_rate_limit {
		return 0
	}
	return e.wait_seconds * 1_000
}

// is reports whether the Telegram error message matches name exactly.
pub fn (e RpcError) is(name string) bool {
	return e.message == name
}

// migration_dc_id returns the target datacenter for migrate errors.
pub fn (e RpcError) migration_dc_id() ?int {
	return rpc.migration_dc_id(e.raw)
}

// AuthErrorKind classifies common Telegram authentication failures.
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

// AuthError wraps authentication-specific failures surfaced by start and sign-in helpers.
pub struct AuthError {
	Error
pub:
	kind      AuthErrorKind = .unknown
	auth_code string
	message   string
	raw       RpcError
}

// msg returns a human-readable authentication error.
pub fn (e AuthError) msg() string {
	return e.message
}

// code returns the underlying Telegram RPC code when available.
pub fn (e AuthError) code() int {
	return e.raw.rpc_code
}

// is reports whether the underlying Telegram auth code matches name.
pub fn (e AuthError) is(name string) bool {
	return e.auth_code == name
}

// requires_password reports whether the account needs a 2FA password.
pub fn (e AuthError) requires_password() bool {
	return e.kind == .password_required
}

// is_code_invalid reports whether the supplied login code was rejected.
pub fn (e AuthError) is_code_invalid() bool {
	return e.kind == .code_invalid
}

// is_code_expired reports whether the current login code has expired.
pub fn (e AuthError) is_code_expired() bool {
	return e.kind == .code_expired
}

// is_password_invalid reports whether the supplied 2FA password was rejected.
pub fn (e AuthError) is_password_invalid() bool {
	return e.kind == .password_invalid
}

// LoginCodeRequest holds the state needed to complete a phone-number sign-in flow.
pub struct LoginCodeRequest {
pub:
	phone_number      string
	phone_code_hash   string
	sent_code         tl.AuthSentCodeType
	authorization     tl.AuthAuthorizationType = tl.UnknownAuthAuthorizationType{}
	authorization_now bool
}

// AuthPromptKind identifies which authentication prompt needs more user input.
pub enum AuthPromptKind {
	phone_number
	bot_token
	code
	password
}

// PhoneCallback resolves a phone number during interactive login.
pub type PhoneCallback = fn () !string

// BotTokenCallback resolves a bot token during interactive login.
pub type BotTokenCallback = fn () !string

// CodeCallback resolves a login code for a LoginCodeRequest.
pub type CodeCallback = fn (request LoginCodeRequest) !string

// PasswordCallback resolves a 2FA password during interactive login.
pub type PasswordCallback = fn () !string

// CodeSentCallback observes that Telegram accepted and sent a login code.
pub type CodeSentCallback = fn (request LoginCodeRequest)

// InvalidAuthCallback observes recoverable authentication failures during start.
pub type InvalidAuthCallback = fn (kind AuthPromptKind, err AuthError)

// StartOptions configures the interactive login flow used by Client.start.
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

// ResolvedPeer is the normalized peer handle used by high-level client helpers.
pub struct ResolvedPeer {
pub:
	key        string
	username   string
	peer       tl.PeerType
	input_peer tl.InputPeerType
	users      []tl.UserType
	chats      []tl.ChatType
}

// SentMessage is the normalized result returned by high-level send helpers.
pub struct SentMessage {
pub:
	id                 int
	peer               ResolvedPeer
	text               string
	date               int
	outgoing           bool = true
	updates            tl.UpdatesType
	message            tl.MessageType = tl.UnknownMessageType{}
	has_message_value  bool
	media              tl.MessageMediaType = tl.UnknownMessageMediaType{}
	has_media_value    bool
	entities           []tl.MessageEntityType
	has_entities_value bool
}

// SendOptions configures text-message send helpers.
pub struct SendOptions {
pub:
	reply_to_message_id           int
	has_reply_to_message_id_value bool
	silent                        bool
	disable_link_preview          bool
	schedule_date                 int
	has_schedule_date_value       bool
}

// SendFileOptions configures document upload and send helpers.
pub struct SendFileOptions {
pub:
	upload                        media.UploadOptions
	caption                       string
	mime_type                     string = 'application/octet-stream'
	attributes                    []tl.DocumentAttributeType
	force_file                    bool = true
	nosound_video                 bool
	spoiler                       bool
	reply_to_message_id           int
	has_reply_to_message_id_value bool
	silent                        bool
	schedule_date                 int
	has_schedule_date_value       bool
}

// SendPhotoOptions configures photo upload and send helpers.
pub struct SendPhotoOptions {
pub:
	upload                        media.UploadOptions
	caption                       string
	spoiler                       bool
	ttl_seconds                   int
	has_ttl_seconds_value         bool
	reply_to_message_id           int
	has_reply_to_message_id_value bool
	silent                        bool
	schedule_date                 int
	has_schedule_date_value       bool
}

// EventPeer describes a peer attached to an emitted update event.
pub struct EventPeer {
pub:
	key                  string
	username             string
	peer                 tl.PeerType
	input_peer           tl.InputPeerType = tl.InputPeerEmpty{}
	has_input_peer_value bool
}

// RawUpdateEvent exposes a live or recovered updates payload from the update manager.
pub struct RawUpdateEvent {
pub:
	kind                 updates.EventKind = .live
	state                updates.StateVector
	batch                tl.UpdatesType = tl.UpdatesTooLong{}
	has_batch_value      bool
	difference           tl.UpdatesDifferenceType = tl.UnknownUpdatesDifferenceType{}
	has_difference_value bool
}

// RawUpdateHandler handles a raw update event emitted by the client.
pub type RawUpdateHandler = fn (event RawUpdateEvent) !

// NewMessagePatternMatcher performs custom filtering for new-message handlers.
pub type NewMessagePatternMatcher = fn (event NewMessageEvent) bool

// NewMessageHandlerConfig filters events delivered to on_new_message_with_config.
pub struct NewMessageHandlerConfig {
pub:
	chat            string
	sender          string
	from_users      string
	incoming        bool
	outgoing        bool
	forwards        ?bool = none
	pattern         string
	pattern_matcher NewMessagePatternMatcher = unsafe { nil }
}

// NewMessageEvent is the normalized high-level event delivered to message handlers.
pub struct NewMessageEvent {
pub:
	kind                 updates.EventKind = .live
	state                updates.StateVector
	id                   int
	text                 string
	date                 int
	outgoing             bool
	forwarded            bool
	chat                 EventPeer
	sender               EventPeer
	has_sender_value     bool
	message              tl.MessageType = tl.UnknownMessageType{}
	has_message_value    bool
	media                tl.MessageMediaType = tl.UnknownMessageMediaType{}
	has_media_value      bool
	entities             []tl.MessageEntityType
	has_entities_value   bool
	update               tl.UpdateType = tl.UnknownUpdateType{}
	has_update_value     bool
	batch                tl.UpdatesType = tl.UpdatesTooLong{}
	has_batch_value      bool
	difference           tl.UpdatesDifferenceType = tl.UnknownUpdatesDifferenceType{}
	has_difference_value bool
}

// NewMessageHandler handles a normalized new-message event.
pub type NewMessageHandler = fn (event NewMessageEvent) !

// Conversation tracks a scoped dialog subscription for request-reply style flows.
pub struct Conversation {
pub:
	peer ResolvedPeer
mut:
	client           &Client = unsafe { nil }
	subscription     updates.Subscription
	pending_messages []NewMessageEvent
	closed           bool
}

// DialogPageOptions configures paginated dialog listing helpers.
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

// DialogPage holds a single normalized page returned by get_dialog_page.
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

// DialogBatch aggregates multiple dialog pages into a deduplicated result.
pub struct DialogBatch {
pub mut:
	pages    []DialogPage
	dialogs  []tl.DialogType
	messages []tl.MessageType
	chats    []tl.ChatType
	users    []tl.UserType
}

// HistoryPageOptions configures paginated history listing helpers.
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

// HistoryPage holds a single normalized page returned by get_history_page.
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

// HistoryBatch aggregates multiple history pages into a deduplicated result.
pub struct HistoryBatch {
pub mut:
	pages    []HistoryPage
	messages []tl.MessageType
	topics   []tl.ForumTopicType
	chats    []tl.ChatType
	users    []tl.UserType
}

// DialogPageCallback handles a page emitted by each_dialog_page.
pub type DialogPageCallback = fn (page DialogPage) !

// HistoryPageCallback handles a page emitted by each_history_page.
pub type HistoryPageCallback = fn (page HistoryPage) !

// DialogCallback handles a single dialog emitted by each_dialog.
pub type DialogCallback = fn (dialog tl.DialogType) !

// HistoryMessageCallback handles a single history message emitted by each_history_message.
pub type HistoryMessageCallback = fn (message tl.MessageType) !
