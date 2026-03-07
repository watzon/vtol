# VTOL Roadmap

Status key:

- `[x]` scaffolded or documented in the repository
- `[ ]` not implemented yet

## Current focus

The original protocol-and-coverage roadmap is complete. The next roadmap should optimize for developer experience rather than raw MTProto capability.

The comparison and rationale for the next phases live in `docs/dx-comparison.md`. In short, VTOL now needs to reduce how early the public API leaks raw TL concepts and make the common path look more like Telethon and mtcute:

- chat-like peer inputs instead of requiring `tl.InputPeerType` early
- message-oriented return values instead of raw `tl.UpdatesType` for common send flows
- handler-oriented update APIs instead of only subscription channels and manual pump loops
- task-oriented user docs instead of primarily contributor-oriented docs

The implementation order should be code-first. Rewrite the user-facing docs only after the new DX abstractions are present and stable enough to document without immediate churn.

## Phase 0: Repo and package foundation

- [x] 0.1 Replace the executable scaffold with a library scaffold by retiring `main.v` and making the root package `vtol`.
- [x] 0.2 Keep `v.mod` as the single package manifest and expand metadata only as needed for VPM distribution.
- [x] 0.3 Add `README.md` with project goals, non-goals, supported platforms, and a phased maturity statement.
- [x] 0.4 Add `LICENSE` and contribution guidance.
- [x] 0.5 Add CI to run `v fmt -verify .`, `v test .`, and at least one build matrix over macOS and Linux.
- [x] 0.6 Establish folder ownership so each MTProto subsystem has a stable module boundary from the start.
- [x] 0.7 Add architecture notes documenting layer order: `crypto -> transport -> auth/session -> rpc -> client/media/updates`.
- [x] 0.8 Define versioning policy and mark the project as unstable until API generation and session compatibility are settled.

## Phase 1: Core domain model and library conventions

- [x] 1.1 Define the root error taxonomy for transport, auth, RPC, schema, session, and media failures.
- [x] 1.2 Define immutable config structs and explicit result-returning constructors.
- [x] 1.3 Define DC metadata and endpoint selection rules.
- [x] 1.4 Define session persistence interfaces before implementing storage backends.
- [x] 1.5 Define logging and trace hooks so deep protocol debugging does not leak into the public API.
- [x] 1.6 Decide and document concurrency policy: channels for updates/events, locks only where shared mutable state is unavoidable.
- [x] 1.7 Establish rules for public vs internal modules to prevent API bloat.

## Phase 2: TL schema ingestion and code generation

- [x] 2.1 Add schema source management for Telegram TL definitions and layer metadata.
- [x] 2.2 Define a repeatable generation pipeline that fetches, normalizes, and snapshots schema inputs.
- [x] 2.3 Generate constructors, functions, enums, flags, and sum-type-like unions into the `tl` module.
- [x] 2.4 Generate serialization and deserialization code instead of hand-writing wire logic for API objects.
- [x] 2.5 Preserve unknown or future constructors gracefully so layer bumps are survivable.
- [x] 2.6 Add golden fixture tests for generated binary encoding and decoding.
- [x] 2.7 Add a compatibility process for upgrading Telegram layers without breaking session or request code.

## Phase 3: Binary codec and transport engine

- [x] 3.1 Implement primitive TL readers and writers with exact little-endian and padding behavior.
- [x] 3.2 Implement MTProto transport framing for abridged first, then intermediate/full if needed.
- [x] 3.3 Add TCP connection management with timeout, reconnect, and DC failover hooks.
- [x] 3.4 Add message ID, seqno, ack, and container handling.
- [x] 3.5 Add bad-message, bad-server-salt, and resend handling.
- [x] 3.6 Add clock-skew detection and correction strategy for message ID validity.
- [x] 3.7 Add transport-level observability for frame sizes, retries, and reconnect reasons.

## Phase 4: Crypto abstraction and auth key exchange

