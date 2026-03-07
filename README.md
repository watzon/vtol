# VTOL

VTOL is an MTProto library for V. The public docs are organized around the common path first: create a client, restore or log in, send messages, receive updates, and only then drop down to raw TL when you need a surface VTOL does not wrap yet.

## Status

VTOL is still pre-`1.0`, but the high-value client surface is already in place:

- `Client.start()` for user or bot login
- session persistence via the built-in `vtol.session` backends: `MemorySession`, `StringSession`, and `SQLiteSession`
- peer-like inputs for high-level client methods
- message-oriented send helpers that return `SentMessage`
- long-lived update handling with `on_new_message()` and recovery-aware pump loops
- raw TL access through `Client.invoke()`

## Install

The examples assume this checkout is available as `vtol` in your V module path:

```bash
v install watzon.vtol
```

Or for local development:

```bash
mkdir -p ~/.vmodules
ln -sfn "$PWD" ~/.vmodules/vtol
```

You also need a Telegram API ID and hash from https://my.telegram.org.

## First Steps

The shortest path to a working VTOL program is:

1. Create a client with a persistent session store.
2. Call `start()` so the first run logs in and later runs restore automatically.
3. Send a message through the high-level client surface.
4. Disconnect cleanly.

```v
module main

import os
import vtol

fn main() {
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
	}, '.vtol.session.sqlite') or {
		panic(err)
	}
	defer {
		client.disconnect() or {}
	}

	me := client.start(vtol.StartOptions{
		phone_number: fn () !string {
			return os.input('Phone number: ').trim_space()
		}
		code: fn (request vtol.LoginCodeRequest) !string {
			println('Telegram sent ${request.sent_code.qualified_name()}')
			return os.input('Login code: ').trim_space()
		}
		password: fn () !string {
			return os.input('2FA password (if enabled): ').trim_space()
		}
	}) or {
		panic(err)
	}

	println('Authorized account payload: ${me.qualified_name()}')

	sent := client.send_text('me', vtol.plain_text('hello from VTOL')) or {
		panic(err)
	}
	println('Sent message ${sent.id} to ${sent.peer.key}')
}
```

The next common step is a message handler:

```v
handler_id := client.on_new_message(fn (event vtol.NewMessageEvent) ! {
	println('[${event.kind}] ${event.chat.key}: ${event.text}')
})!
defer {
	client.remove_event_handler(handler_id)
}

client.idle()!
```

If you want Telethon-style filtering, VTOL also supports `on_new_message_with_config()` plus `on_new_message_pattern()` and `on_new_message_matcher()`.

For the full flow, start with `docs/quick-start.md` and then continue to `docs/updates.md`.

## Docs

- `docs/quick-start.md`: first working script, session restore, login, send, disconnect
- `docs/auth-and-sessions.md`: auth flows, session backends, restore semantics, and safety
- `docs/peers.md`: usernames, cached peers, `me` / `self`, and VTOL's peer-like inputs
- `docs/messages.md`: sending text and media, formatting helpers, and history helpers
- `docs/updates.md`: long-lived clients, new-message handlers, recovery, and pump loops
- `docs/raw-api.md`: using `Client.invoke()` when you need the raw Telegram API
- `docs/client-reference.md`: short `Client` quick reference

## Examples

- `examples/auth_basic`: login and session reuse
- `examples/send_message`: formatted send flow returning `SentMessage`
- `examples/watch_updates`: long-lived `on_new_message()` example
- `examples/download_file`: media download from recent history

Each example has a companion README under `examples/`.

## Development

VTOL still keeps transport, auth, session, RPC, TL generation, media, and updates as separate modules. Development commands:

```bash
v run scripts/fetch_schemas.vsh
v run scripts/gen_tl.vsh
v run scripts/check_tl_schema.vsh
v fmt -w .
v fmt -verify .
v test .
```
