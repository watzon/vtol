module crypto

import encoding.hex
import math.big
import tl

// auth_key_size is the MTProto auth key size in bytes.
pub const auth_key_size = 256
// msg_key_size is the MTProto message key size in bytes.
pub const msg_key_size = 16
// nonce_size is the standard MTProto nonce size in bytes.
pub const nonce_size = 16
// new_nonce_size is the MTProto new_nonce size in bytes.
pub const new_nonce_size = 32
// aes_block_size is the AES block size used by MTProto.
pub const aes_block_size = 16
// tmp_aes_key_size is the temporary AES key size used during auth.
pub const tmp_aes_key_size = 32
// tmp_aes_iv_size is the temporary AES IV size used during auth.
pub const tmp_aes_iv_size = 32
// rsa_payload_size is the RSA payload size used by Telegram auth keys.
pub const rsa_payload_size = 256
// rsa_inner_data_size is the maximum inner auth payload size before RSA padding.
pub const rsa_inner_data_size = 192

// telegram_safe_dh_prime_hex is Telegram's published safe prime for DH key exchange.
pub const telegram_safe_dh_prime_hex = 'C71CAEB9C6B1C9048E6C522F70F13F73980D40238E3E21C14934D037563D930F48198A0AA7C14058229493D22530F4DBFA336F6E0AC925139543AED44CCE7C3720FD51F69458705AC68CD4FE6B6B13ABDC9746512969328454F18FAF8C595F642477FE96BB2A941D5BCD1D4AC8CC49880708FA9B378E3C4F3A9060BEE67CF9A4A4A695811051907E162753B56B0F6B410DBA74D8A84B2A14B3144E0EF1284754FD17ED950D5965B4B9DD46582DB1178D169C6BC465B0D6FF9CA3928FEF5B9AE4E418FC15E83EBEA0F87FA9FF5EED70050DED2849F47BF959D956850CE929851F0D8115F635B105EE2E4E15D04B2454BF6F4FADF034B10403119CD8E3B92FCC5B'

// Capability reports whether the active backend supports a named feature.
pub struct Capability {
pub:
	name      string
	available bool
}

// PublicKey stores a Telegram RSA public key.
pub struct PublicKey {
pub:
	fingerprint i64
	modulus     []u8
	exponent    []u8
}

// AesKeyIv stores a paired AES key and IV.
pub struct AesKeyIv {
pub:
	key []u8
	iv  []u8
}

// KeyMaterial stores the auth key and msg key used for encrypted messages.
pub struct KeyMaterial {
pub:
	auth_key []u8
	msg_key  []u8
}

// PQFactors stores a factored pq value returned by Telegram during auth.
pub struct PQFactors {
pub:
	pq []u8
	p  []u8
	q  []u8
}

// Backend abstracts the crypto primitives VTOL needs.
pub interface Backend {
	name() string
	capabilities() []Capability
	random_bytes(length int) ![]u8
	sha1(data []u8) ![]u8
	sha256(data []u8) ![]u8
	aes_ige_encrypt(data []u8, key []u8, iv []u8) ![]u8
	aes_ige_decrypt(data []u8, key []u8, iv []u8) ![]u8
}

struct OpenSSLBackend {}