- [x] 4.1 Create a crypto abstraction module with C-backed implementations hidden behind V interfaces.
- [x] 4.2 Implement required primitives for MTProto 2.0 handshake and message encryption.
- [x] 4.3 Implement nonce handling and temporary state for the auth key exchange flow.
- [x] 4.4 Implement the full authorization handshake against Telegram DCs.
- [x] 4.5 Derive and persist auth keys, server salt, session IDs, and layer metadata.
- [x] 4.6 Add cryptographic vector tests where official or community-known vectors exist.
- [x] 4.7 Add negative-path tests for invalid nonces, mismatched hashes, and replay-like conditions.

## Phase 5: Session engine and RPC pipeline

- [x] 5.1 Build the encrypted message packer/unpacker on top of the auth key.
- [x] 5.2 Implement request correlation, pending futures/promises equivalent, and timeout handling.
- [x] 5.3 Implement middleware points for retries, flood-wait handling, DC migration, and logging.
- [x] 5.4 Support gzip-packed payloads, containers, and automatic ack generation.
- [x] 5.5 Implement session restore from persisted storage without forcing re-auth.
- [x] 5.6 Add clean disconnect and reconnect semantics that preserve in-flight safety where possible.

## Phase 6: High-level client API

- [x] 6.1 Design `vtol.Client` around explicit `connect`, `login`, `invoke`, and `disconnect` flows.
- [x] 6.2 Add sign-in flows for code-based login, 2FA password, and bot-token-compatible paths where MTProto supports them.
- [x] 6.3 Expose ergonomic wrappers for core account, dialog, chat, and messaging operations.
- [x] 6.4 Add input entity resolution and cached peer handling.
- [x] 6.5 Keep the high-level surface thin over generated TL methods to avoid drift from Telegram capabilities.
- [x] 6.6 Add examples that mirror the intended Telethon-like usage style without hiding failures.

## Phase 7: Updates, state sync, and long-lived clients

- [x] 7.1 Implement update state tracking with `pts`, `qts`, `seq`, and date handling.
- [x] 7.2 Implement gap detection and `getDifference` recovery logic.
- [x] 7.3 Provide a subscription API for updates, with backpressure behavior defined explicitly.
- [x] 7.4 Separate update ingestion from user callbacks so slow consumers do not corrupt session state.
- [x] 7.5 Add reconnection and re-subscription behavior for long-running clients.
- [x] 7.6 Add integration tests for out-of-order, duplicated, and missed updates.

## Phase 8: Media and large payload workflows

- [x] 8.1 Implement upload and download abstractions for files and media parts.
- [x] 8.2 Support chunked transfer, resume, and progress reporting.
- [x] 8.3 Add CDN and file-reference handling where required by Telegram semantics.
- [x] 8.4 Add message send helpers for text, files, photos, and common media flows.
- [x] 8.5 Add large-file integration tests and failure recovery for interrupted transfers.

## Phase 9: Reliability, packaging, and ecosystem fit

- [x] 9.1 Add session storage backends starting with file-based persistence, then optional pluggable stores.
- [x] 9.2 Add rate-limit and flood-wait ergonomics that preserve raw error access.
- [x] 9.3 Add structured debug logging suitable for protocol troubleshooting.
- [x] 9.4 Harden CI with integration suites gated behind credentials and fast deterministic unit suites by default.
- [x] 9.5 Prepare VPM-friendly packaging and release automation.
- [ ] 9.6 Add cross-platform validation for Windows only after crypto abstraction and socket behavior are stable.
- [x] 9.7 Publish API docs and architecture docs that clearly separate stable and unstable surfaces.

## Phase 10: Telethon-class completeness

- [x] 10.1 Expand generated method coverage to the full supported Telegram layer.
- [x] 10.2 Add richer entity helpers, pagination utilities, and convenience iterators.
- [x] 10.3 Add robust dialog/history iteration and batched fetch helpers.
- [x] 10.4 Add reconnection, migration, and retry behavior that is transparent but inspectable.
- [x] 10.5 Add example applications that prove login, messaging, updates, downloads, and long-running sessions.
- [x] 10.6 Define a compatibility and upgrade process for future Telegram layer changes.
- [x] 10.7 Mark a `1.0` target only after generated API coverage, session stability, and update recovery are proven in integration testing.

