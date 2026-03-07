module vtol

import auth
import crypto
import media
import math.big
import os
import rpc
import session
import time
import tl
import transport
import updates

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
	app_id               int
	app_hash             string
	device_model         string = 'vtol'
	system_version       string = 'unknown'
	app_version          string = '0.1.0'
	system_lang_code     string = 'en'
	lang_pack            string
	lang_code            string        = 'en'
	transport            TransportMode = .abridged
	dc_options           []DcOption
	public_keys          []crypto.PublicKey
	transport_retry      transport.RetryPolicy = transport.RetryPolicy{}
	transport_timeouts   transport.Timeouts    = transport.Timeouts{}
	rpc_config           rpc.EngineConfig      = rpc.EngineConfig{}
	default_call_options rpc.CallOptions       = rpc.CallOptions{}
	test_mode            bool
	padding_mode         auth.RsaPaddingMode = .auto
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

pub struct LoginCodeRequest {
pub:
	phone_number      string
	phone_code_hash   string
	sent_code         tl.AuthSentCodeType
	authorization     tl.AuthAuthorizationType = tl.UnknownAuthAuthorizationType{}
	authorization_now bool
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

struct CachedPeer {
	key        string
	username   string
	input_peer tl.InputPeerType
	peer       tl.PeerType
}

struct ChannelHandle {
	id          i64
	access_hash i64
	username    string
}

interface ClientRuntime {
	is_connected() bool
	session_state() session.SessionState
mut:
	connect() !
	disconnect() !
	invoke(function tl.Function, options rpc.CallOptions) !tl.Object
	pump_once() !
	drain_updates() []tl.UpdatesType
}

struct NullRuntime {}

fn (mut n NullRuntime) connect() ! {
	return error('client is not connected')
}

fn (mut n NullRuntime) disconnect() ! {}

fn (n NullRuntime) is_connected() bool {
	return false
}

fn (mut n NullRuntime) invoke(function tl.Function, options rpc.CallOptions) !tl.Object {
	return error('client is not connected')
}

fn (mut n NullRuntime) pump_once() ! {
	return error('client is not connected')
}

fn (mut n NullRuntime) drain_updates() []tl.UpdatesType {
	return []tl.UpdatesType{}
}

fn (n NullRuntime) session_state() session.SessionState {
	return session.SessionState{}
}

struct SessionRuntime {
mut:
	engine rpc.SessionEngine
}

struct RuntimeDifferenceSource {
mut:
	runtime ClientRuntime
}

fn (mut r SessionRuntime) connect() ! {
	r.engine.connect()!
}

fn (mut r SessionRuntime) disconnect() ! {
	r.engine.disconnect()!
}

fn (r SessionRuntime) is_connected() bool {
	return r.engine.is_connected()
}

fn (mut r SessionRuntime) invoke(function tl.Function, options rpc.CallOptions) !tl.Object {
	return r.engine.invoke(function, options)!
}

fn (mut r SessionRuntime) pump_once() ! {
	r.engine.pump_once()!
}

fn (mut r SessionRuntime) drain_updates() []tl.UpdatesType {
	return r.engine.drain_updates()
}

fn (r SessionRuntime) session_state() session.SessionState {
	return r.engine.session_state()
}

fn (mut s RuntimeDifferenceSource) invoke(function tl.Function, options rpc.CallOptions) !tl.Object {
	return s.runtime.invoke(function, options)!
}

pub struct Client {
pub:
	config ClientConfig
mut:
	state          ClientState = .disconnected
	store          session.Store
	runtime        ClientRuntime = NullRuntime{}
	runtime_ready  bool
	session_loaded bool
	peer_cache     map[string]CachedPeer
	update_manager updates.Manager
}

pub fn new_client(config ClientConfig) !Client {
	return new_client_with_store(config, session.new_memory_store())
}

pub fn new_client_with_store(config ClientConfig, store session.Store) !Client {
	validate_client_config(config)!
	return Client{
		config:         config
		store:          store
		peer_cache:     map[string]CachedPeer{}
		update_manager: updates.new_manager(updates.ManagerConfig{})
	}
}

pub fn (c Client) client_state() ClientState {
	return c.state
}

pub fn (c Client) is_connected() bool {
	return c.state == .connected && c.runtime_ready && c.runtime.is_connected()
}

pub fn (c Client) did_restore_session() bool {
	return c.session_loaded
}

pub fn (c Client) primary_dc() ?DcOption {
	if c.config.dc_options.len == 0 {
		return none
	}
	return c.config.dc_options[0]
}

pub fn (c Client) session() ?Session {
	if !c.runtime_ready {
		return none
	}
	state := c.runtime.session_state()
	if state.session_id == 0 {
		return none
	}
	return Session{
		dc_id:           state.dc_id
		auth_key:        state.auth_key.clone()
		auth_key_id:     state.auth_key_id
		server_salt:     state.server_salt
		session_id:      state.session_id
		layer:           state.layer
		schema_revision: state.schema_revision
		created_at:      state.created_at
	}
}

pub fn (mut c Client) connect() ! {
	if c.is_connected() {
		return
	}
	c.state = .connecting
	if !c.runtime_ready {
		runtime, session_loaded := c.build_runtime()!
		c.runtime = runtime
		c.runtime_ready = true
		c.session_loaded = session_loaded
	}
	c.runtime.connect()!
	c.state = .connected
}

pub fn (mut c Client) disconnect() ! {
	if c.runtime_ready && c.runtime.is_connected() {
		c.runtime.disconnect()!
	}
	c.state = .disconnected
}

pub fn (c Client) update_state() ?updates.StateVector {
	return c.update_manager.current_state()
}

pub fn (mut c Client) invoke(function tl.Function) !tl.Object {
	return c.invoke_with_options(function, c.config.default_call_options)!
}

pub fn (mut c Client) invoke_with_options(function tl.Function, options rpc.CallOptions) !tl.Object {
	c.connect()!
	return c.runtime.invoke(function, c.normalized_call_options(options))!
}

pub fn (mut c Client) send_login_code(phone_number string) !LoginCodeRequest {
	return c.send_login_code_with_settings(phone_number, tl.CodeSettings{
		allow_app_hash: true
	})
}

pub fn (mut c Client) send_login_code_with_settings(phone_number string, settings tl.CodeSettingsType) !LoginCodeRequest {
	result := c.invoke(tl.AuthSendCode{
		phone_number: phone_number
		api_id:       c.config.app_id
		api_hash:     c.config.app_hash
		settings:     settings
	})!
	return login_code_request_from_object(phone_number, result)!
}

pub fn (mut c Client) sign_in_code(request LoginCodeRequest, code string) !tl.AuthAuthorizationType {
	if request.authorization_now {
		c.cache_authorization(request.authorization)
		return request.authorization
	}
	if request.phone_code_hash.len == 0 {
		return error('login code request does not contain a phone_code_hash')
	}
	return c.sign_in_phone(request.phone_number, request.phone_code_hash, code)!
}

pub fn (mut c Client) sign_in_phone(phone_number string, phone_code_hash string, code string) !tl.AuthAuthorizationType {
	result := c.invoke(tl.AuthSignIn{
		phone_number:                 phone_number
		phone_code_hash:              phone_code_hash
		phone_code:                   code
		has_phone_code_value:         true
		email_verification:           tl.UnknownEmailVerificationType{}
		has_email_verification_value: false
	})!
	authorization := expect_auth_authorization(result)!
	c.cache_authorization(authorization)
	return authorization
}

pub fn (mut c Client) get_password_challenge() !tl.AccountPasswordType {
	result := c.invoke(tl.AccountGetPassword{})!
	return expect_account_password(result)!
}

pub fn (mut c Client) check_password(password tl.InputCheckPasswordSRPType) !tl.AuthAuthorizationType {
	result := c.invoke(tl.AuthCheckPassword{
		password: password
	})!
	authorization := expect_auth_authorization(result)!
	c.cache_authorization(authorization)
	return authorization
}

pub fn (mut c Client) sign_in_password(password string) !tl.AuthAuthorizationType {
	challenge := c.get_password_challenge()!
	password_check := password_check_from_challenge(password, challenge)!
	return c.check_password(password_check)!
}

pub fn (mut c Client) login_bot(bot_token string) !tl.AuthAuthorizationType {
	result := c.invoke(tl.AuthImportBotAuthorization{
		flags:          0
		api_id:         c.config.app_id
		api_hash:       c.config.app_hash
		bot_auth_token: bot_token
	})!
	authorization := expect_auth_authorization(result)!
	c.cache_authorization(authorization)
	return authorization
}

pub fn (mut c Client) log_out() !tl.AuthLoggedOutType {
	result := c.invoke(tl.AuthLogOut{})!
	return expect_auth_logged_out(result)!
}

pub fn (mut c Client) get_me() !tl.UsersUserFullType {
	result := c.invoke(tl.UsersGetFullUser{
		id: tl.InputUserSelf{}
	})!
	return expect_users_user_full(result)!
}

pub fn (mut c Client) get_dialogs(limit int) !tl.MessagesDialogsType {
	result := c.invoke(tl.MessagesGetDialogs{
		offset_peer: tl.InputPeerEmpty{}
		limit:       normalize_limit(limit)
	})!
	return expect_messages_dialogs(result)!
}

pub fn (mut c Client) get_chats(chat_ids []i64) !tl.MessagesChatsType {
	result := c.invoke(tl.MessagesGetChats{
		id: chat_ids.clone()
	})!
	return expect_messages_chats(result)!
}

pub fn (mut c Client) get_history(peer tl.InputPeerType, limit int) !tl.MessagesMessagesType {
	result := c.invoke(tl.MessagesGetHistory{
		peer:  peer
		limit: normalize_limit(limit)
	})!
	return expect_messages_messages(result)!
}

pub fn (mut c Client) upload_file_bytes(name string, data []u8, options media.UploadOptions) !media.UploadedFile {
	c.connect()!
	file_id := if options.file_id != 0 {
		options.file_id
	} else {
		c.random_id()!
	}
	plan := media.new_upload_plan(name, data, media.UploadOptions{
		file_id:     file_id
		part_size:   options.part_size
		resume_part: options.resume_part
		reporter:    options.reporter
	})!
	plan.report_initial_progress()
	for part_index in plan.resume_part .. plan.total_parts {
		part := plan.part(part_index)!
		method_name := if plan.is_big { 'upload.saveBigFilePart' } else { 'upload.saveFilePart' }
		result := if plan.is_big {
			c.invoke(tl.UploadSaveBigFilePart{
				file_id:          plan.file_id
				file_part:        part.index
				file_total_parts: plan.total_parts
				bytes:            part.bytes
			})!
		} else {
			c.invoke(tl.UploadSaveFilePart{
				file_id:   plan.file_id
				file_part: part.index
				bytes:     part.bytes
			})!
		}
		expect_bool_true(result, method_name)!
		plan.report_uploaded_part(part.index)!
	}
	return plan.uploaded_file()
}

pub fn (mut c Client) upload_file_path(path string, options media.UploadOptions) !media.UploadedFile {
	if path.len == 0 {
		return error('upload path must not be empty')
	}
	name := os.file_name(path)
	if name.len == 0 {
		return error('upload path must include a file name')
	}
	data := os.read_bytes(path)!
	return c.upload_file_bytes(name, data, options)!
}

pub fn (mut c Client) download_file(location tl.InputFileLocationType, options media.DownloadOptions) !media.DownloadResult {
	c.connect()!
	mut cursor := media.new_download_cursor(options)!
	mut bytes := []u8{}
	for !cursor.is_complete() {
		limit := cursor.next_limit()
		if limit <= 0 {
			break
		}
		result := c.invoke(tl.UploadGetFile{
			precise:       options.precise
			cdn_supported: options.cdn_supported
			location:      location
			offset:        cursor.next_offset()
			limit:         limit
		})!
		match result {
			tl.UploadFile {
				bytes << result.bytes.clone()
				_ = cursor.accept_chunk(result.bytes.len)!
			}
			tl.UploadFileCdnRedirect {
				return media.DownloadResult{
					bytes:            bytes
					start_offset:     cursor.start_offset
					end_offset:       cursor.current_offset()
					completed:        false
					has_cdn_redirect: true
					cdn_redirect:     media.CdnRedirect{
						dc_id:          result.dc_id
						file_token:     result.file_token.clone()
						encryption_key: result.encryption_key.clone()
						encryption_iv:  result.encryption_iv.clone()
						file_hashes:    result.file_hashes.clone()
					}
				}
			}
			else {
				return error('expected upload.File, got ${result.qualified_name()}')
			}
		}
	}
	return media.DownloadResult{
		bytes:        bytes
		start_offset: cursor.start_offset
		end_offset:   cursor.current_offset()
		completed:    true
	}
}

pub fn (mut c Client) send_message(peer tl.InputPeerType, message string) !tl.UpdatesType {
	if message.len == 0 {
		return error('message must not be empty')
	}
	result := c.invoke(tl.MessagesSendMessage{
		peer:                           peer
		reply_to:                       tl.UnknownInputReplyToType{}
		has_reply_to_value:             false
		message:                        message
		random_id:                      c.random_id()!
		reply_markup:                   tl.UnknownReplyMarkupType{}
		has_reply_markup_value:         false
		send_as:                        tl.InputPeerEmpty{}
		has_send_as_value:              false
		quick_reply_shortcut:           tl.UnknownInputQuickReplyShortcutType{}
		has_quick_reply_shortcut_value: false
		suggested_post:                 tl.UnknownSuggestedPostType{}
		has_suggested_post_value:       false
	})!
	batch := expect_updates(result)!
	if c.update_manager.is_initialized() {
		mut source := RuntimeDifferenceSource{
			runtime: c.runtime
		}
		c.update_manager.ingest(batch, mut source)!
	}
	return batch
}

pub fn (mut c Client) send_file(peer tl.InputPeerType, name string, data []u8, options media.SendFileOptions) !tl.UpdatesType {
	uploaded := c.upload_file_bytes(name, data, options.upload)!
	mime_type := if options.mime_type.len > 0 {
		options.mime_type
	} else {
		'application/octet-stream'
	}
	return c.send_media_request(peer, tl.InputMediaUploadedDocument{
		nosound_video:             options.nosound_video
		force_file:                options.force_file
		spoiler:                   options.spoiler
		file:                      uploaded.input_file
		thumb:                     tl.InputFile{}
		video_cover:               tl.InputPhotoEmpty{}
		mime_type:                 mime_type
		attributes:                document_attributes_with_filename(uploaded.name, options.attributes)
		has_thumb_value:           false
		has_stickers_value:        false
		has_video_cover_value:     false
		has_video_timestamp_value: false
		has_ttl_seconds_value:     false
	}, options.caption)
}

pub fn (mut c Client) send_file_path(peer tl.InputPeerType, path string, options media.SendFileOptions) !tl.UpdatesType {
	if path.len == 0 {
		return error('file path must not be empty')
	}
	name := os.file_name(path)
	if name.len == 0 {
		return error('file path must include a file name')
	}
	data := os.read_bytes(path)!
	return c.send_file(peer, name, data, options)!
}

pub fn (mut c Client) send_file_to_username(username string, name string, data []u8, options media.SendFileOptions) !tl.UpdatesType {
	peer := c.resolve_input_peer(username)!
	return c.send_file(peer, name, data, options)!
}

pub fn (mut c Client) send_photo(peer tl.InputPeerType, name string, data []u8, options media.SendPhotoOptions) !tl.UpdatesType {
	uploaded := c.upload_file_bytes(name, data, options.upload)!
	return c.send_media_request(peer, tl.InputMediaUploadedPhoto{
		spoiler:               options.spoiler
		file:                  uploaded.input_file
		ttl_seconds:           options.ttl_seconds
		has_stickers_value:    false
		has_ttl_seconds_value: options.has_ttl_seconds_value
	}, options.caption)
}

pub fn (mut c Client) send_photo_path(peer tl.InputPeerType, path string, options media.SendPhotoOptions) !tl.UpdatesType {
	if path.len == 0 {
		return error('photo path must not be empty')
	}
	name := os.file_name(path)
	if name.len == 0 {
		return error('photo path must include a file name')
	}
	data := os.read_bytes(path)!
	return c.send_photo(peer, name, data, options)!
}

pub fn (mut c Client) send_photo_to_username(username string, name string, data []u8, options media.SendPhotoOptions) !tl.UpdatesType {
	peer := c.resolve_input_peer(username)!
	return c.send_photo(peer, name, data, options)!
}

pub fn (mut c Client) send_message_to_username(username string, message string) !tl.UpdatesType {
	peer := c.resolve_input_peer(username)!
	return c.send_message(peer, message)!
}

pub fn document_file_location(document tl.Document, thumb_size string) tl.InputFileLocationType {
	return tl.InputDocumentFileLocation{
		id:             document.id
		access_hash:    document.access_hash
		file_reference: document.file_reference.clone()
		thumb_size:     thumb_size
	}
}

pub fn photo_file_location(photo tl.Photo, thumb_size string) tl.InputFileLocationType {
	return tl.InputPhotoFileLocation{
		id:             photo.id
		access_hash:    photo.access_hash
		file_reference: photo.file_reference.clone()
		thumb_size:     thumb_size
	}
}

pub fn (c Client) cached_input_peer(key string) ?tl.InputPeerType {
	cache_key := normalize_cache_key(key)
	if cache_key in c.peer_cache {
		return c.peer_cache[cache_key].input_peer
	}
	return none
}

pub fn (mut c Client) resolve_input_peer(key string) !tl.InputPeerType {
	cache_key := normalize_cache_key(key)
	if cache_key == 'me' || cache_key == 'self' {
		return tl.InputPeerSelf{}
	}
	if cached := c.cached_input_peer(cache_key) {
		return cached
	}
	resolved := c.resolve_username(cache_key)!
	return resolved.input_peer
}

pub fn (mut c Client) resolve_username(username string) !ResolvedPeer {
	normalized := normalize_username(username)
	if normalized.len == 0 {
		return error('username must not be empty')
	}
	if normalized in c.peer_cache {
		cached := c.peer_cache[normalized]
		return ResolvedPeer{
			key:        cached.key
			username:   cached.username
			peer:       cached.peer
			input_peer: cached.input_peer
		}
	}
	result := c.invoke(tl.ContactsResolveUsername{
		username: normalized
	})!
	resolved := expect_contacts_resolved_peer(result)!
	entry := resolved_peer_from_contacts(resolved)!
	c.cache_resolved_peer(entry)
	return entry
}

pub fn (mut c Client) sync_update_state() !updates.StateVector {
	c.connect()!
	return c.ensure_update_state()!
}

pub fn (mut c Client) subscribe_updates(config updates.SubscriptionConfig) !updates.Subscription {
	c.connect()!
	c.ensure_update_state()!
	return c.update_manager.subscribe(config)!
}

pub fn (mut c Client) apply_updates(batch tl.UpdatesType) ! {
	c.connect()!
	c.ensure_update_state()!
	mut source := RuntimeDifferenceSource{
		runtime: c.runtime
	}
	c.update_manager.ingest(batch, mut source)!
}

pub fn (mut c Client) pump_updates_once() ! {
	c.connect()!
	c.ensure_update_state()!
	c.runtime.pump_once() or {
		if !c.config.rpc_config.auto_reconnect {
			return err
		}
		c.runtime.disconnect() or {}
		c.runtime.connect()!
		mut source := RuntimeDifferenceSource{
			runtime: c.runtime
		}
		c.update_manager.recover(mut source)!
		return
	}
	for batch in c.runtime.drain_updates() {
		mut source := RuntimeDifferenceSource{
			runtime: c.runtime
		}
		c.update_manager.ingest(batch, mut source)!
	}
}

fn validate_client_config(config ClientConfig) ! {
	if config.app_id <= 0 {
		return error('client config app_id must be greater than zero')
	}
	if config.app_hash.len == 0 {
		return error('client config app_hash must not be empty')
	}
	if config.dc_options.len == 0 {
		return error('client config must define at least one dc option')
	}
	for dc in config.dc_options {
		if dc.id == 0 {
			return error('client config dc options must define a non-zero id')
		}
		if dc.host.len == 0 {
			return error('client config dc options must define a host')
		}
		if dc.port <= 0 {
			return error('client config dc options must define a positive port')
		}
	}
}

fn (mut c Client) build_runtime() !(ClientRuntime, bool) {
	mut transport_engine := c.new_transport_engine()!
	stored_state := c.store.load() or {
		primary_dc := c.primary_dc() or {
			return error('client config must define at least one dc option')
		}
		_ = auth.authenticate_and_store(mut transport_engine, auth.ExchangeConfig{
			dc_id:        primary_dc.id
			public_keys:  c.config.public_keys.clone()
			test_mode:    c.config.test_mode
			is_media:     primary_dc.is_media
			padding_mode: c.config.padding_mode
		}, mut c.store)!
		mut engine := rpc.new_session_engine_from_store(transport_engine, mut c.store,
			c.config.rpc_config)!
		return SessionRuntime{
			engine: engine
		}, false
	}
	if stored_state.dc_id != 0 {
		transport_engine.select_endpoint(stored_state.dc_id)!
	}
	mut engine := rpc.new_session_engine(transport_engine, stored_state, c.config.rpc_config)!
	return SessionRuntime{
		engine: engine
	}, true
}

fn (mut c Client) ensure_update_state() !updates.StateVector {
	if state := c.update_manager.current_state() {
		return state
	}
	mut source := RuntimeDifferenceSource{
		runtime: c.runtime
	}
	return c.update_manager.bootstrap(mut source)!
}

fn (c Client) new_transport_engine() !transport.Engine {
	return transport.new_engine(transport.EngineConfig{
		endpoints: c.transport_endpoints()
		mode:      c.transport_mode()
		retry:     c.config.transport_retry
		timeouts:  c.config.transport_timeouts
	})!
}

fn (c Client) transport_endpoints() []transport.Endpoint {
	mut endpoints := []transport.Endpoint{cap: c.config.dc_options.len}
	for dc in c.config.dc_options {
		endpoints << transport.Endpoint{
			id:       dc.id
			host:     dc.host
			port:     dc.port
			is_media: dc.is_media
		}
	}
	return endpoints
}

fn (c Client) transport_mode() transport.Mode {
	return match c.config.transport {
		.intermediate { .intermediate }
		.full { .full }
		else { .abridged }
	}
}

fn (c Client) normalized_call_options(options rpc.CallOptions) rpc.CallOptions {
	if options.timeout_ms > 0 {
		return options
	}
	return c.config.default_call_options
}

fn (mut c Client) random_id() !i64 {
	bytes := crypto.default_backend().random_bytes(8)!
	mut value := u64(0)
	for index, byte in bytes {
		value |= u64(byte) << (8 * index)
	}
	return i64(value ^ u64(time.now().unix_nano()))
}

fn (mut c Client) cache_authorization(authorization tl.AuthAuthorizationType) {
	c.peer_cache['me'] = CachedPeer{
		key:        'me'
		username:   'me'
		input_peer: tl.InputPeerSelf{}
		peer:       tl.PeerUser{}
	}
	match authorization {
		tl.AuthAuthorization {
			c.cache_user_aliases(authorization.user)
		}
		else {}
	}
}

fn (mut c Client) cache_resolved_peer(peer ResolvedPeer) {
	c.peer_cache[peer.key] = CachedPeer{
		key:        peer.key
		username:   peer.username
		input_peer: peer.input_peer
		peer:       peer.peer
	}
	if peer.username.len > 0 {
		c.peer_cache[normalize_cache_key(peer.username)] = CachedPeer{
			key:        peer.key
			username:   peer.username
			input_peer: peer.input_peer
			peer:       peer.peer
		}
	}
}

fn (mut c Client) cache_user_aliases(user tl.UserType) {
	match user {
		tl.User {
			if user.has_username_value {
				c.peer_cache[normalize_cache_key(user.username)] = CachedPeer{
					key:        'user:${user.id}'
					username:   normalize_username(user.username)
					input_peer: tl.InputPeerSelf{}
					peer:       tl.PeerUser{
						user_id: user.id
					}
				}
			}
		}
		else {}
	}
}

fn (mut c Client) send_media_request(peer tl.InputPeerType, media_value tl.InputMediaType, caption string) !tl.UpdatesType {
	result := c.invoke(tl.MessagesSendMedia{
		peer:                             peer
		reply_to:                         tl.UnknownInputReplyToType{}
		has_reply_to_value:               false
		media:                            media_value
		message:                          caption
		random_id:                        c.random_id()!
		reply_markup:                     tl.UnknownReplyMarkupType{}
		has_reply_markup_value:           false
		entities:                         []tl.MessageEntityType{}
		has_entities_value:               false
		has_schedule_date_value:          false
		has_schedule_repeat_period_value: false
		send_as:                          tl.InputPeerEmpty{}
		has_send_as_value:                false
		quick_reply_shortcut:             tl.UnknownInputQuickReplyShortcutType{}
		has_quick_reply_shortcut_value:   false
		has_effect_value:                 false
		has_allow_paid_stars_value:       false
		suggested_post:                   tl.UnknownSuggestedPostType{}
		has_suggested_post_value:         false
	})!
	batch := expect_updates(result)!
	if c.update_manager.is_initialized() {
		mut source := RuntimeDifferenceSource{
			runtime: c.runtime
		}
		c.update_manager.ingest(batch, mut source)!
	}
	return batch
}

fn document_attributes_with_filename(file_name string, attributes []tl.DocumentAttributeType) []tl.DocumentAttributeType {
	mut resolved := []tl.DocumentAttributeType{}
	mut has_filename := false
	for attribute in attributes {
		match attribute {
			tl.DocumentAttributeFilename {
				has_filename = true
			}
			else {}
		}
		resolved << attribute
	}
	if !has_filename {
		mut with_filename := []tl.DocumentAttributeType{}
		with_filename << tl.DocumentAttributeType(tl.DocumentAttributeFilename{
			file_name: file_name
		})
		with_filename << resolved
		return with_filename
	}
	return resolved
}

fn login_code_request_from_object(phone_number string, object tl.Object) !LoginCodeRequest {
	match object {
		tl.AuthSentCode {
			return LoginCodeRequest{
				phone_number:    phone_number
				phone_code_hash: object.phone_code_hash
				sent_code:       object
			}
		}
		tl.AuthSentCodeSuccess {
			return LoginCodeRequest{
				phone_number:      phone_number
				sent_code:         object
				authorization:     object.authorization
				authorization_now: true
			}
		}
		tl.AuthSentCodePaymentRequired {
			return LoginCodeRequest{
				phone_number:    phone_number
				phone_code_hash: object.phone_code_hash
				sent_code:       object
			}
		}
		else {
			return error('expected auth.SentCode, got ${object.qualified_name()}')
		}
	}
}

fn expect_auth_authorization(object tl.Object) !tl.AuthAuthorizationType {
	match object {
		tl.AuthAuthorization {
			return object
		}
		tl.AuthAuthorizationSignUpRequired {
			return object
		}
		else {
			return error('expected auth.Authorization, got ${object.qualified_name()}')
		}
	}
}

fn expect_auth_logged_out(object tl.Object) !tl.AuthLoggedOutType {
	match object {
		tl.AuthLoggedOut {
			return object
		}
		else {
			return error('expected auth.LoggedOut, got ${object.qualified_name()}')
		}
	}
}

fn password_check_from_challenge(password string, challenge tl.AccountPasswordType) !tl.InputCheckPasswordSRP {
	match challenge {
		tl.AccountPassword {
			return password_check_from_account(password, challenge)!
		}
		else {
			return error('expected account.Password, got ${challenge.qualified_name()}')
		}
	}
}

fn password_check_from_account(password string, challenge tl.AccountPassword) !tl.InputCheckPasswordSRP {
	random := crypto.default_backend().random_bytes(crypto.auth_key_size)!
	return password_check_from_account_with_random(password, challenge, random)!
}

fn password_check_from_account_with_random(password string, challenge tl.AccountPassword, random []u8) !tl.InputCheckPasswordSRP {
	if !challenge.has_password || !challenge.has_current_algo_value {
		return error('account password challenge does not include SRP parameters')
	}
	if !challenge.has_srp_b_value || !challenge.has_srp_id_value {
		return error('account password challenge is missing srp parameters')
	}
	if challenge.srp_b.len == 0 {
		return error('account password challenge srp_B must not be empty')
	}
	if random.len == 0 {
		return error('SRP random input must not be empty')
	}
	algo := match challenge.current_algo {
		tl.PasswordKdfAlgoSHA256SHA256PBKDF2HMACSHA512iter100000SHA256ModPow {
			challenge.current_algo
		}
		else {
			return error('unsupported password KDF algorithm ${challenge.current_algo.qualified_name()}')
		}
	}
	backend := crypto.default_backend()
	p_bytes := crypto.left_pad(crypto.trim_leading_zero_bytes(algo.p), crypto.auth_key_size)!
	g_bytes := crypto.left_pad([u8(algo.g)], crypto.auth_key_size)!
	gb_bytes := crypto.left_pad(crypto.trim_leading_zero_bytes(challenge.srp_b), crypto.auth_key_size)!
	p := big.integer_from_bytes(crypto.trim_leading_zero_bytes(p_bytes))
	g := big.integer_from_int(algo.g)
	mut a := big.integer_from_bytes(crypto.trim_leading_zero_bytes(random))
	if a.signum == 0 {
		a = big.one_int
	}
	ga := g.big_mod_pow(a, p)!
	ga_raw, ga_sign := ga.bytes()
	if ga_sign <= 0 {
		return error('derived SRP A must be positive')
	}
	ga_bytes := crypto.left_pad(ga_raw, crypto.auth_key_size)!
	crypto.validate_dh_group(algo.g, p_bytes, gb_bytes, gb_bytes)!
	u := big.integer_from_bytes(sha256_concat(backend, ga_bytes, gb_bytes)!)
	x := big.integer_from_bytes(password_kdf_hash(backend, password.bytes(), algo.salt1,
		algo.salt2)!)
	v := g.big_mod_pow(x, p)!
	k := big.integer_from_bytes(sha256_concat(backend, p_bytes, g_bytes)!)
	kv := (k * v).mod_euclid(p)
	gb := big.integer_from_bytes(crypto.trim_leading_zero_bytes(challenge.srp_b))
	exponent := a + (u * x)
	sa := (gb - kv).mod_euclid(p).big_mod_pow(exponent, p)!
	sa_raw, sa_sign := sa.bytes()
	if sa_sign <= 0 {
		return error('derived SRP shared secret must be positive')
	}
	sa_bytes := crypto.left_pad(sa_raw, crypto.auth_key_size)!
	ka := backend.sha256(sa_bytes)!
	hp := backend.sha256(p_bytes)!
	hg := backend.sha256(g_bytes)!
	hs1 := backend.sha256(algo.salt1)!
	hs2 := backend.sha256(algo.salt2)!
	xor_hp_hg := crypto.xor_bytes(hp, hg)!
	m1 := sha256_concat(backend, xor_hp_hg, hs1, hs2, ga_bytes, gb_bytes, ka)!
	return tl.InputCheckPasswordSRP{
		srp_id: challenge.srp_id
		a:      ga_bytes
		m1:     m1
	}
}

fn expect_account_password(object tl.Object) !tl.AccountPasswordType {
	match object {
		tl.AccountPassword {
			return object
		}
		else {
			return error('expected account.Password, got ${object.qualified_name()}')
		}
	}
}

fn expect_users_user_full(object tl.Object) !tl.UsersUserFullType {
	match object {
		tl.UsersUserFull {
			return object
		}
		else {
			return error('expected users.UserFull, got ${object.qualified_name()}')
		}
	}
}

fn expect_messages_dialogs(object tl.Object) !tl.MessagesDialogsType {
	match object {
		tl.MessagesDialogs {
			return object
		}
		tl.MessagesDialogsSlice {
			return object
		}
		tl.MessagesDialogsNotModified {
			return object
		}
		else {
			return error('expected messages.Dialogs, got ${object.qualified_name()}')
		}
	}
}

fn expect_messages_chats(object tl.Object) !tl.MessagesChatsType {
	match object {
		tl.MessagesChats {
			return object
		}
		tl.MessagesChatsSlice {
			return object
		}
		else {
			return error('expected messages.Chats, got ${object.qualified_name()}')
		}
	}
}

fn expect_messages_messages(object tl.Object) !tl.MessagesMessagesType {
	match object {
		tl.MessagesMessages {
			return object
		}
		tl.MessagesMessagesSlice {
			return object
		}
		tl.MessagesChannelMessages {
			return object
		}
		tl.MessagesMessagesNotModified {
			return object
		}
		else {
			return error('expected messages.Messages, got ${object.qualified_name()}')
		}
	}
}

fn expect_updates(object tl.Object) !tl.UpdatesType {
	match object {
		tl.UpdatesTooLong {
			return object
		}
		tl.UpdateShortMessage {
			return object
		}
		tl.UpdateShortChatMessage {
			return object
		}
		tl.UpdateShort {
			return object
		}
		tl.UpdatesCombined {
			return object
		}
		tl.Updates {
			return object
		}
		tl.UpdateShortSentMessage {
			return object
		}
		else {
			return error('expected Updates, got ${object.qualified_name()}')
		}
	}
}

fn expect_bool_true(object tl.Object, operation string) ! {
	match object {
		tl.BoolTrue {
			return
		}
		tl.BoolFalse {
			return error('${operation} returned Bool.false')
		}
		else {
			return error('expected Bool, got ${object.qualified_name()}')
		}
	}
}

fn expect_contacts_resolved_peer(object tl.Object) !tl.ContactsResolvedPeer {
	match object {
		tl.ContactsResolvedPeer {
			return *object
		}
		else {
			return error('expected contacts.ResolvedPeer, got ${object.qualified_name()}')
		}
	}
}

fn resolved_peer_from_contacts(resolved tl.ContactsResolvedPeer) !ResolvedPeer {
	input_peer, key := input_peer_from_resolved_peer(resolved)!
	return ResolvedPeer{
		key:        key
		username:   resolved_peer_username(resolved)
		peer:       resolved.peer
		input_peer: input_peer
		users:      resolved.users.clone()
		chats:      resolved.chats.clone()
	}
}

fn input_peer_from_resolved_peer(resolved tl.ContactsResolvedPeer) !(tl.InputPeerType, string) {
	match resolved.peer {
		tl.PeerUser {
			user := find_user_by_id(resolved.users, resolved.peer.user_id) or {
				return error('resolved peer did not include user ${resolved.peer.user_id}')
			}
			if !user.has_access_hash_value {
				return error('resolved user ${user.id} is missing an access hash')
			}
			return tl.InputPeerUser{
				user_id:     user.id
				access_hash: user.access_hash
			}, 'user:${user.id}'
		}
		tl.PeerChat {
			return tl.InputPeerChat{
				chat_id: resolved.peer.chat_id
			}, 'chat:${resolved.peer.chat_id}'
		}
		tl.PeerChannel {
			channel := find_channel_by_id(resolved.chats, resolved.peer.channel_id) or {
				return error('resolved peer did not include channel ${resolved.peer.channel_id}')
			}
			return tl.InputPeerChannel{
				channel_id:  channel.id
				access_hash: channel.access_hash
			}, 'channel:${channel.id}'
		}
		else {
			return error('unsupported resolved peer ${resolved.peer.qualified_name()}')
		}
	}
}

fn resolved_peer_username(resolved tl.ContactsResolvedPeer) string {
	match resolved.peer {
		tl.PeerUser {
			if user := find_user_by_id(resolved.users, resolved.peer.user_id) {
				if user.has_username_value {
					return normalize_username(user.username)
				}
			}
		}
		tl.PeerChannel {
			if channel := find_channel_by_id(resolved.chats, resolved.peer.channel_id) {
				if channel.username.len > 0 {
					return normalize_username(channel.username)
				}
			}
		}
		else {}
	}
	return ''
}

fn find_user_by_id(users []tl.UserType, user_id i64) ?tl.User {
	for user in users {
		match user {
			tl.User {
				if user.id == user_id {
					return *user
				}
			}
			else {}
		}
	}
	return none
}

fn find_channel_by_id(chats []tl.ChatType, channel_id i64) ?ChannelHandle {
	for chat in chats {
		match chat {
			tl.Channel {
				if chat.id == channel_id {
					if !chat.has_access_hash_value {
						return none
					}
					return ChannelHandle{
						id:          chat.id
						access_hash: chat.access_hash
						username:    if chat.has_username_value { chat.username } else { '' }
					}
				}
			}
			tl.ChannelForbidden {
				if chat.id == channel_id {
					return ChannelHandle{
						id:          chat.id
						access_hash: chat.access_hash
					}
				}
			}
			else {}
		}
	}
	return none
}

fn normalize_limit(limit int) int {
	if limit <= 0 {
		return 50
	}
	return limit
}

fn normalize_username(value string) string {
	mut normalized := value.trim_space()
	if normalized.starts_with('@') {
		normalized = normalized[1..]
	}
	return normalized.to_lower()
}

fn normalize_cache_key(value string) string {
	if value.contains(':') {
		return value.to_lower()
	}
	return normalize_username(value)
}

fn password_kdf_hash(backend crypto.Backend, password []u8, salt1 []u8, salt2 []u8) ![]u8 {
	primary := salted_sha256(backend, salted_sha256(backend, password, salt1)!, salt2)!
	pbkdf2 := crypto.pbkdf2_hmac_sha512(primary, salt1, 100_000, 64)!
	return salted_sha256(backend, pbkdf2, salt2)!
}

fn salted_sha256(backend crypto.Backend, data []u8, salt []u8) ![]u8 {
	return sha256_concat(backend, salt, data, salt)!
}

fn sha256_concat(backend crypto.Backend, parts ...[]u8) ![]u8 {
	mut input := []u8{}
	for part in parts {
		input << part
	}
	return backend.sha256(input)!
}
