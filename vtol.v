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

struct FunctionObjectAdapter {
	function tl.Function
}

fn (a FunctionObjectAdapter) encode() ![]u8 {
	return a.function.encode()!
}

fn (a FunctionObjectAdapter) constructor_id() u32 {
	return a.function.constructor_id()
}

fn (a FunctionObjectAdapter) qualified_name() string {
	return a.function.qualified_name()
}

fn (a FunctionObjectAdapter) method_name() string {
	return a.function.method_name()
}

fn (a FunctionObjectAdapter) result_type_name() string {
	return a.function.result_type_name()
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
	return r.engine.invoke(function, options) or {
		if err is rpc.RpcError {
			return IError(public_rpc_error_from_internal(err))
		}
		return err
	}
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
	dc_options     []DcOption
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

pub fn new_client_with_session_file(config ClientConfig, path string) !Client {
	store := session.new_file_store(path)!
	return new_client_with_store(config, store)
}

pub fn new_client_with_store(config ClientConfig, store session.Store) !Client {
	validate_client_config(config)!
	return Client{
		config:         config
		dc_options:     merge_dc_options(config.dc_options.clone(), default_dc_options(config.test_mode))
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
	if c.dc_options.len == 0 {
		return none
	}
	return c.dc_options[0]
}

fn (c Client) dc_option_by_id(dc_id int) ?DcOption {
	for dc in c.dc_options {
		if dc.id == dc_id {
			return dc
		}
	}
	return none
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
	request := c.wrap_client_invoke(function)
	return c.runtime.invoke(request, c.normalized_call_options(options)) or {
		if err is rpc.RpcError {
			return IError(public_rpc_error_from_internal(err))
		}
		return err
	}
}

fn (mut c Client) invoke_auth_with_migration(function tl.Function) !tl.Object {
	result := c.invoke(function) or {
		if err is RpcError {
			if dc_id := err.migration_dc_id() {
				c.switch_auth_dc(dc_id)!
				return c.invoke(function)
			}
		}
		return err
	}
	return result
}

fn (mut c Client) switch_auth_dc(dc_id int) ! {
	if dc_id == 0 {
		return error('auth dc migration target must be non-zero')
	}
	dc := c.ensure_dc_option(dc_id)!
	if c.runtime_ready && c.runtime.is_connected() {
		c.runtime.disconnect() or {}
	}
	c.state = .disconnected
	c.runtime = NullRuntime{}
	c.runtime_ready = false
	c.session_loaded = false

	mut transport_engine := c.new_transport_engine()!
	_ = transport_engine.select_endpoint(dc.id)!
	result := auth.authenticate_and_store(mut transport_engine, auth.ExchangeConfig{
		dc_id:        dc.id
		public_keys:  c.config.public_keys.clone()
		test_mode:    c.config.test_mode
		is_media:     dc.is_media
		padding_mode: c.config.padding_mode
	}, mut c.store)!
	c.store.save(session_state_with_endpoint(result.session_state(), dc))!

	runtime, _ := c.build_runtime()!
	c.runtime = runtime
	c.runtime_ready = true
	c.session_loaded = false
	c.runtime.connect()!
	c.state = .connected
}

fn (mut c Client) ensure_dc_option(dc_id int) !DcOption {
	if dc := c.dc_option_by_id(dc_id) {
		return dc
	}
	c.refresh_dc_options()!
	if dc := c.dc_option_by_id(dc_id) {
		return dc
	}
	return error('transport endpoint ${dc_id} is not configured')
}

fn (mut c Client) refresh_dc_options() ! {
	result := c.invoke(tl.HelpGetConfig{})!
	config := expect_config(result)!
	discovered := dc_options_from_config(config)
	c.dc_options = merge_dc_options(c.dc_options, discovered)
}

fn (c Client) wrap_client_invoke(function tl.Function) tl.Function {
	match function {
		tl.InitConnection {
			return function
		}
		tl.InvokeWithLayer {
			return function
		}
		else {}
	}
	return tl.InvokeWithLayer{
		layer: tl.current_layer_info().layer
		query: tl.InitConnection{
			api_id:           c.config.app_id
			device_model:     c.config.device_model
			system_version:   c.config.system_version
			app_version:      c.config.app_version
			system_lang_code: c.config.system_lang_code
			lang_pack:        c.config.lang_pack
			lang_code:        c.config.lang_code
			proxy:            tl.UnknownInputClientProxyType{}
			has_proxy_value:  false
			params:           tl.UnknownJSONValueType{}
			has_params_value: false
			query:            FunctionObjectAdapter{
				function: function
			}
		}
	}
}

pub fn (mut c Client) send_login_code(phone_number string) !LoginCodeRequest {
	return c.send_login_code_with_settings(phone_number, tl.CodeSettings{
		allow_app_hash: true
	})
}

pub fn (mut c Client) send_login_code_with_settings(phone_number string, settings tl.CodeSettingsType) !LoginCodeRequest {
	result := c.invoke_auth_with_migration(tl.AuthSendCode{
		phone_number: phone_number
		api_id:       c.config.app_id
		api_hash:     c.config.app_hash
		settings:     settings
	}) or { return wrap_auth_error(err) }
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
	result := c.invoke_auth_with_migration(tl.AuthSignIn{
		phone_number:                 phone_number
		phone_code_hash:              phone_code_hash
		phone_code:                   code
		has_phone_code_value:         true
		email_verification:           tl.UnknownEmailVerificationType{}
		has_email_verification_value: false
	}) or { return wrap_auth_error(err) }
	authorization := expect_auth_authorization(result)!
	c.cache_authorization(authorization)
	return authorization
}

pub fn (mut c Client) get_password_challenge() !tl.AccountPasswordType {
	result := c.invoke_auth_with_migration(tl.AccountGetPassword{})!
	return expect_account_password(result)!
}

pub fn (mut c Client) check_password(password tl.InputCheckPasswordSRPType) !tl.AuthAuthorizationType {
	result := c.invoke_auth_with_migration(tl.AuthCheckPassword{
		password: password
	}) or { return wrap_auth_error(err) }
	authorization := expect_auth_authorization(result)!
	c.cache_authorization(authorization)
	return authorization
}

pub fn (mut c Client) sign_in_password(password string) !tl.AuthAuthorizationType {
	challenge := c.get_password_challenge()!
	password_check := password_check_from_challenge(password, challenge)!
	return c.check_password(password_check)!
}

pub fn (mut c Client) complete_login(request LoginCodeRequest, code string, password string) !tl.AuthAuthorizationType {
	return c.sign_in_code(request, code) or {
		if err is AuthError && err.requires_password() && password.len > 0 {
			return c.sign_in_password(password)
		}
		return err
	}
}

pub fn (mut c Client) start(options StartOptions) !tl.UsersUserFullType {
	c.connect()!
	if c.did_restore_session() {
		return c.get_me()!
	}
	phone_number, bot_token := resolve_start_identity(options)!
	if bot_token.len > 0 {
		_ = c.login_bot(bot_token)!
		return c.get_me()!
	}
	mut request := c.send_login_code_with_settings(phone_number, options.code_settings)!
	if options.code_sent_callback != unsafe { nil } {
		options.code_sent_callback(request)
	}
	for {
		code := resolve_start_code(options, request)!
		if _ := c.complete_login(request, code, '') {
			return c.get_me()!
		} else {
			if err is AuthError {
				if err.requires_password() {
					if options.password == unsafe { nil } {
						return IError(err)
					}
					_ = c.start_password_flow(options)!
					return c.get_me()!
				}
				if can_retry_start_code(options, err) {
					options.invalid_auth_callback(AuthPromptKind.code, err)
					if err.is_code_expired() || err.kind == .code_hash_invalid {
						request = c.send_login_code_with_settings(phone_number, options.code_settings)!
						if options.code_sent_callback != unsafe { nil } {
							options.code_sent_callback(request)
						}
					}
					continue
				}
			}
			return err
		}
	}
	return error('unreachable')
}

pub fn (mut c Client) interactive_login(options StartOptions) !tl.UsersUserFullType {
	return c.start(options)!
}

pub fn (mut c Client) login_bot(bot_token string) !tl.AuthAuthorizationType {
	result := c.invoke_auth_with_migration(tl.AuthImportBotAuthorization{
		flags:          0
		api_id:         c.config.app_id
		api_hash:       c.config.app_hash
		bot_auth_token: bot_token
	}) or { return wrap_auth_error(err) }
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
	return media.document_file_reference(document, thumb_size).input_location()
}

pub fn photo_file_location(photo tl.Photo, thumb_size string) tl.InputFileLocationType {
	return media.photo_file_reference(photo, thumb_size).input_location()
}

pub fn document_file_reference(document tl.Document, thumb_size string) media.FileReference {
	return media.document_file_reference(document, thumb_size)
}

pub fn photo_file_reference(photo tl.Photo, thumb_size string) media.FileReference {
	return media.photo_file_reference(photo, thumb_size)
}

pub fn (mut c Client) download_file_reference(reference media.FileReference, options media.DownloadOptions) !media.DownloadResult {
	return c.download_file(reference.input_location(), options)!
}

pub fn (mut c Client) get_file_hashes(location tl.InputFileLocationType, offset i64) ![]tl.FileHashType {
	if offset < 0 {
		return error('file hash offset must not be negative')
	}
	result := c.invoke(tl.UploadGetFileHashes{
		location: location
		offset:   offset
	})!
	return expect_file_hashes(result)!
}

pub fn (mut c Client) get_cdn_file_hashes(file_token []u8, offset i64) ![]tl.FileHashType {
	if file_token.len == 0 {
		return error('cdn file token must not be empty')
	}
	if offset < 0 {
		return error('cdn file hash offset must not be negative')
	}
	result := c.invoke(tl.UploadGetCdnFileHashes{
		file_token: file_token.clone()
		offset:     offset
	})!
	return expect_file_hashes(result)!
}

pub fn (mut c Client) reupload_cdn_file(file_token []u8, request_token []u8) ![]tl.FileHashType {
	if file_token.len == 0 {
		return error('cdn file token must not be empty')
	}
	if request_token.len == 0 {
		return error('cdn request token must not be empty')
	}
	result := c.invoke(tl.UploadReuploadCdnFile{
		file_token:    file_token.clone()
		request_token: request_token.clone()
	})!
	return expect_file_hashes(result)!
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
		result := auth.authenticate_and_store(mut transport_engine, auth.ExchangeConfig{
			dc_id:        primary_dc.id
			public_keys:  c.config.public_keys.clone()
			test_mode:    c.config.test_mode
			is_media:     primary_dc.is_media
			padding_mode: c.config.padding_mode
		}, mut c.store)!
		c.store.save(session_state_with_endpoint(result.session_state(), primary_dc))!
		mut engine := rpc.new_session_engine_from_store(transport_engine, mut c.store,
			c.config.rpc_config)!
		return SessionRuntime{
			engine: engine
		}, false
	}
	if stored_state.dc_id != 0 {
		if c.dc_option_by_id(stored_state.dc_id) == none && stored_state.dc_address.len > 0
			&& stored_state.dc_port > 0 {
			c.dc_options = merge_dc_options(c.dc_options, [
				DcOption{
					id:   stored_state.dc_id
					host: stored_state.dc_address
					port: stored_state.dc_port
				},
			])
		}
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
	mut endpoints := []transport.Endpoint{cap: c.dc_options.len}
	for dc in c.dc_options {
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

fn public_rpc_error_from_internal(err rpc.RpcError) RpcError {
	return RpcError{
		rpc_code:       err.rpc_code
		message:        err.message
		raw:            err.raw
		wait_seconds:   err.wait_seconds
		premium_wait:   err.premium_wait
		has_rate_limit: err.has_rate_limit
	}
}

fn auth_error_kind(code string) AuthErrorKind {
	return match code {
		'SESSION_PASSWORD_NEEDED' { .password_required }
		'PHONE_CODE_INVALID', 'CODE_INVALID' { .code_invalid }
		'PHONE_CODE_EXPIRED' { .code_expired }
		'PHONE_NUMBER_INVALID' { .phone_number_invalid }
		'PHONE_CODE_HASH_EMPTY', 'PHONE_CODE_HASH_INVALID' { .code_hash_invalid }
		'PHONE_CODE_EMPTY' { .code_empty }
		'PASSWORD_HASH_INVALID' { .password_invalid }
		'BOT_TOKEN_INVALID' { .bot_token_invalid }
		else { .unknown }
	}
}

fn auth_error_message(kind AuthErrorKind, code string) string {
	return match kind {
		.password_required { 'account requires a 2FA password' }
		.code_invalid { 'login code is invalid' }
		.code_expired { 'login code has expired' }
		.phone_number_invalid { 'phone number is invalid' }
		.code_hash_invalid { 'login code request is invalid or expired' }
		.code_empty { 'login code must not be empty' }
		.password_invalid { '2FA password is invalid' }
		.bot_token_invalid { 'bot token is invalid' }
		else { 'telegram auth failed: ${code}' }
	}
}

fn auth_error_from_rpc(err RpcError) ?AuthError {
	kind := auth_error_kind(err.message)
	if kind == .unknown {
		return none
	}
	return AuthError{
		kind:      kind
		auth_code: err.message
		message:   auth_error_message(kind, err.message)
		raw:       err
	}
}

fn wrap_auth_error(err IError) IError {
	if err is AuthError {
		return err
	}
	if err is RpcError {
		if auth_err := auth_error_from_rpc(err) {
			return IError(auth_err)
		}
	}
	return err
}

fn resolve_start_identity(options StartOptions) !(string, string) {
	mut phone_number := ''
	if options.phone_number != unsafe { nil } {
		phone_number = options.phone_number()!.trim_space()
	}
	if phone_number.len > 0 {
		return phone_number, ''
	}
	mut bot_token := ''
	if options.bot_token != unsafe { nil } {
		bot_token = options.bot_token()!.trim_space()
	}
	if bot_token.len > 0 {
		return '', bot_token
	}
	return error('start options must provide a phone_number or bot_token callback that returns a value')
}

fn resolve_start_code(options StartOptions, request LoginCodeRequest) !string {
	if options.code == unsafe { nil } {
		return error('start options must provide a code callback')
	}
	code := options.code(request)!.trim_space()
	if code.len == 0 {
		return error('login code must not be empty')
	}
	return code
}

fn resolve_start_password(options StartOptions) !string {
	if options.password == unsafe { nil } {
		return error('start options must provide a password callback')
	}
	password := options.password()!.trim_space()
	if password.len == 0 {
		return error('2FA password must not be empty')
	}
	return password
}

fn can_retry_start_code(options StartOptions, err AuthError) bool {
	return options.code != unsafe { nil } && options.invalid_auth_callback != unsafe { nil }
		&& (err.is_code_invalid() || err.is_code_expired()
		|| err.kind == .code_hash_invalid)
}

fn (mut c Client) start_password_flow(options StartOptions) !tl.AuthAuthorizationType {
	for {
		password := resolve_start_password(options)!
		if authorization := c.sign_in_password(password) {
			return authorization
		} else {
			if err is AuthError && options.invalid_auth_callback != unsafe { nil }
				&& err.is_password_invalid() {
				options.invalid_auth_callback(AuthPromptKind.password, err)
				continue
			}
			return err
		}
	}
	return error('unreachable')
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

fn expect_config(object tl.Object) !tl.Config {
	match object {
		tl.Config {
			return *object
		}
		else {
			return error('expected config, got ${object.qualified_name()}')
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

fn dc_options_from_config(config tl.Config) []DcOption {
	mut options := []DcOption{}
	for option in config.dc_options {
		match option {
			tl.DcOption {
				if option.cdn || option.tcpo_only || option.ip_address.len == 0 || option.port <= 0 {
					continue
				}
				options << DcOption{
					id:       option.id
					host:     option.ip_address
					port:     option.port
					is_media: option.media_only
				}
			}
			else {}
		}
	}
	return options
}

fn merge_dc_options(existing []DcOption, discovered []DcOption) []DcOption {
	mut merged := existing.clone()
	mut known_ids := map[int]bool{}
	for dc in merged {
		known_ids[dc.id] = true
	}
	for dc in discovered {
		if dc.id in known_ids {
			continue
		}
		merged << dc
		known_ids[dc.id] = true
	}
	return merged
}

fn default_dc_options(test_mode bool) []DcOption {
	if test_mode {
		return []DcOption{}
	}
	return [
		DcOption{
			id:   1
			host: '149.154.175.50'
			port: 443
		},
		DcOption{
			id:   2
			host: '149.154.167.51'
			port: 443
		},
		DcOption{
			id:   3
			host: '149.154.175.100'
			port: 443
		},
		DcOption{
			id:   4
			host: '149.154.167.91'
			port: 443
		},
		DcOption{
			id:   5
			host: '149.154.171.5'
			port: 443
		},
	]
}

fn session_state_with_endpoint(state session.SessionState, dc DcOption) session.SessionState {
	return session.SessionState{
		dc_id:           state.dc_id
		dc_address:      dc.host
		dc_port:         dc.port
		auth_key:        state.auth_key.clone()
		auth_key_id:     state.auth_key_id
		server_salt:     state.server_salt
		session_id:      state.session_id
		layer:           state.layer
		schema_revision: state.schema_revision
		created_at:      state.created_at
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

fn expect_file_hashes(object tl.Object) ![]tl.FileHashType {
	match object {
		tl.UnknownObject {
			if object.constructor != tl.vector_constructor_id {
				return error('expected Vector<FileHash>, got ${object.qualified_name()}')
			}
			mut payload := object.encode()!
			mut decoder := tl.new_decoder(payload)
			count := decoder.read_vector_len()!
			mut remaining := decoder.read_remaining()
			mut hashes := []tl.FileHashType{cap: count}
			for _ in 0 .. count {
				item, consumed := tl.decode_object_prefix(remaining)!
				match item {
					tl.FileHash {
						hashes << tl.FileHashType(item)
					}
					tl.UnknownObject {
						hashes << tl.FileHashType(tl.UnknownFileHashType{
							constructor: item.constructor
							name:        item.name
							raw_payload: item.raw_payload.clone()
						})
					}
					else {
						return error('expected FileHash, got ${item.qualified_name()}')
					}
				}
				remaining = remaining[consumed..].clone()
			}
			if remaining.len != 0 {
				return error('unexpected trailing bytes in Vector<FileHash>')
			}
			return hashes
		}
		else {
			return error('expected Vector<FileHash>, got ${object.qualified_name()}')
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
