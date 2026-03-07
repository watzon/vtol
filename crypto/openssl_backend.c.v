module crypto

import crypto.aes as std_aes

#define OPENSSL_API_COMPAT 0x30000000L

#flag linux -I/usr/local/include/openssl
#flag linux -L/usr/local/lib64
#flag freebsd -I/usr/local/include
#flag freebsd -L/usr/local/lib

$if $pkgconfig('openssl') {
	#pkgconfig --cflags --libs openssl
} $else {
	#flag -lssl -lcrypto
	#flag linux -ldl -lpthread
	#flag darwin -I/usr/local/opt/openssl/include
	#flag darwin -L/usr/local/opt/openssl/lib
	#flag darwin -I/usr/local/opt/openssl@3/include
	#flag darwin -L/usr/local/opt/openssl@3/lib
	#flag darwin -I /opt/homebrew/opt/openssl/include
	#flag darwin -L /opt/homebrew/opt/openssl/lib
}

#include <openssl/evp.h>
#include <openssl/rand.h> # Please install OpenSSL development headers
#include <openssl/sha.h>

@[typedef]
struct C.EVP_MD {}

fn C.RAND_bytes(buf &u8, num int) int
fn C.SHA1(data &u8, len usize, out &u8) &u8
fn C.SHA256(data &u8, len usize, out &u8) &u8
fn C.EVP_sha512() &C.EVP_MD
fn C.PKCS5_PBKDF2_HMAC(pass voidptr, passlen int, salt &u8, saltlen int, iter int, digest &C.EVP_MD, keylen int, out &u8) int

const openssl_success = 1

pub fn (backend OpenSSLBackend) name() string {
	return 'openssl'
}

pub fn (backend OpenSSLBackend) capabilities() []Capability {
	return [
		Capability{
			name:      'rand_bytes'
			available: true
		},
		Capability{
			name:      'sha1'
			available: true
		},
		Capability{
			name:      'sha256'
			available: true
		},
		Capability{
			name:      'aes_256_ige'
			available: true
		},
	]
}

pub fn (backend OpenSSLBackend) random_bytes(length int) ![]u8 {
	if length < 0 {
		return error('random byte length must not be negative')
	}
	mut out := []u8{len: length}
	if length == 0 {
		return out
	}
	if C.RAND_bytes(out.data, length) != openssl_success {
		return error('openssl RAND_bytes failed')
	}
	return out
}

pub fn (backend OpenSSLBackend) sha1(data []u8) ![]u8 {
	mut out := []u8{len: 20}
	mut empty := []u8{len: 1}
	if data.len == 0 {
		if C.SHA1(empty.data, usize(0), out.data) == 0 {
			return error('openssl SHA1 failed')
		}
		return out
	}
	if C.SHA1(data.data, usize(data.len), out.data) == 0 {
		return error('openssl SHA1 failed')
	}
	return out
}

pub fn (backend OpenSSLBackend) sha256(data []u8) ![]u8 {
	mut out := []u8{len: 32}
	mut empty := []u8{len: 1}
	if data.len == 0 {
		if C.SHA256(empty.data, usize(0), out.data) == 0 {
			return error('openssl SHA256 failed')
		}
		return out
	}
	if C.SHA256(data.data, usize(data.len), out.data) == 0 {
		return error('openssl SHA256 failed')
	}
	return out
}

pub fn (backend OpenSSLBackend) aes_ige_encrypt(data []u8, key []u8, iv []u8) ![]u8 {
	return backend.aes_ige_crypt(data, key, iv, true)
}

pub fn (backend OpenSSLBackend) aes_ige_decrypt(data []u8, key []u8, iv []u8) ![]u8 {
	return backend.aes_ige_crypt(data, key, iv, false)
}

fn (backend OpenSSLBackend) aes_ige_crypt(data []u8, key []u8, iv []u8, encrypt bool) ![]u8 {
	if key.len != tmp_aes_key_size {
		return error('AES-IGE key must be 32 bytes')
	}
	if iv.len != tmp_aes_iv_size {
		return error('AES-IGE IV must be 32 bytes')
	}
	if data.len % aes_block_size != 0 {
		return error('AES-IGE payload length must be divisible by 16')
	}
	cipher := std_aes.new_cipher(key)
	mut iv_left := iv[..aes_block_size].clone()
	mut iv_right := iv[aes_block_size..].clone()
	mut out := []u8{len: data.len}
	if encrypt {
		for offset := 0; offset < data.len; offset += aes_block_size {
			block := data[offset..offset + aes_block_size].clone()
			mut xored := xor_bytes(block, iv_left)!
			mut encrypted := []u8{len: aes_block_size}
			cipher.encrypt(mut encrypted, xored)
			cipher_block := xor_bytes(encrypted, iv_right)!
			copy(mut out[offset..offset + aes_block_size], cipher_block)
			iv_left = cipher_block.clone()
			iv_right = block.clone()
		}
	} else {
		for offset := 0; offset < data.len; offset += aes_block_size {
			block := data[offset..offset + aes_block_size].clone()
			mut xored := xor_bytes(block, iv_right)!
			mut decrypted := []u8{len: aes_block_size}
			cipher.decrypt(mut decrypted, xored)
			plain_block := xor_bytes(decrypted, iv_left)!
			copy(mut out[offset..offset + aes_block_size], plain_block)
			iv_left = block.clone()
			iv_right = plain_block.clone()
		}
	}
	return out
}

pub fn pbkdf2_hmac_sha512(password []u8, salt []u8, iterations int, key_len int) ![]u8 {
	if iterations <= 0 {
		return error('PBKDF2 iterations must be greater than zero')
	}
	if key_len <= 0 {
		return error('PBKDF2 key length must be greater than zero')
	}
	mut out := []u8{len: key_len}
	mut empty_password := []u8{len: 1}
	mut empty_salt := []u8{len: 1}
	mut password_ptr := voidptr(empty_password.data)
	if password.len > 0 {
		password_ptr = voidptr(password.data)
	}
	mut salt_ptr := empty_salt.data
	if salt.len > 0 {
		salt_ptr = salt.data
	}
	if C.PKCS5_PBKDF2_HMAC(password_ptr, password.len, salt_ptr, salt.len, iterations,
		C.EVP_sha512(), key_len, out.data) != openssl_success {
		return error('openssl PKCS5_PBKDF2_HMAC failed')
	}
	return out
}
