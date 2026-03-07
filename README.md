# VTOL

VTOL is an MTProto library for V with a core-first architecture: build the protocol engine, auth/session machinery, and generated TL types first, then layer ergonomic Telegram client APIs on top.

## Status

The repository is still pre-`1.0`, but it is no longer just a scaffold. The core transport/auth/session/RPC layers have unit coverage, and the first thin `vtol.Client` API now covers connect, raw invoke, code login, 2FA password login, bot login, peer resolution, basic account/dialog/message helpers, chunked upload/download flows, CDN redirect metadata and hash helpers, and long-lived update subscriptions with state recovery.

Session persistence now ships with Telethon-style `MemorySession`, `StringSession`, and `SQLiteSession` backends, RPC errors expose flood-wait metadata without discarding the underlying Telegram error payload, and the RPC engine can emit structured debug events for protocol troubleshooting.

Generated TL coverage is now exposed as a public function registry via `tl.current_function_registry()`, and the repository verifies that registry against the pinned normalized schema in test runs.

`vtol.Client` now keeps a bounded in-memory copy of those RPC debug events by default, so reconnects, retries, and DC migrations are inspectable through `client.rpc_debug_events()` without replacing the runtime logger. Set `ClientConfig.rpc_event_history_limit = 0` to disable the buffer or provide `ClientConfig.rpc_config.debug_logger` to forward events elsewhere as well.

## Goals

- Provide a library-first V package named `vtol`
- Build toward user-client MTProto parity in the style of Telethon
- Keep transport, auth, session, TL, RPC, and client concerns isolated by module
- Make TL schema generation a first-class workflow instead of hand-writing Telegram API coverage

## Non-goals for the current stage

- Shipping a working Telegram client
- Hand-writing the full Telegram TL surface
- Supporting every platform before the protocol core is stable
- Locking a stable public API before session and layer compatibility settle

## Project Layout

- Root `vtol` package: split across `vtol.v` plus focused `client_*.v` files
- `vtol.v`: client/runtime core, session persistence wiring, transport setup, and shared helpers
- `client_types.v`, `client_auth.v`, `client_dialogs.v`, `client_media.v`, `client_peers.v`, `client_updates.v`: public client surface grouped by concern without changing the `vtol` import path
- `config/`, `errors/`, `crypto/`, `transport/`, `tl/`, `auth/`, `session/`, `rpc/`, `updates/`, `media/`, `client/`: stable subsystem boundaries
- `internal/`: implementation details that should not leak into the public API
- `docs/`: architecture, MTProto notes, and roadmap
- `scripts/`: schema acquisition and TL generation entrypoints
- `examples/`: runnable usage samples
- `tests/`: fixtures, vectors, and integration suites

## Development

```bash
v run scripts/fetch_schemas.vsh
v run scripts/gen_tl.vsh
v run scripts/check_tl_schema.vsh
v fmt -w .
v fmt -verify .
v test .
```

The TL generation workflow and upgrade process are documented in `docs/tl-generation.md`.

## Session persistence

```v
mut client := vtol.new_client_with_session_file(vtol.ClientConfig{
	app_id:   12345
	app_hash: '0123456789abcdef'
	dc_options: [
		vtol.DcOption{
			id:   2
			host: '149.154.167.50'
			port: 443
		},
	]
}, '/tmp/vtol.session.sqlite')!
```

String sessions work the same way:

```v
mut store := session.new_string_session('')!
mut client := vtol.new_client_with_store(config, store)!
// ... authenticate, resolve peers, send requests ...
println(store.encoded())
```

For custom storage, pass any `session.Store` implementation to `vtol.new_client_with_store`.

## Debug logging

`rpc.EngineConfig` accepts a structured `debug_logger`. Use `rpc.JsonLineDebugLogger{}` for JSON-lines protocol traces or provide a custom `rpc.DebugLogger` implementation.

## Roadmap

The active implementation roadmap lives in `docs/roadmap.md`. The project remains pre-`1.0`, but generated TL coverage, session restore, and live update recovery are now enforced in tests, so the next milestone is API stabilization and cross-platform hardening rather than basic feature completeness.

For the current Telethon/mtcute DX comparison and the recommended post-roadmap backlog, see `docs/dx-comparison.md`.

## Stability notes

The current stable-vs-unstable boundary is documented in `docs/api-stability.md`.
