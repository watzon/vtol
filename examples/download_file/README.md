# download_file

Runnable media-download example that reuses the session created by `examples/auth_basic`.

It looks through recent history, finds the first photo or document, downloads it with progress output, and writes it to disk.

## Environment

Required:

- `VTOL_EXAMPLE_API_ID` or `VTOL_TEST_API_ID`
- `VTOL_EXAMPLE_API_HASH` or `VTOL_TEST_API_HASH`

Optional:

- `VTOL_EXAMPLE_SESSION_FILE` defaults to `.vtol.example.session.sqlite`
- `VTOL_EXAMPLE_PEER` defaults to `me`
- `VTOL_EXAMPLE_HISTORY_LIMIT` defaults to `50`
- `VTOL_EXAMPLE_OUTPUT` to override the output path
- `VTOL_EXAMPLE_DC_HOST` is only used when `VTOL_EXAMPLE_TEST_MODE=1`
- `VTOL_EXAMPLE_TEST_MODE=1` to target Telegram test mode

## Run

```bash
export VTOL_EXAMPLE_API_ID=12345
export VTOL_EXAMPLE_API_HASH=your-app-hash
v run ./examples/download_file
```

By default it searches Saved Messages. To target another peer:

```bash
export VTOL_EXAMPLE_PEER=telegram
export VTOL_EXAMPLE_OUTPUT=/tmp/telegram-asset.bin
v run ./examples/download_file
```

This example assumes the repo is available as `~/.vmodules/vtol` or otherwise resolvable via V's module path.

The example disables CDN redirects to keep the flow simple. If recent history does not contain a photo or document, it exits with a clear error.
