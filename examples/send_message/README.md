# send_message

Runnable message-send example that reuses the session created by `examples/auth_basic`.

## Environment

Required:

- `VTOL_EXAMPLE_API_ID` or `VTOL_TEST_API_ID`
- `VTOL_EXAMPLE_API_HASH` or `VTOL_TEST_API_HASH`

Optional:

- `VTOL_EXAMPLE_SESSION_FILE` defaults to `.vtol.example.session.json`
- `VTOL_EXAMPLE_PEER` defaults to `me`
- `VTOL_EXAMPLE_MESSAGE` defaults to `hello from VTOL`
- `VTOL_EXAMPLE_DC_HOST` defaults to `149.154.167.50`
- `VTOL_EXAMPLE_TEST_MODE=1` to target Telegram test mode

## Run

```bash
export VTOL_EXAMPLE_API_ID=12345
export VTOL_EXAMPLE_API_HASH=your-app-hash
v run ./examples/send_message
```

To send somewhere other than Saved Messages:

```bash
export VTOL_EXAMPLE_PEER=telegram
export VTOL_EXAMPLE_MESSAGE='hello from VTOL'
v run ./examples/send_message
```

This example assumes the repo is available as `~/.vmodules/vtol` or otherwise resolvable via V's module path.

The example fails fast if no session file was restored, so run `examples/auth_basic` first.
