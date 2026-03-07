# API Stability

VTOL remains pre-`1.0`. The package is usable for experimentation, but only a small part of the surface should be treated as a medium-term contract.

## Stable enough to build on

- Module boundaries: `crypto -> transport -> auth/session -> rpc -> client/media/updates`
- Generated TL objects staying in `tl` instead of being re-modeled in the root package
- Session persistence via `session.Store`, `session.MemoryStore`, and `session.FileStore`
- Thin client entrypoints such as `connect`, `disconnect`, `invoke`, login flows, upload/download helpers, and update subscription APIs
- Structured RPC error metadata exposed through `rpc.RpcError` and the root `vtol.RpcError`

## Explicitly unstable

- Generated TL coverage and any convenience helpers layered on top of it
- Retry, reconnection, and migration heuristics while long-running client behavior is still being proven
- Integration-test expectations that depend on Telegram account state or evolving server behavior
- Release packaging details until the project is published through VPM and exercised across tagged releases
- Windows support, which remains pending dedicated validation after the OpenSSL and socket toolchain story is proven in CI

## Compatibility intent before 1.0

- Prefer additive changes over breaking renames where practical.
- Keep `vtol` small and move protocol-specific details into subsystem modules.
- Treat `internal/` and generated implementation details as non-contractual.
- Document new stable surfaces here before advertising them in the README.
