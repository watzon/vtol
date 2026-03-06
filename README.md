# VTOL

VTOL is an MTProto library for V with a core-first architecture: build the protocol engine, auth/session machinery, and generated TL types first, then layer ergonomic Telegram client APIs on top.

## Status

The repository is in scaffold mode. The package layout, public placeholder types, CI, docs, and code-generation entrypoints are in place, but the MTProto implementation is not yet functional.

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

- `vtol.v`: root package and initial public API placeholders
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