const telegram_public_key_specs = [
	PublicKeySpec{
		fingerprint:  i64(-4344800451088585951)
		modulus_hex:  'C150023E2F70DB7985DED064759CFECF0AF328E69A41DAF4D6F01B538135A6F91F8F8B2A0EC9BA9720CE352EFCF6C5680FFC424BD634864902DE0B4BD6D49F4E580230E3AE97D95C8B19442B3C0A10D8F5633FECEDD6926A7F6DAB0DDB7D457F9EA81B8465FCD6FFFEED114011DF91C059CAEDAF97625F6C96ECC74725556934EF781D866B34F011FCE4D835A090196E9A5F0E4449AF7EB697DDB9076494CA5F81104A305B6DD27665722C46B60E5DF680FB16B210607EF217652E60236C255F6A28315F4083A96791D7214BF64C1DF4FD0DB1944FB26A2A57031B32EEE64AD15A8BA68885CDE74A5BFC920F6ABF59BA5C75506373E7130F9042DA922179251F'
		exponent_hex: '010001'
	},
	PublicKeySpec{
		fingerprint:  i64(847625836280919973)
		modulus_hex:  'AEEC36C8FFC109CB099624685B97815415657BD76D8C9C3E398103D7AD16C9BBA6F525ED0412D7AE2C2DE2B44E77D72CBF4B7438709A4E646A05C43427C7F184DEBF72947519680E651500890C6832796DD11F772C25FF8F576755AFE055B0A3752C696EB7D8DA0D8BE1FAF38C9BDD97CE0A77D3916230C4032167100EDD0F9E7A3A9B602D04367B689536AF0D64B613CCBA7962939D3B57682BEB6DAE5B608130B2E52ACA78BA023CF6CE806B1DC49C72CF928A7199D22E3D7AC84E47BC9427D0236945D10DBD15177BAB413FBF0EDFDA09F014C7A7DA088DDE9759702CA760AF2B8E4E97CC055C617BD74C3D97008635B98DC4D621B4891DA9FB0473047927'
		exponent_hex: '010001'
	},
	PublicKeySpec{
		fingerprint:  i64(1562291298945373506)
		modulus_hex:  'BDF2C77D81F6AFD47BD30F29AC76E55ADFE70E487E5E48297E5A9055C9C07D2B93B4ED3994D3ECA5098BF18D978D54F8B7C713EB10247607E69AF9EF44F38E28F8B439F257A11572945CC0406FE3F37BB92B79112DB69EEDF2DC71584A661638EA5BECB9E23585074B80D57D9F5710DD30D2DA940E0ADA2F1B878397DC1A72B5CE2531B6F7DD158E09C828D03450CA0FF8A174DEACEBCAA22DDE84EF66AD370F259D18AF806638012DA0CA4A70BAA83D9C158F3552BC9158E69BF332A45809E1C36905A5CAA12348DD57941A482131BE7B2355A5F4635374F3BD3DDF5FF925BF4809EE27C1E67D9120C5FE08A9DE458B1B4A3C5D0A428437F2BECA81F4E2D5FF'
		exponent_hex: '010001'
	},
	PublicKeySpec{
		fingerprint:  i64(-5859577972006586033)
		modulus_hex:  'B3F762B739BE98F343EB1921CF0148CFA27FF7AF02B6471213FED9DAA0098976E667750324F1ABCEA4C31E43B7D11F1579133F2B3D9FE27474E462058884E5E1B123BE9CBBC6A443B2925C08520E7325E6F1A6D50E117EB61EA49D2534C8BB4D2AE4153FABE832B9EDF4C5755FDD8B19940B81D1D96CF433D19E6A22968A85DC80F0312F596BD2530C1CFB28B5FE019AC9BC25CD9C2A5D8A0F3A1C0C79BCCA524D315B5E21B5C26B46BABE3D75D06D1CD33329EC782A0F22891ED1DB42A1D6C0DEA431428BC4D7AABDCF3E0EB6FDA4E23EB7733E7727E9A1915580796C55188D2596D2665AD1182BA7ABF15AAA5A8B779EA996317A20AE044B820BFF35B6E8A1'
		exponent_hex: '010001'
	},
	PublicKeySpec{
		fingerprint:  i64(6491968696586960280)
		modulus_hex:  'BE6A71558EE577FF03023CFA17AAB4E6C86383CFF8A7AD38EDB9FAFE6F323F2D5106CBC8CAFB83B869CFFD1CCF121CD743D509E589E68765C96601E813DC5B9DFC4BE415C7A6526132D0035CA33D6D6075D4F535122A1CDFE017041F1088D1419F65C8E5490EE613E16DBF662698C0F54870F0475FA893FC41EB55B08FF1AC211BC045DED31BE27D12C96D8D3CFC6A7AE8AA50BF2EE0F30ED507CC2581E3DEC56DE94F5DC0A7ABEE0BE990B893F2887BD2C6310A1E0A9E3E38BD34FDED2541508DC102A9C9B4C95EFFD9DD2DFE96C29BE647D6C69D66CA500843CFAED6E440196F1DBE0E2E22163C61CA48C79116FA77216726749A976A1C4B0944B5121E8C01'
		exponent_hex: '010001'
	},
]

