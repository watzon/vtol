module vtol

import crypto
import math.big
import rpc
import tl

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
		c.persist_session()!
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
	c.persist_session()!
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
	c.persist_session()!
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
	c.persist_session()!
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