## Phase 11: Peer and message ergonomics

- [x] 11.1 Define a public `PeerLike` input story that can represent usernames, `me`/`self`, cached entity keys, `ResolvedPeer`, and `tl.InputPeerType`.
- [x] 11.2 Add a normalization helper such as `resolve_peer_like()` and make high-level client methods use it consistently.
- [x] 11.3 Replace username-only convenience helpers with generic chat-like wrappers so `send_text`, `send_photo`, `send_file`, and history helpers accept the same peer contract.
- [x] 11.4 Add a thin VTOL-owned sent-message wrapper that captures the common message metadata users need without hiding raw updates.
- [x] 11.5 Make high-level send helpers return that sent-message wrapper while preserving access to the raw `tl.UpdatesType`.
- [x] 11.6 Add result normalization helpers for common message/update responses so users do not need to manually unpack TL unions for routine flows.
- [x] 11.7 Add item-level dialog and history iteration helpers in addition to page/batch helpers.

## Phase 12: Event and conversation ergonomics

- [x] 12.1 Add a typed event facade over `updates.Manager` so users can register handlers without manually draining subscription channels.
- [x] 12.2 Add a first high-level handler such as `on_new_message()` that exposes a VTOL message/event wrapper rather than raw update batches.
- [x] 12.3 Add basic event filters for peer/chat, sender, outgoing/incoming, and simple text matching without forcing users into raw TL inspection.
- [x] 12.4 Add `idle()` or `run_until_disconnected()` so long-lived clients do not require hand-written pump loops for the happy path.
- [x] 12.5 Ensure the handler layer composes with the existing update recovery logic instead of bypassing it.
- [ ] 12.6 Add a conversation helper that supports request-response flows like send, wait for reply, and wait for next message within a chat.
- [ ] 12.7 Add tests that prove handler delivery, ordering, reconnect recovery, and backpressure behavior remain correct under the new facade.

## Phase 13: Rich-text and common-flow polish

- [ ] 13.1 Add a user-facing rich-text input model based on `{ text, entities }` rather than hard-coding formatting logic into the client core.
- [ ] 13.2 Add optional markdown and HTML parsing helpers layered on top of that entity model.
- [ ] 13.3 Expand high-level send options for common cases such as reply-to, silent send, scheduling, and link-preview control where Telegram semantics are stable enough.
- [ ] 13.4 Shorten common constructor paths so session-file and string-session startup require less ceremony in the first example.
- [ ] 13.5 Revisit examples so the primary examples use the new peer, message, and event abstractions rather than the lower-level flows.
- [ ] 13.6 Re-audit the public API stability boundary after the DX pass and explicitly mark which new helper surfaces are intended to be stable for `1.0`.

## Phase 14: Documentation and 1.0 readiness

- [ ] 14.1 Rewrite the top-level README around the first-user journey: create client, start/login, send a message, receive updates, then discover advanced topics.
- [ ] 14.2 Add `docs/quick-start.md` with a minimal end-to-end example for session restore, login, sending a message, and clean disconnect.
- [ ] 14.3 Add `docs/auth-and-sessions.md` that explains `MemorySession`, `StringSession`, `SQLiteSession`, session safety, and restore semantics in user-facing terms.
- [ ] 14.4 Add `docs/peers.md` that explains peer resolution, cached peers, usernames, `me`/`self`, and the finalized `PeerLike` contract.
- [ ] 14.5 Add `docs/messages.md` that teaches common send/fetch flows through the new message-oriented surface before introducing raw TL unions.
- [ ] 14.6 Add `docs/updates.md` that documents long-lived clients, update state, recovery, and the finalized high-level handler model.
- [ ] 14.7 Add `docs/raw-api.md` that explicitly positions `Client.invoke()` as the escape hatch after high-level helpers, not the default starting point.
- [ ] 14.8 Add a short `Client` quick reference doc listing the highest-value methods and their intended use.
- [ ] 14.9 Mark `1.0` only after the docs, PeerLike/message/event ergonomics, and update-recovery invariants are all proven together.
