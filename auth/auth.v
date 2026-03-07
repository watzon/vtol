module auth

import crypto
import math.big
import session
import time
import tl
import transport

// HandshakeState tracks progress through the unauthenticated MTProto key exchange.
pub enum HandshakeState {
	idle
	waiting_pq
	waiting_dh_params
	waiting_dh_gen
	complete
	failed
}

// RsaPaddingMode selects which RSA padding variant to use during auth.
pub enum RsaPaddingMode {
	auto
	mtproto2
	legacy
}

// AuthKeyMeta summarizes the metadata associated with an authenticated key.
pub struct AuthKeyMeta {
pub:
	dc_id           int
	key_id          i64
	session_id      i64
	layer           int
	schema_revision string
	created_at      i64
}

// ExchangeConfig configures a one-time MTProto authentication exchange.
pub struct ExchangeConfig {
pub:
	dc_id        int
	public_keys  []crypto.PublicKey
	session_id   i64
	test_mode    bool
	is_media     bool
	temporary    bool
	expires_in   int
	padding_mode RsaPaddingMode = .auto
}

// HandshakeResult contains the authorization material produced by a handshake.
pub struct HandshakeResult {
pub:
	dc_id               int
	auth_key            []u8
	auth_key_id         i64
	server_salt         i64
	session_id          i64
	layer               int
	schema_revision     string
	created_at          i64
	time_offset_seconds int
}

// Sender abstracts the unencrypted function transport used during handshake.
pub interface Sender {
mut:
	invoke(function tl.Function) !tl.Object
}

struct EngineSender {
mut:
	engine &transport.Engine
}

fn (mut s EngineSender) invoke(function tl.Function) !tl.Object {
	return s.engine.invoke_unencrypted(function)!
}

// authenticate performs the MTProto auth handshake over a transport engine.
pub fn authenticate(mut engine transport.Engine, config ExchangeConfig) !HandshakeResult {
	modes := match config.padding_mode {
		.auto { [RsaPaddingMode.mtproto2, .legacy] }
		.mtproto2 { [RsaPaddingMode.mtproto2] }
		.legacy { [RsaPaddingMode.legacy] }
	}
	mut last_error := error('authorization handshake failed')
	for index, mode in modes {
		if !engine.is_connected() {
			engine.connect()!
		}
		mut sender := EngineSender{
			engine: unsafe { &engine }
		}
		result := exchange_with_padding(mut sender, config, mode) or {
			last_error = err
			if index < modes.len - 1 {
				engine.disconnect() or {}
				continue
			}
			return err
		}
		return result
	}
	return last_error
}

// authenticate_and_store performs the handshake and persists the resulting session state.
pub fn authenticate_and_store(mut engine transport.Engine, config ExchangeConfig, mut store session.Store) !HandshakeResult {
	result := authenticate(mut engine, config)!
	store.save(session.SessionData{
		state: result.session_state()
		peers: []session.PeerRecord{}
	})!
	return result
}

// exchange performs the MTProto auth handshake using a caller-provided Sender.
pub fn exchange(mut sender Sender, config ExchangeConfig) !HandshakeResult {
	mode := if config.padding_mode == .legacy {
		RsaPaddingMode.legacy
	} else {
		RsaPaddingMode.mtproto2
	}
	return exchange_with_padding(mut sender, config, mode)!
}

