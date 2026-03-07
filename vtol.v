module vtol

import auth
import crypto
import rpc
import session
import time
import tl
import transport
import updates

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
	return new_client_with_store(config, session.new_memory_session())
}

pub fn new_client_with_sqlite_session(config ClientConfig, path string) !Client {
	store := session.new_sqlite_session(path)!
	return new_client_with_store(config, store)
}

pub fn new_client_with_session_file(config ClientConfig, path string) !Client {
	return new_client_with_sqlite_session(config, path)
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
	c.persist_session()!
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
	result := c.runtime.invoke(request, c.normalized_call_options(options)) or {
		if err is rpc.RpcError {
			return IError(public_rpc_error_from_internal(err))
		}
		return err
	}
	c.persist_session()!
	return result
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
	c.store.save(session.SessionData{
		state: session_state_with_endpoint(result.session_state(), dc)
		peers: c.stored_peer_records()
	})!

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
	stored := c.store.load() or {
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
		c.store.save(session.SessionData{
			state: session_state_with_endpoint(result.session_state(), primary_dc)
			peers: c.stored_peer_records()
		})!
		mut engine := rpc.new_session_engine_from_store(transport_engine, mut c.store,
			c.config.rpc_config)!
		return SessionRuntime{
			engine: engine
		}, false
	}
	c.restore_peer_cache(stored.peers)
	stored_state := stored.state
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

fn (mut c Client) restore_peer_cache(records []session.PeerRecord) {
	c.peer_cache = map[string]CachedPeer{}
	for record in records {
		c.peer_cache[record.cache_key] = CachedPeer{
			key:        record.key
			username:   record.username
			input_peer: record.input_peer
			peer:       record.peer
		}
	}
}

fn (c Client) stored_peer_records() []session.PeerRecord {
	mut cache_keys := c.peer_cache.keys()
	cache_keys.sort()
	mut peers := []session.PeerRecord{cap: cache_keys.len}
	for cache_key in cache_keys {
		cached := c.peer_cache[cache_key]
		peers << session.PeerRecord{
			cache_key:  cache_key
			key:        cached.key
			username:   cached.username
			peer:       cached.peer
			input_peer: cached.input_peer
		}
	}
	return peers
}

fn (mut c Client) persist_session() ! {
	if !c.runtime_ready {
		return
	}
	c.store.save(session.SessionData{
		state: c.runtime.session_state()
		peers: c.stored_peer_records()
	})!
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