struct PublicKeySpec {
	fingerprint  i64
	modulus_hex  string
	exponent_hex string
}

// default_backend returns VTOL's default crypto backend.
pub fn default_backend() Backend {
	return OpenSSLBackend{}
}

// available_capabilities returns the capabilities reported by the default backend.
pub fn available_capabilities() []Capability {
	return default_backend().capabilities()
}

// default_public_keys returns the bundled Telegram production public keys.
pub fn default_public_keys() []PublicKey {
	mut keys := []PublicKey{cap: telegram_public_key_specs.len}
	for spec in telegram_public_key_specs {
		keys << PublicKey{
			fingerprint: spec.fingerprint
			modulus:     decode_hex_bytes(spec.modulus_hex) or { panic(err) }
			exponent:    decode_hex_bytes(spec.exponent_hex) or { panic(err) }
		}
	}
	return keys
}

// select_public_key selects the first supported public key from Telegram fingerprints.
pub fn select_public_key(keys []PublicKey, fingerprints []i64) !PublicKey {
	for fingerprint in fingerprints {
		for key in keys {
			if key.fingerprint == fingerprint {
				return key
			}
		}
	}
	return error('no supported public key fingerprint found')
}

// compute_public_key_fingerprint calculates Telegram's fingerprint for a public key.
pub fn compute_public_key_fingerprint(backend Backend, key PublicKey) !i64 {
	encoded := encode_public_key(key)
	digest := backend.sha1(encoded)!
	if digest.len != 20 {
		return error('sha1 digest must be 20 bytes')
	}
	return bytes_to_i64_le(digest[digest.len - 8..])
}

// encode_public_key serializes a public key using Telegram's expected layout.
pub fn encode_public_key(key PublicKey) []u8 {
	mut out := []u8{}
	tl.append_bytes(mut out, trim_leading_zero_bytes(key.modulus))
	tl.append_bytes(mut out, trim_leading_zero_bytes(key.exponent))
	return out
}

// rsa_pad_v2 applies MTProto 2.0 RSA padding before encryption.
pub fn rsa_pad_v2(data []u8, key PublicKey, backend Backend) ![]u8 {
	if data.len > 144 {
		return error('rsa inner data must not exceed 144 bytes')
	}
	mut data_with_padding := data.clone()
	if data_with_padding.len < rsa_inner_data_size {
		data_with_padding << backend.random_bytes(rsa_inner_data_size - data_with_padding.len)!
	}
	data_pad_reversed := reverse_bytes(data_with_padding)
	modulus_int := big.integer_from_bytes(trim_leading_zero_bytes(key.modulus))
	zero_iv := []u8{len: tmp_aes_iv_size}
	for attempt in 0 .. 8 {
		temp_key := backend.random_bytes(tmp_aes_key_size)!
		mut temp_and_data := temp_key.clone()
		temp_and_data << data_with_padding
		hash_tail := backend.sha256(temp_and_data)!
		mut data_with_hash := data_pad_reversed.clone()
		data_with_hash << hash_tail
		aes_encrypted := backend.aes_ige_encrypt(data_with_hash, temp_key, zero_iv)!
		temp_key_xor := xor_bytes(temp_key, backend.sha256(aes_encrypted)!)!
		mut payload := temp_key_xor.clone()
		payload << aes_encrypted
		if payload.len != rsa_payload_size {
			return error('rsa padded payload must be 256 bytes')
		}
		payload_int := big.integer_from_bytes(payload)
		if payload_int < modulus_int {
			return rsa_raw_encrypt(payload, key)!
		}
		if attempt == 7 {
			break
		}
	}
	return error('could not generate RSA-padded payload below modulus')
}

