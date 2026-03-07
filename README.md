# VTOL

VTOL is an MTProto library for V with a core-first architecture: build the protocol engine, auth/session machinery, and generated TL types first, then layer ergonomic Telegram client APIs on top.

## Status

The repository is still pre-`1.0`, but it is no longer just a scaffold. The core transport/auth/session/RPC layers have unit coverage, and the first thin `vtol.Client` API now covers connect, raw invoke, code login, 2FA password login, bot login, peer resolution, and basic account/dialog/message helpers.

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

- `vtol.v`: root package and the current high-level client surface
- `config/`, `errors/`, `crypto/`, `transport/`, `tl/`, `auth/`, `session/`, `rpc/`, `updates/`, `media/`, `client/`: stable subsystem boundaries
- `internal/`: implementation details that should not leak into the public API
- `docs/`: architecture, MTProto notes, and roadmap
- `scripts/`: schema acquisition and TL generation entrypoints
- `examples/`: future usage samples
- `tests/`: fixtures, vectors, and integration suites

## Development

```bash
v run scripts/fetch_schemas.vsh
v run scripts/gen_tl.vsh
v fmt -w .
v fmt -verify .
v test .
```

The TL generation workflow and upgrade process are documented in `docs/tl-generation.md`.

## Roadmap

The active implementation roadmap lives in `docs/roadmap.md`. The project should remain pre-`1.0` until TL generation, auth/session persistence, and update recovery are proven in integration tests.
