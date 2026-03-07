# watch_updates

Runnable long-lived session example that reuses the session created by `examples/auth_basic`.

It registers a high-level `client.on_new_message(...)` handler, prints VTOL message events, and relies on the existing reconnect-and-recover path under the hood.

## Environment

Required:

- `VTOL_EXAMPLE_API_ID` or `VTOL_TEST_API_ID`
- `VTOL_EXAMPLE_API_HASH` or `VTOL_TEST_API_HASH`

Optional:

- `VTOL_EXAMPLE_SESSION_FILE` defaults to `.vtol.example.session.sqlite`
- `VTOL_EXAMPLE_DC_HOST` defaults to `149.154.167.50`
- `VTOL_EXAMPLE_TIMEOUT_MS` defaults to `30000`
- `VTOL_EXAMPLE_PUMP_INTERVAL_MS` defaults to `250`
- `VTOL_EXAMPLE_MAX_PUMPS` to stop after a fixed number of pump cycles
- `VTOL_EXAMPLE_TEST_MODE=1` to target Telegram test mode
- `VTOL_DEBUG_RPC=1`, `VTOL_DEBUG_MTPROTO=1`, or `VTOL_DEBUG_TRANSPORT=1` for protocol debugging

## Run

```bash
export VTOL_EXAMPLE_API_ID=12345
export VTOL_EXAMPLE_API_HASH=your-app-hash
v run ./examples/watch_updates
```

To run a bounded smoke loop instead of watching forever:

```bash
export VTOL_EXAMPLE_MAX_PUMPS=10
v run ./examples/watch_updates
```

This example assumes the repo is available as `~/.vmodules/vtol` or otherwise resolvable via V's module path.

The example fails fast if no session file was restored, so run `examples/auth_basic` first.