// rsa_pad_legacy applies Telegram's legacy RSA padding before encryption.
pub fn rsa_pad_legacy(data []u8, key PublicKey, backend Backend) ![]u8 {
	sha := backend.sha1(data)!
	mut payload := sha.clone()
	payload << data.clone()
	if payload.len > rsa_payload_size - 1 {
		return error('legacy RSA payload is too large')
	}
	payload << backend.random_bytes((rsa_payload_size - 1) - payload.len)!
	return rsa_raw_encrypt(left_pad(payload, rsa_payload_size)!, key)!
}

// rsa_raw_encrypt encrypts a fixed-size payload with a Telegram RSA key.
pub fn rsa_raw_encrypt(data []u8, key PublicKey) ![]u8 {
	if data.len != rsa_payload_size {
		return error('rsa raw input must be exactly 256 bytes')
	}
	modulus := big.integer_from_bytes(trim_leading_zero_bytes(key.modulus))
	exponent := big.integer_from_bytes(trim_leading_zero_bytes(key.exponent))
	value := big.integer_from_bytes(data)
	if value >= modulus {
		return error('rsa input must be smaller than modulus')
	}
	encrypted := value.big_mod_pow(exponent, modulus)!
	encrypted_bytes, sign := encrypted.bytes()
	if sign < 0 {
		return error('rsa output must not be negative')
	}
	return left_pad(encrypted_bytes, rsa_payload_size)
}

// factorize_pq factors Telegram's pq challenge into p and q.
pub fn factorize_pq(pq []u8) !PQFactors {
	value := bytes_to_u64_be(pq)!
	if value < 2 {
		return error('pq must be at least 2')
	}
	factor := pollard_rho_brent(value)!
	mut p := factor
	mut q := value / factor
	if p > q {
		p, q = q, p
	}
	return PQFactors{
		pq: trim_leading_zero_bytes(pq)
		p:  u64_to_be_bytes(p)
		q:  u64_to_be_bytes(q)
	}
}

// derive_tmp_aes_key_iv derives the temporary AES key and IV used during auth.
pub fn derive_tmp_aes_key_iv(backend Backend, new_nonce []u8, server_nonce []u8) !AesKeyIv {
	if new_nonce.len != new_nonce_size {
		return error('new nonce must be 32 bytes')
	}
	if server_nonce.len != nonce_size {
		return error('server nonce must be 16 bytes')
	}
	mut first := new_nonce.clone()
	first << server_nonce
	mut second := server_nonce.clone()
	second << new_nonce
	mut third := new_nonce.clone()
	third << new_nonce
	sha_a := backend.sha1(first)!
	sha_b := backend.sha1(second)!
	sha_c := backend.sha1(third)!
	mut key := sha_a.clone()
	key << sha_b[..12]
	mut iv := sha_b[12..].clone()
	iv << sha_c
	iv << new_nonce[..4]
	return AesKeyIv{
		key: key
		iv:  iv
	}
}

// derive_message_aes_key_iv derives the AES key and IV for encrypted messages.
pub fn derive_message_aes_key_iv(backend Backend, auth_key []u8, msg_key []u8, outgoing bool) !AesKeyIv {
	if auth_key.len != auth_key_size {
		return error('auth key must be 256 bytes')
	}
	if msg_key.len != msg_key_size {
		return error('msg key must be 16 bytes')
	}
	x := if outgoing { 0 } else { 8 }
	mut sha_a_input := msg_key.clone()
	sha_a_input << auth_key[x..x + 36]
	mut sha_b_input := auth_key[40 + x..40 + x + 36].clone()
	sha_b_input << msg_key
	sha_a := backend.sha256(sha_a_input)!
	sha_b := backend.sha256(sha_b_input)!
	mut key := sha_a[..8].clone()
	key << sha_b[8..24]
	key << sha_a[24..32]
	mut iv := sha_b[..8].clone()
	iv << sha_a[8..24]
	iv << sha_b[24..32]
	return AesKeyIv{
		key: key
		iv:  iv
	}
}

