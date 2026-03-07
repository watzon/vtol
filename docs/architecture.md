# Architecture

## Layer order

The library is organized in a core-first sequence:

1. `crypto`
2. `transport`
3. `auth`
4. `session`
5. `rpc`
6. `client`
7. `media`
8. `updates`

`tl` sits across the stack because generated Telegram types and codecs feed both low-level message handling and high-level client ergonomics.

## Module ownership

- `vtol`: small public surface and top-level domain types, implemented across `vtol.v` and focused `client_*.v` companion files in the repository root
- `config`: logging, retry, and future runtime configuration definitions
- `errors`: shared error taxonomy categories
- `crypto`: crypto capabilities and key-material abstractions
- `transport`: wire framing, endpoints, and reconnect policies
- `tl`: schema metadata and generated TL types
- `auth`: handshake and auth-key lifecycle
- `session`: persisted session state and storage interfaces
- `rpc`: request envelopes, timeout policy, and middleware hooks
- `updates`: state vectors and update subscription primitives
- `media`: chunked transfer primitives
- `client`: orchestration state for the high-level API
- `internal`: codegen and protocol helpers that should not be imported as stable API

## Public API policy

- Keep the root package intentionally small.
- Split the root package across focused same-module files when the public client surface grows, rather than collapsing unrelated concerns back into one file.
- Only promote types to `vtol` when they are stable enough to represent long-term library concepts.
- Keep generated TL types in `tl`.
- Keep protocol implementation details in subsystem modules or `internal/`.

## Concurrency policy

- Prefer channels for update delivery and long-lived event streams.
- Use shared mutable state only where MTProto sequencing or session restoration requires it.
- Keep backpressure decisions explicit in update subscription APIs.

## Packaging policy

- The package remains pre-`1.0` until session persistence, TL generation, and update recovery are production-grade.
- CI should validate formatting and tests on macOS and Linux before widening platform support.
- Credential-gated integration suites should live separately from the default deterministic `v test .` path.
- Tagged releases should validate against `v.mod` versioning before publishing archives.

## Stability mapping

- `docs/api-stability.md` is the source of truth for which public surfaces are stable enough for downstream use.
- `internal/`, generated helpers, and cross-platform packaging behavior remain explicitly unstable until called out there.
