# Quick Start

This guide gets a VTOL client from zero to a reusable session, a sent message, and a clean disconnect.

If you want the runnable version first, see:

- `examples/auth_basic`
- `examples/send_message`

## What You Need

- a Telegram API ID
- a Telegram API hash
- a local checkout of VTOL available as `vtol` in your V module path

If this checkout is not already resolvable as a V module:

```bash
mkdir -p ~/.vmodules
ln -sfn "$PWD" ~/.vmodules/vtol
```

Export your Telegram credentials before running examples:

```bash
export VTOL_API_ID=12345
export VTOL_API_HASH=your-app-hash
```

## End-To-End Example

This example uses a SQLite-backed session file. The first run performs login. Later runs reuse the saved session automatically.

```v
module main

import os
import vtol

fn main() {
	run() or {
		eprintln('quick-start: ${err}')
		exit(1)
	}
}

fn run() ! {
	mut client := vtol.new_client_with_session_file(vtol.ClientConfig{
		app_id:   os.getenv('VTOL_API_ID').int()
		app_hash: os.getenv('VTOL_API_HASH')
		dc_options: [
			vtol.DcOption{
				id:   2
				host: '149.154.167.50'
				port: 443
			},
		]
	}, '.vtol.session.sqlite')!
	defer {
		client.disconnect() or {}
	}

	me := client.start(vtol.StartOptions{
		phone_number: fn () !string {
			return os.input('Phone number: ').trim_space()
		}
		code: fn (request vtol.LoginCodeRequest) !string {
			println('Received ${request.sent_code.qualified_name()}')
			return os.input('Login code: ').trim_space()
		}
		password: fn () !string {
			return os.input('2FA password (leave empty if not enabled): ').trim_space()
		}
	})!

	if client.did_restore_session() {
		println('Restored a saved session')
	} else {
		println('Logged in and saved a new session')
	}

	sent := client.send_text('me', vtol.parse_markdown('*hello* from `VTOL`') or {
		vtol.plain_text('hello from VTOL')
	})!

	println('Current account payload: ${me.qualified_name()}')
	println('Sent message ${sent.id} to ${sent.peer.key}: ${sent.text}')
}
```

## What Happens On Each Run

### First run

`client.start(...)` connects, asks for login details, completes authorization, and saves the session data to `.vtol.session.sqlite`.

### Later runs

`client.start(...)` notices that the session store already contains authorization state, restores it, and returns `get_me()` without asking for a login code again.

You can confirm that path with `client.did_restore_session()`.

## Why `start()` Is The Default Entry Point

For most applications, `start()` is the right first call because it handles:

- initial connection
- user login with a code
- optional 2FA password
- bot login when you provide `bot_token`
- session reuse on later runs

If you need to control auth steps manually, VTOL also exposes `send_login_code()`, `sign_in_code()`, `sign_in_password()`, and `login_bot()`. Those lower-level flows are covered in `docs/auth-and-sessions.md`.

## Where To Go Next

- Read `docs/auth-and-sessions.md` if you want to choose a different session backend.
- Read `docs/peers.md` if you want to message usernames, cached peers, or explicit input peers.
- Read `docs/messages.md` for send options, media sends, and history helpers.
- Read `docs/updates.md` when you want a long-lived client with message handlers.