fn exchange_with_padding(mut sender Sender, config ExchangeConfig, padding_mode RsaPaddingMode) !HandshakeResult {
	if config.dc_id == 0 {
		return error('exchange config must define a non-zero dc id')
	}
	keys := if config.public_keys.len == 0 {
		crypto.default_public_keys()
	} else {
		config.public_keys.clone()
	}
	backend := crypto.default_backend()
	mut state := HandshakeState.waiting_pq

	nonce := backend.random_bytes(crypto.nonce_size)!
	res_pq_object := sender.invoke(tl.ReqPqMulti{
		nonce: nonce
	})!
	res_pq := match res_pq_object {
		tl.ResPQ {
			res_pq_object
		}
		else {
			state = .failed
			return error('expected resPQ but received ${res_pq_object.qualified_name()}')
		}
	}
	validate_nonce_pair(state, nonce, res_pq.nonce, []u8{}, []u8{})!

	public_key := crypto.select_public_key(keys, res_pq.server_public_key_fingerprints)!
	factors := crypto.factorize_pq(res_pq.pq.bytes())!
	new_nonce := backend.random_bytes(crypto.new_nonce_size)!
	server_nonce := res_pq.server_nonce.clone()

	state = .waiting_dh_params
	inner_data := build_pq_inner_data(config, res_pq, factors, new_nonce)
	encrypted_data := match padding_mode {
		.legacy { crypto.rsa_pad_legacy(inner_data, public_key, backend)! }
		else { crypto.rsa_pad_v2(inner_data, public_key, backend)! }
	}
	req_dh_params_object := sender.invoke(tl.ReqDHParams{
		nonce:                  nonce
		server_nonce:           server_nonce
		p:                      factors.p.bytestr()
		q:                      factors.q.bytestr()
		public_key_fingerprint: public_key.fingerprint
		encrypted_data:         encrypted_data.bytestr()
	})!

	match req_dh_params_object {
		tl.ServerDHParamsFail {
			validate_nonce_pair(state, nonce, req_dh_params_object.nonce, server_nonce,
				req_dh_params_object.server_nonce)!
			expected_fail_hash := backend.sha1(new_nonce)!
			if req_dh_params_object.new_nonce_hash != expected_fail_hash[4..20] {
				state = .failed
				return error('server_DH_params_fail new_nonce_hash mismatch')
			}
			state = .failed
			return error('server rejected DH params')
		}
		tl.ServerDHParamsOk {
			validate_nonce_pair(state, nonce, req_dh_params_object.nonce, server_nonce,
				req_dh_params_object.server_nonce)!
			tmp_key_iv := crypto.derive_tmp_aes_key_iv(backend, new_nonce, server_nonce)!
			encrypted_answer := req_dh_params_object.encrypted_answer.bytes()
			if encrypted_answer.len % crypto.aes_block_size != 0 {
				state = .failed
				return error('encrypted server DH answer length must be divisible by 16')
			}
			answer_with_hash := backend.aes_ige_decrypt(encrypted_answer, tmp_key_iv.key,
				tmp_key_iv.iv)!
			server_dh_inner := decode_hashed_tl_object(answer_with_hash, backend)!
			inner := match server_dh_inner {
				tl.ServerDHInnerData {
					server_dh_inner
				}
				else {
					state = .failed
					return error('expected server_DH_inner_data but received ${server_dh_inner.qualified_name()}')
				}
			}
			validate_nonce_pair(state, nonce, inner.nonce, server_nonce, inner.server_nonce)!
			state = .waiting_dh_gen

			dh_prime_bytes := inner.dh_prime.bytes()
			dh_prime := big.integer_from_bytes(crypto.trim_leading_zero_bytes(dh_prime_bytes))
			g_a_bytes := inner.g_a.bytes()
			g_a := big.integer_from_bytes(crypto.trim_leading_zero_bytes(g_a_bytes))
			b_bytes := backend.random_bytes(crypto.auth_key_size)!
			mut b := big.integer_from_bytes(crypto.trim_leading_zero_bytes(b_bytes))
			if b.signum == 0 {
				b = big.one_int
			}
			g_b := big.integer_from_int(inner.g).big_mod_pow(b, dh_prime)!
			g_b_bytes_raw, g_b_sign := g_b.bytes()
			if g_b_sign <= 0 {
				state = .failed
				return error('derived g_b must be positive')
			}
			g_b_bytes := crypto.left_pad(g_b_bytes_raw, crypto.auth_key_size)!
			crypto.validate_dh_group(inner.g, dh_prime_bytes, g_a_bytes, g_b_bytes)!

			client_inner := tl.ClientDHInnerData{
				nonce:        nonce
				server_nonce: server_nonce
				retry_id:     0
				g_b:          g_b_bytes.bytestr()
			}.encode()!
			mut client_inner_with_hash := backend.sha1(client_inner)!
			client_inner_with_hash << client_inner
			client_inner_with_hash = pad_random(client_inner_with_hash, crypto.aes_block_size,
				backend)!
			encrypted_client_inner := backend.aes_ige_encrypt(client_inner_with_hash,
				tmp_key_iv.key, tmp_key_iv.iv)!

			dh_gen_object := sender.invoke(tl.SetClientDHParams{
				nonce:          nonce
				server_nonce:   server_nonce
				encrypted_data: encrypted_client_inner.bytestr()
			})!

			auth_key := g_a.big_mod_pow(b, dh_prime)!
			auth_key_bytes_raw, auth_key_sign := auth_key.bytes()
			if auth_key_sign <= 0 {
				state = .failed
				return error('derived auth key must be positive')
			}
			auth_key_bytes := crypto.left_pad(auth_key_bytes_raw, crypto.auth_key_size)!
			auth_key_id := crypto.derive_auth_key_id(backend, auth_key_bytes)!
			session_id := if config.session_id != 0 {
				config.session_id
			} else {
				random_session_id(backend)!
			}
			server_salt := crypto.derive_server_salt(new_nonce, server_nonce)!
			nonce_number, actual_nonce_hash := dh_gen_hash_parts(dh_gen_object)!
			expected_nonce_hash := crypto.derive_new_nonce_hash(backend, new_nonce, auth_key_bytes,
				nonce_number)!
			validate_dh_gen_response(nonce, server_nonce, expected_nonce_hash, actual_nonce_hash,
				dh_gen_object)!
			if dh_gen_object !is tl.DhGenOk {
				state = .failed
				return error('server returned ${dh_gen_object.qualified_name()} during DH completion')
			}
			state = .complete
			layer_info := tl.current_layer_info()
			return HandshakeResult{
				dc_id:               config.dc_id
				auth_key:            auth_key_bytes
				auth_key_id:         auth_key_id
				server_salt:         server_salt
				session_id:          session_id
				layer:               layer_info.layer
				schema_revision:     layer_info.schema_revision
				created_at:          time.now().unix()
				time_offset_seconds: inner.server_time - int(time.now().unix())
			}
		}
		else {
			state = .failed
			return error('expected server_DH_params response but received ${req_dh_params_object.qualified_name()}')
		}
	}
}

