module crypto

const sample_server_nonce = '801775A3EFBFD2701AA28AD727BE4646'
const sample_new_nonce = '264F835B0B7BDFF9C6ED6CF819FD6DF5DCD17E90D67ADD2C2C1E3775C7A6A0AC'
const sample_pq = '130B7475669FEB8B'

fn test_default_public_keys_report_stable_fingerprints() {
	backend := default_backend()
	keys := default_public_keys()
	assert keys.len >= 5
	for key in keys {
		assert compute_public_key_fingerprint(backend, key) or { panic(err) } == key.fingerprint
	}
}

fn test_factorize_pq_matches_official_sample() {
	factors := factorize_pq(decode_hex_bytes(sample_pq) or { panic(err) }) or { panic(err) }
	assert factors.p.hex() == '44095e05'
	assert factors.q.hex() == '47a8c84f'
}

fn test_derive_tmp_aes_material_matches_sample_vector() {
	backend := default_backend()
	new_nonce := decode_hex_bytes(sample_new_nonce) or { panic(err) }
	server_nonce := decode_hex_bytes(sample_server_nonce) or { panic(err) }
	tmp := derive_tmp_aes_key_iv(backend, new_nonce, server_nonce) or { panic(err) }
	assert tmp.key.hex() == 'e68ca5aba101ffca0adda66303a57affaa2712fb16a7b8dafc72c25e8a73a368'
	assert tmp.iv.hex() == '0a355d4431b9ddd91a51eff3f7d340d64f0390c53f91dc53c331d43c264f835b'
	salt := derive_server_salt_bytes(new_nonce, server_nonce) or { panic(err) }
	assert salt.hex() == 'a658f6f8e4c40d89'
}

fn test_derive_message_aes_material_matches_mtproto_2_vector() {
	backend := default_backend()
	auth_key := []u8{len: 256, init: u8(index)}
	msg_key := decode_hex_bytes('00112233445566778899AABBCCDDEEFF') or { panic(err) }
	outgoing := derive_message_aes_key_iv(backend, auth_key, msg_key, true) or { panic(err) }
	incoming := derive_message_aes_key_iv(backend, auth_key, msg_key, false) or { panic(err) }
	assert outgoing.key.hex() == '0ca62c584ac1fe575b48d4cc2025a9653c4a0a8bb8c5c5dda6f5061850da4c52'
	assert outgoing.iv.hex() == '5fd0614404c9476ea05a2233b14abc6fb453642788b625cc6ee78d4a1329808a'
	assert incoming.key.hex() == '45d8307decb2faf15ff224213b70481246403074e88c7ef17a3e76d4b045e43e'
	assert incoming.iv.hex() == '5a2e1da8cacc1b644f3c5b662d40bc85a2e63b1a4404d253aa8d7bac1ad4132c'
}

fn test_new_nonce_hash_matches_vector() {
	backend := default_backend()
	auth_key := []u8{len: 256, init: u8(index)}
	new_nonce := decode_hex_bytes(sample_new_nonce) or { panic(err) }
	expected_auth_key_id := bytes_to_i64_le(decode_hex_bytes('32d1586ea457dfc8') or { panic(err) }) or {
		panic(err)
	}
	aux_hash := derive_auth_key_aux_hash(backend, auth_key) or { panic(err) }
	hash_one := derive_new_nonce_hash(backend, new_nonce, auth_key, 1) or { panic(err) }
	hash_two := derive_new_nonce_hash(backend, new_nonce, auth_key, 2) or { panic(err) }
	hash_three := derive_new_nonce_hash(backend, new_nonce, auth_key, 3) or { panic(err) }
	assert derive_auth_key_id(backend, auth_key) or { panic(err) } == expected_auth_key_id
	assert aux_hash.hex() == '4916d6bdb7f78e68'
	assert hash_one.hex() == 'e1357adba8c150c5f0d8d0b82987a502'
	assert hash_two.hex() == '2948ca02741a6a7bdabd2950b1a53235'
	assert hash_three.hex() == 'a78f83e148c9ffc12cfd7fecb3528810'
}
