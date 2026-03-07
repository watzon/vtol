module auth

import crypto
import encoding.hex
import tl

const sample_server_nonce = '801775A3EFBFD2701AA28AD727BE4646'
const sample_pq = '130B7475669FEB8B'

struct NonceMismatchSender {}

fn (mut s NonceMismatchSender) invoke(function tl.Function) !tl.Object {
	match function {
		tl.ReqPqMulti {
			key := crypto.default_public_keys()[0]
			return tl.ResPQ{
				nonce:                          []u8{len: 16, init: u8(0)}
				server_nonce:                   decode_hex(sample_server_nonce)
				pq:                             decode_hex(sample_pq).bytestr()
				server_public_key_fingerprints: [key.fingerprint]
			}
		}
		else {
			return error('unexpected function ${function.qualified_name()}')
		}
	}
}

struct DhFailHashMismatchSender {
mut:
	request_nonce []u8
}

fn (mut s DhFailHashMismatchSender) invoke(function tl.Function) !tl.Object {
	match function {
		tl.ReqPqMulti {
			s.request_nonce = function.nonce.clone()
			key := crypto.default_public_keys()[0]
			return tl.ResPQ{
				nonce:                          function.nonce.clone()
				server_nonce:                   decode_hex(sample_server_nonce)
				pq:                             decode_hex(sample_pq).bytestr()
				server_public_key_fingerprints: [key.fingerprint]
			}
		}
		tl.ReqDHParams {
			return tl.ServerDHParamsFail{
				nonce:          function.nonce.clone()
				server_nonce:   function.server_nonce.clone()
				new_nonce_hash: []u8{len: 16, init: u8(0)}
			}
		}
		else {
			return error('unexpected function ${function.qualified_name()}')
		}
	}
}

struct ReplayLikeSender {}

fn (mut s ReplayLikeSender) invoke(function tl.Function) !tl.Object {
	match function {
		tl.ReqPqMulti {
			key := crypto.default_public_keys()[0]
			return tl.ResPQ{
				nonce:                          function.nonce.clone()
				server_nonce:                   decode_hex(sample_server_nonce)
				pq:                             decode_hex(sample_pq).bytestr()
				server_public_key_fingerprints: [key.fingerprint]
			}
		}
		tl.ReqDHParams {
			mut wrong_server_nonce := function.server_nonce.clone()
			wrong_server_nonce[0] ^= 0xff
			return tl.ServerDHParamsOk{
				nonce:            function.nonce.clone()
				server_nonce:     wrong_server_nonce
				encrypted_answer: ''
			}
		}
		else {
			return error('unexpected function ${function.qualified_name()}')
		}
	}
}

fn exchange_config() ExchangeConfig {
	return ExchangeConfig{
		dc_id:       2
		public_keys: [crypto.default_public_keys()[0]]
	}
}

fn decode_hex(value string) []u8 {
	return hex.decode(value) or { panic(err) }
}

fn test_exchange_rejects_invalid_res_pq_nonce() {
	mut sender := NonceMismatchSender{}
	_ := exchange(mut sender, exchange_config()) or {
		assert err.msg().contains('nonce mismatch')
		return
	}
	assert false
}

fn test_exchange_rejects_invalid_server_dh_fail_hash() {
	mut sender := DhFailHashMismatchSender{}
	_ := exchange(mut sender, exchange_config()) or {
		assert err.msg().contains('new_nonce_hash mismatch')
		return
	}
	assert false
}

fn test_exchange_rejects_replay_like_server_nonce_mismatch() {
	mut sender := ReplayLikeSender{}
	_ := exchange(mut sender, exchange_config()) or {
		assert err.msg().contains('server nonce mismatch')
		return
	}
	assert false
}