// meta returns the metadata-only view of the handshake result.
pub fn (r HandshakeResult) meta() AuthKeyMeta {
	return AuthKeyMeta{
		dc_id:           r.dc_id
		key_id:          r.auth_key_id
		session_id:      r.session_id
		layer:           r.layer
		schema_revision: r.schema_revision
		created_at:      r.created_at
	}
}

// session_state converts the handshake result into a persistable session.SessionState.
pub fn (r HandshakeResult) session_state() session.SessionState {
	return session.SessionState{
		dc_id:           r.dc_id
		auth_key:        r.auth_key.clone()
		auth_key_id:     r.auth_key_id
		server_salt:     r.server_salt
		session_id:      r.session_id
		layer:           r.layer
		schema_revision: r.schema_revision
		created_at:      r.created_at
	}
}

fn build_pq_inner_data(config ExchangeConfig, res_pq tl.ResPQ, factors crypto.PQFactors, new_nonce []u8) []u8 {
	dc := normalize_dc_id(config)
	if config.temporary {
		return tl.PQInnerDataTempDc{
			pq:           factors.pq.bytestr()
			p:            factors.p.bytestr()
			q:            factors.q.bytestr()
			nonce:        res_pq.nonce.clone()
			server_nonce: res_pq.server_nonce.clone()
			new_nonce:    new_nonce.clone()
			dc:           dc
			expires_in:   config.expires_in
		}.encode() or { panic(err) }
	}
	return tl.PQInnerDataDc{
		pq:           factors.pq.bytestr()
		p:            factors.p.bytestr()
		q:            factors.q.bytestr()
		nonce:        res_pq.nonce.clone()
		server_nonce: res_pq.server_nonce.clone()
		new_nonce:    new_nonce.clone()
		dc:           dc
	}.encode() or { panic(err) }
}