// derive_auth_key_id derives the Telegram auth_key_id from an auth key.
pub fn derive_auth_key_id(backend Backend, auth_key []u8) !i64 {
	if auth_key.len != auth_key_size {
		return error('auth key must be 256 bytes')
	}
	digest := backend.sha1(auth_key)!
	return bytes_to_i64_le(digest[digest.len - 8..])
}

// derive_auth_key_aux_hash derives the auxiliary hash used in auth flows.
pub fn derive_auth_key_aux_hash(backend Backend, auth_key []u8) ![]u8 {
	if auth_key.len != auth_key_size {
		return error('auth key must be 256 bytes')
	}
	digest := backend.sha1(auth_key)!
	return digest[..8].clone()
}

// derive_new_nonce_hash derives the server verification hash for DH completion.
pub fn derive_new_nonce_hash(backend Backend, new_nonce []u8, auth_key []u8, number u8) ![]u8 {
	if new_nonce.len != new_nonce_size {
		return error('new nonce must be 32 bytes')
	}
	auth_key_aux_hash := derive_auth_key_aux_hash(backend, auth_key)!
	mut input := new_nonce.clone()
	input << number
	input << auth_key_aux_hash
	digest := backend.sha1(input)!
	return digest[4..20].clone()
}

// derive_server_salt_bytes derives the raw server salt bytes from the exchanged nonces.
pub fn derive_server_salt_bytes(new_nonce []u8, server_nonce []u8) ![]u8 {
	if new_nonce.len != new_nonce_size {
		return error('new nonce must be 32 bytes')
	}
	if server_nonce.len != nonce_size {
		return error('server nonce must be 16 bytes')
	}
	return xor_bytes(new_nonce[..8], server_nonce[..8])!
}

// derive_server_salt derives the server salt integer from the exchanged nonces.
pub fn derive_server_salt(new_nonce []u8, server_nonce []u8) !i64 {
	return bytes_to_i64_le(derive_server_salt_bytes(new_nonce, server_nonce)!)
}

// validate_dh_group validates the DH parameters returned during auth.
pub fn validate_dh_group(g int, dh_prime []u8, g_a []u8, g_b []u8) ! {
	expected_prime := telegram_safe_dh_prime_bytes()
	if trim_leading_zero_bytes(dh_prime) != expected_prime {
		return error('unexpected DH prime')
	}
	if g < 2 || g > 7 {
		return error('unexpected DH generator')
	}
	prime_int := big.integer_from_bytes(expected_prime)
	one := big.one_int
	safety_range := one.left_shift(2048 - 64)
	upper_bound := prime_int - safety_range
	validate_dh_value(g_a, 'g_a', one, prime_int, safety_range, upper_bound)!
	validate_dh_value(g_b, 'g_b', one, prime_int, safety_range, upper_bound)!
}

// telegram_safe_dh_prime_bytes returns Telegram's safe DH prime as bytes.
pub fn telegram_safe_dh_prime_bytes() []u8 {
	return decode_hex_bytes(telegram_safe_dh_prime_hex) or { panic(err) }
}

// telegram_safe_dh_prime returns Telegram's safe DH prime as a big integer.
pub fn telegram_safe_dh_prime() big.Integer {
	return big.integer_from_bytes(telegram_safe_dh_prime_bytes())
}

// reverse_bytes returns a reversed copy of data.
pub fn reverse_bytes(data []u8) []u8 {
	mut reversed := data.clone()
	reversed.reverse_in_place()
	return reversed
}

// xor_bytes returns the byte-wise XOR of equally sized slices.
pub fn xor_bytes(a []u8, b []u8) ![]u8 {
	if a.len != b.len {
		return error('xor inputs must have equal length')
	}
	mut out := []u8{len: a.len}
	for index in 0 .. a.len {
		out[index] = a[index] ^ b[index]
	}
	return out
}

