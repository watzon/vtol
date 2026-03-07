# Auth And Sessions

VTOL separates authorization from session storage, but the normal user path keeps them tied together:

- use `Client.start()` to log in or restore
- back that client with a session store
- let VTOL persist auth state and cached peer information for later runs

## Auth Entry Points

### `start()`

`Client.start(StartOptions)` is the default entry point for user-facing apps.

It will:

- connect the client
- restore an existing authorized session when one is present
- otherwise request a login code and continue the sign-in flow
- fall back to password auth when Telegram requires 2FA
- log in as a bot if you provide `bot_token`

Use it when you want the common path to stay simple.

### Manual auth methods

VTOL also exposes the lower-level pieces:

- `send_login_code(phone_number)`
- `send_login_code_with_settings(phone_number, settings)`
- `sign_in_code(request, code)`
- `sign_in_password(password)`
- `complete_login(request, code, password)`
- `login_bot(bot_token)`
- `log_out()`
- `get_me()`

Use these when you need to own the login state machine yourself.

## Session Backends

VTOL ships with three built-in session backends under `vtol.session`. Most applications use them through VTOL's convenience constructors instead of instantiating the store directly.

### `MemorySession`

Use `MemorySession` when you only need a session for the current process.

Characteristics:

- nothing is written to disk
- restarting the process means logging in again
- useful for short-lived tools and tests

```v
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
})!
```

`vtol.new_client(...)` uses an in-memory store internally.

### `SQLiteSession`

Use `SQLiteSession` when you want the usual desktop or server behavior: restart the program and keep the same authorization.

Characteristics:

- persisted on disk
- easiest default for applications and scripts
- stores both session state and VTOL's cached peer records

```v
mut client := vtol.new_client_with_session_file(config, '.vtol.session.sqlite')!
```

`new_client_with_session_file()` and `new_client_with_sqlite_session()` are equivalent convenience constructors.

### `StringSession`

Use `StringSession` when you want to keep the session as a serialized string instead of a file.

Characteristics:

- good for secrets managers, CI, or external storage
- lets you inject an existing session into a client directly
- can also be used as a store if you want to read back the encoded value

Consume an existing string session like this:

```v
mut client := vtol.new_client_with_string_session(config, existing_session)!
```

If you need to export the encoded value after login, work with the store directly:

```v
import vtol
import vtol.session

mut store := session.new_string_session('')!
mut client := vtol.new_client_with_store(config, store)!

client.start(vtol.StartOptions{
	phone_number: prompt_phone
	code:         prompt_code
	password:     prompt_password
})!

println(store.encoded())
```

## Restore Semantics

The important part of VTOL's restore behavior is that the session store is consulted before auth prompts happen.

What that means in practice:

- `Client.start()` restores first and only asks for credentials when the store is empty or unauthorized.
- `Client.connect()`, `Client.invoke()`, and other client calls build the runtime from the session store under the hood.
- `Client.did_restore_session()` becomes meaningful after the runtime has been built, which happens during `connect()`, `start()`, `invoke()`, or any higher-level helper that invokes RPC.

`did_restore_session()` tells you whether the current client instance started from saved authorization state, not whether the session was merely written during this process.

## Session Safety

Treat VTOL sessions like account credentials.

Recommended rules:

- do not commit session files or string sessions to version control
- do not log encoded string sessions
- put SQLite session files in a private directory
- rotate sessions if you suspect the file or string leaked
- use separate sessions for separate environments when possible

## Cached Peers Live In The Session Too

VTOL stores resolved peer metadata alongside the authorization state. That is why username lookups can become reusable cached keys such as `user:42` or `channel:123` across runs.

This matters for the peer-like API:

- usernames can be resolved remotely
- `user:...`, `chat:...`, and `channel:...` keys only work after VTOL has cached those peers

The full peer story is documented in `docs/peers.md`.

## Which Backend To Pick

- pick `SQLiteSession` for most local apps, bots, and scripts
- pick `StringSession` when another system should own the persisted secret
- pick `MemorySession` when persistence would be a liability or you only need a temporary client