fn normalize_dc_id(config ExchangeConfig) int {
	mut dc := config.dc_id
	if config.test_mode {
		dc += 10_000
	}
	if config.is_media {
		dc = -dc
	}
	return dc
}

fn validate_nonce_pair(state HandshakeState, expected_nonce []u8, actual_nonce []u8, expected_server_nonce []u8, actual_server_nonce []u8) ! {
	if actual_nonce != expected_nonce {
		return error('nonce mismatch while in ${state}')
	}
	if expected_server_nonce.len > 0 && actual_server_nonce != expected_server_nonce {
		return error('server nonce mismatch while in ${state}')
	}
}

fn decode_hashed_tl_object(payload []u8, backend crypto.Backend) !tl.Object {
	if payload.len < 20 {
		return error('hashed TL payload is too short')
	}
	hash_prefix := payload[..20]
	object, consumed := tl.decode_object_prefix(payload[20..])!
	object_payload := payload[20..20 + consumed].clone()
	expected_hash := backend.sha1(object_payload)!
	if hash_prefix != expected_hash {
		return error('SHA1 hash mismatch for hashed TL payload')
	}
	return object
}

fn pad_random(data []u8, block_size int, backend crypto.Backend) ![]u8 {
	if block_size <= 0 {
		return error('block size must be positive')
	}
	remainder := data.len % block_size
	if remainder == 0 {
		return data.clone()
	}
	mut out := data.clone()
	out << backend.random_bytes(block_size - remainder)!
	return out
}

fn random_session_id(backend crypto.Backend) !i64 {
	return bytes_to_i64_le(backend.random_bytes(8)!)
}

fn bytes_to_i64_le(data []u8) !i64 {
	if data.len != 8 {
		return error('expected exactly 8 bytes for session id conversion')
	}
	mut value := u64(0)
	for index, byte in data {
		value |= u64(byte) << (8 * index)
	}
	return i64(value)
}

fn dh_gen_hash_parts(response tl.Object) !(u8, []u8) {
	match response {
		tl.DhGenOk {
			return u8(1), response.new_nonce_hash1.clone()
		}
		tl.DhGenRetry {
			return u8(2), response.new_nonce_hash2.clone()
		}
		tl.DhGenFail {
			return u8(3), response.new_nonce_hash3.clone()
		}
		else {
			return error('unexpected DH generation response ${response.qualified_name()}')
		}
	}
}

fn validate_dh_gen_response(expected_nonce []u8, expected_server_nonce []u8, expected_hash []u8, actual_hash []u8, response tl.Object) ! {
	match response {
		tl.DhGenOk {
			if response.nonce != expected_nonce {
				return error('dh_gen_ok nonce mismatch')
			}
			if response.server_nonce != expected_server_nonce {
				return error('dh_gen_ok server nonce mismatch')
			}
		}
		tl.DhGenRetry {
			if response.nonce != expected_nonce {
				return error('dh_gen_retry nonce mismatch')
			}
			if response.server_nonce != expected_server_nonce {
				return error('dh_gen_retry server nonce mismatch')
			}
		}
		tl.DhGenFail {
			if response.nonce != expected_nonce {
				return error('dh_gen_fail nonce mismatch')
			}
			if response.server_nonce != expected_server_nonce {
				return error('dh_gen_fail server nonce mismatch')
			}
		}
		else {
			return error('unexpected DH generation response ${response.qualified_name()}')
		}
	}
	if actual_hash != expected_hash {
		return error('new nonce hash mismatch')
	}
}
