# auth_basic

Runnable login example that creates or reuses a session file.

It uses `client.start(vtol.StartOptions{ ... })`, where the auth inputs are callback providers for phone number, bot token, login code, and password.

## Environment

Required:

- `VTOL_EXAMPLE_API_ID`
- `VTOL_EXAMPLE_API_HASH`

Phone login:

- `VTOL_EXAMPLE_PHONE_NUMBER`
- optional `VTOL_EXAMPLE_LOGIN_CODE`
- optional `VTOL_EXAMPLE_PASSWORD`

Bot login:

- `VTOL_EXAMPLE_BOT_TOKEN`

Optional:

- `VTOL_EXAMPLE_SESSION_FILE` defaults to `.vtol.example.session.json`
- `VTOL_EXAMPLE_DC_HOST` defaults to `149.154.167.50` for the initial connection; the client discovers additional Telegram DCs automatically
- `VTOL_EXAMPLE_TIMEOUT_MS` defaults to `30000`
- `VTOL_DEBUG_RPC=1` to print RPC request/result/error lines to stderr
- `VTOL_DEBUG_MTPROTO=1` to print decoded MTProto messages to stderr
- `VTOL_EXAMPLE_TEST_MODE=1` to target Telegram test mode

For lower-level transport hex dumps, the library also honors `VTOL_DEBUG_TRANSPORT=1`.

## One-time setup

These examples live under `./examples`, so V needs to be able to resolve `import vtol`.

If this checkout is not already installed as a V module, symlink it once:

```bash
mkdir -p ~/.vmodules
ln -sfn "$PWD" ~/.vmodules/vtol
```

## Run

User login:

```bash
export VTOL_EXAMPLE_API_ID=12345
export VTOL_EXAMPLE_API_HASH=your-app-hash
export VTOL_EXAMPLE_PHONE_NUMBER=+15551234567
export VTOL_DEBUG_RPC=1
export VTOL_DEBUG_MTPROTO=1
v run ./examples/auth_basic
```

The program uses env-aware callbacks: each auth prompt reads the matching `VTOL_EXAMPLE_*` variable first and falls back to interactive input when it is unset.

Bot login:

```bash
export VTOL_EXAMPLE_API_ID=12345
export VTOL_EXAMPLE_API_HASH=your-app-hash
export VTOL_EXAMPLE_BOT_TOKEN=123456:telegram-bot-token
v run ./examples/auth_basic
```

Successful runs write a reusable session file, which the other examples consume.
