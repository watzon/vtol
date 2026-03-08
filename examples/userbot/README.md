# userbot

Runnable userbot example that reuses the session created by `examples/auth_basic`.

It watches self-issued `!`-prefixed messages from the logged-in account and replies in the same chat using `event.reply(...)`, then stays alive through `run_until_disconnected()`.

## Commands

- `!ping` replies with `pong`
- `!echo <text>` replies with the provided text
- `!help` prints the available commands

## Environment

Required:

- `VTOL_EXAMPLE_API_ID` or `VTOL_TEST_API_ID`
- `VTOL_EXAMPLE_API_HASH` or `VTOL_TEST_API_HASH`

Optional:

- `VTOL_EXAMPLE_SESSION_FILE` defaults to `.vtol.example.session.sqlite`
- `VTOL_EXAMPLE_DC_HOST` is only used when `VTOL_EXAMPLE_TEST_MODE=1`
- `VTOL_EXAMPLE_TIMEOUT_MS` defaults to `30000`
- `VTOL_EXAMPLE_TEST_MODE=1` to target Telegram test mode

## Run

```bash
export VTOL_EXAMPLE_API_ID=12345
export VTOL_EXAMPLE_API_HASH=your-app-hash
v run ./examples/userbot
```

Send `!ping` from the same Telegram account that owns the session to verify the userbot is watching outgoing commands and replying.

This example assumes the repo is available as `~/.vmodules/vtol` or otherwise resolvable via V's module path.

The example fails fast if no session file was restored, so run `examples/auth_basic` first.
