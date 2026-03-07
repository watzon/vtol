# auth_basic

The high-level client now supports the explicit `connect -> login -> disconnect` flow without hiding the underlying TL methods.

```v
import tl
import vtol

mut client := vtol.new_client(vtol.ClientConfig{
	app_id:   12345
	app_hash: 'your-app-hash'
	dc_options: [
		vtol.DcOption{
			id:   2
			host: '149.154.167.50'
			port: 443
		},
	]
}) or {
	panic(err)
}

client.connect() or { panic(err) }
defer {
	client.disconnect() or {}
}

request := client.send_login_code('+15551234567') or { panic(err) }
authorization := client.sign_in_code(request, '123456') or { panic(err) }

match authorization {
	tl.AuthAuthorization {
		println('signed in as ${authorization.user.qualified_name()}')
	}
	tl.AuthAuthorizationSignUpRequired {
		println('sign-up is required before the account can continue')
	}
	else {
		println('unexpected auth result: ${authorization.qualified_name()}')
	}
}
```

Bot login is also available through `client.login_bot(token)`.

If the account requires 2FA, the client can complete the SRP exchange directly:

```v
authorization := client.sign_in_password('correct horse battery staple') or { panic(err) }
println(authorization.qualified_name())
```

The low-level pieces are still available if you need them:

- `client.get_password_challenge()` fetches the SRP challenge.
- `client.check_password(input_srp)` submits a precomputed `tl.InputCheckPasswordSRPType`.