// left_pad pads data with leading zero bytes up to target_len.
pub fn left_pad(data []u8, target_len int) ![]u8 {
	if data.len > target_len {
		return error('cannot left-pad data longer than target length')
	}
	mut out := []u8{len: target_len}
	offset := target_len - data.len
	for index, value in data {
		out[offset + index] = value
	}
	return out
}

// trim_leading_zero_bytes removes leading zero bytes from data.
pub fn trim_leading_zero_bytes(data []u8) []u8 {
	for index, value in data {
		if value != 0 {
			return data[index..].clone()
		}
	}
	return []u8{}
}

fn decode_hex_bytes(value string) ![]u8 {
	return hex.decode(value)!
}

fn bytes_to_u64_be(data []u8) !u64 {
	if data.len == 0 || data.len > 8 {
		return error('expected 1 to 8 bytes for u64 conversion')
	}
	mut value := u64(0)
	for byte in data {
		value = (value << 8) | u64(byte)
	}
	return value
}

fn bytes_to_i64_le(data []u8) !i64 {
	if data.len != 8 {
		return error('expected exactly 8 bytes for i64 conversion')
	}
	mut value := u64(0)
	for index, byte in data {
		value |= u64(byte) << (8 * index)
	}
	return i64(value)
}

fn u64_to_be_bytes(value u64) []u8 {
	mut out := []u8{len: 8}
	for index in 0 .. 8 {
		shift := (7 - index) * 8
		out[index] = u8((value >> shift) & 0xff)
	}
	return trim_leading_zero_bytes(out)
}

fn pollard_rho_brent(value u64) !u64 {
	if value % 2 == 0 {
		return 2
	}
	for seed in 1 .. 32 {
		mut y := u64((seed * 2 + 1) % int(value - 1)) + 1
		mut c := u64((seed * 3 + 1) % int(value - 1)) + 1
		mut m := u64((seed * 5 + 1) % int(value - 1)) + 1
		mut g := u64(1)
		mut r := u64(1)
		mut q := u64(1)
		mut x := u64(0)
		mut ys := u64(0)
		for g == 1 {
			x = y
			for _ in u64(0) .. r {
				y = (mod_mul(y, y, value) + c) % value
			}
			mut k := u64(0)
			for k < r && g == 1 {
				ys = y
				limit := min_u64(m, r - k)
				for _ in u64(0) .. limit {
					y = (mod_mul(y, y, value) + c) % value
					diff := if x > y { x - y } else { y - x }
					q = mod_mul(q, diff, value)
				}
				g = gcd_u64(q, value)
				k += m
			}
			r <<= 1
		}
		if g == value {
			for g == 1 {
				ys = (mod_mul(ys, ys, value) + c) % value
				diff := if x > ys { x - ys } else { ys - x }
				g = gcd_u64(diff, value)
			}
		}
		if g > 1 && g < value {
			return g
		}
	}
	return error('could not factor pq')
}

fn gcd_u64(a u64, b u64) u64 {
	mut left := a
	mut right := b
	for right != 0 {
		left, right = right, left % right
	}
	return left
}

fn mod_mul(a u64, b u64, modulus u64) u64 {
	mut left := a % modulus
	mut right := b
	mut result := u64(0)
	for right > 0 {
		if right & 1 == 1 {
			result = (result + left) % modulus
		}
		if left >= modulus - left {
			left = left - (modulus - left)
		} else {
			left += left
		}
		right >>= 1
	}
	return result
}

fn min_u64(a u64, b u64) u64 {
	return if a < b { a } else { b }
}

fn validate_dh_value(value []u8, label string, one big.Integer, prime big.Integer, safety_range big.Integer, upper_bound big.Integer) ! {
	value_int := big.integer_from_bytes(trim_leading_zero_bytes(value))
	if !(value_int > one && value_int < prime - one) {
		return error('${label} is outside the DH group bounds')
	}
	if !(value_int >= safety_range && value_int <= upper_bound) {
		return error('${label} is outside the DH safety range')
	}
}
