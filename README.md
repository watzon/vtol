# vtol

MTProto library for the V programming language

VTOL is a V library for building Telegram clients on top of MTProto. It provides a high-level `vtol.Client` for login, session reuse, messaging, media transfer, peer resolution, and update handling, while still exposing the generated raw TL layer when you need to work closer to Telegram's API surface.

The library is aimed at application code, bots, automation scripts, and experiments that want a practical default path first: restore a saved session, send messages, handle updates, and drop down to raw calls only when the typed helpers are not enough.

## Table of Contents

- [Security](#security)
- [Background](#background)
- [Install](#install)
  - [Dependencies](#dependencies)
- [Usage](#usage)
- [Documentation](#documentation)
- [API](#api)
- [Maintainers](#maintainers)
- [Contributing](#contributing)
- [License](#license)

## Security

VTOL works with Telegram credentials and session material. Treat all of the following as secrets:

- Telegram API ID and API hash
- bot tokens
- string sessions
- SQLite session files

Do not commit session files, log encoded string sessions, or reuse the same session across unrelated environments. If a session leaks, rotate it and create a new one.

## Background

VTOL exists to make Telegram's MTProto protocol usable from V without forcing every consumer to build their own client lifecycle, session storage, auth flow, update recovery, and TL wiring.

The project combines two layers:

- a high-level client API for the common path
- a generated TL layer for direct access to Telegram methods and result types

That split lets application code stay simple for the everyday cases:

- create a client
- restore or authorize a session
- resolve peers
- send text, files, or photos
- receive updates through typed handlers

When the high-level surface is not enough, VTOL still exposes the raw `tl.*` constructors and `client.invoke(...)` so you can call Telegram methods directly.

## Install

Install from VPM if you want to consume VTOL as a dependency:

```bash
v install watzon.vtol
```

Clone the repository and symlink it into V's module path if you are developing VTOL itself locally:

```bash
git clone https://github.com/watzon/vtol.git
cd vtol
mkdir -p ~/.vmodules
ln -sfn "$PWD" ~/.vmodules/vtol
```

To verify the checkout compiles and the local environment is usable:

```bash
v test .
```

### Dependencies

VTOL expects:

- a recent [V compiler](https://vlang.io)
- OpenSSL development headers and libraries

Typical OpenSSL installs:

```bash
# macOS (Homebrew)
brew install openssl@3

# Debian / Ubuntu
sudo apt-get install libssl-dev
```

SQLite-backed sessions are built into VTOL through `vtol.session.SQLiteSession`. If you do not want disk persistence, use `vtol.new_client(...)` for an in-memory session instead.

## Usage

Set your Telegram application credentials before running code that authenticates:

```bash
export VTOL_API_ID=12345
export VTOL_API_HASH=your-app-hash
```

The common path is a file-backed client plus `start(...)`, which restores an existing session or performs login on the first run:

```v
module main

import os
import vtol

fn main() {
	run() or {
		eprintln(err)
		exit(1)
	}
}

fn run() ! {
	mut client := vtol.new_client_with_session_file(vtol.ClientConfig{
		app_id:   os.getenv('VTOL_API_ID').int()
		app_hash: os.getenv('VTOL_API_HASH')
	}, '.vtol.session.sqlite')!
	defer {
		client.disconnect() or {}
	}

	client.start(vtol.StartOptions{
		phone_number: fn () !string {
			return os.input('Phone number: ').trim_space()
		}
		code: fn (request vtol.LoginCodeRequest) !string {
			return os.input('Login code: ').trim_space()
		}
		password: fn () !string {
			return os.input('2FA password: ').trim_space()
		}
	})!

	message := vtol.parse_markdown('*hello* from `vtol`') or {
		vtol.plain_text('hello from vtol')
	}

	sent := client.send_text('me', message)!
	println('sent message ${sent.id}: ${sent.text}')
}
```

For long-lived applications, register a handler and let the client own the update loop:

```v
handler_id := client.on_new_message(fn (event vtol.NewMessageEvent) ! {
	println('[${event.kind}] ${event.chat.key}: ${event.text}')
})!
defer {
	client.remove_event_handler(handler_id)
}

client.idle()!
```

Runnable examples live under [`examples/`](examples):

- [`examples/auth_basic`](examples/auth_basic)
- [`examples/send_message`](examples/send_message)
- [`examples/watch_updates`](examples/watch_updates)
- [`examples/download_file`](examples/download_file)
- [`examples/userbot`](examples/userbot)

## Documentation

Project guides live in [`docs/`](docs):

- [`docs/quick-start.md`](docs/quick-start.md) for the end-to-end login and first message flow
- [`docs/auth-and-sessions.md`](docs/auth-and-sessions.md) for memory, string, and SQLite session backends
- [`docs/peers.md`](docs/peers.md) for usernames, cached peers, and peer-like inputs
- [`docs/messages.md`](docs/messages.md) for text formatting, media sends, and history helpers
- [`docs/updates.md`](docs/updates.md) for update handlers, pump loops, and recovery behavior
- [`docs/client-reference.md`](docs/client-reference.md) for the highest-value `vtol.Client` entry points
- [`docs/raw-api.md`](docs/raw-api.md) for direct TL-level usage

## API

VTOL's main exported surface is the `vtol` module.

Core types and entry points:

- `vtol.Client` manages connection state, auth, session restore, peer caching, RPC calls, and update handling.
- `vtol.ClientConfig` configures MTProto transport, datacenter endpoints, retry behavior, and default RPC options.
- `vtol.StartOptions` defines the callbacks used by `client.start(...)` for interactive user or bot login.
- `vtol.Session`, `vtol.ResolvedPeer`, `vtol.SentMessage`, and `vtol.NewMessageEvent` provide the high-level results returned by common workflows.

For normal production mode, `ClientConfig` only needs `app_id` and `app_hash`. Add `dc_options` only when you need a custom bootstrap endpoint or when targeting Telegram test mode.

Common methods:

- construction: `new_client`, `new_client_with_session_file`, `new_client_with_string_session`, `new_client_with_store`
- auth and lifecycle: `start`, `connect`, `disconnect`, `did_restore_session`, `get_me`, `login_bot`
- messaging and media: `send_text`, `send_text_with`, `send_file`, `send_photo`, `download_file`
- dialogs and history: `get_dialog_page`, `get_history_page`, `each_dialog`, `each_history_message`
- updates: `on_new_message`, `on_raw_update`, `pump_updates_once`, `idle`
- raw Telegram access: `invoke`

Supporting modules are also public where needed:

- `vtol.session` for `MemorySession`, `StringSession`, and `SQLiteSession`
- `vtol.updates` for lower-level subscription and state management
- `vtol.tl` for generated Telegram TL constructors, functions, and result types

For fuller guidance, use the docs in [`docs/`](docs) rather than treating this README as the complete API reference.

## Maintainers

- [Chris Watson](https://github.com/watzon)

## Contributing

Questions and bug reports should go through [GitHub issues](https://github.com/watzon/vtol/issues).

Pull requests are accepted. Before opening one, read [CONTRIBUTING.md](CONTRIBUTING.md) and run:

```bash
v run scripts/check_tl_schema.vsh
v fmt -w .
v test .
```

Keep changes scoped, update docs when public APIs change, and avoid changing generated TL files by hand unless the generator flow requires it.

## License

[MIT](LICENSE) © Chris Watson
