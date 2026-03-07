# DX Comparison: VTOL vs Telethon and mtcute

VTOL has reached feature completeness for its current roadmap, but the developer experience is still closer to a well-factored MTProto toolkit than to the productized feel of Telethon or mtcute.

This document compares the current VTOL surface against the usage patterns emphasized in the current Telethon and mtcute docs and turns that comparison into a concrete DX backlog.

## Sources

- Telethon signing in: https://docs.telethon.dev/en/stable/basic/signing-in.html
- Telethon client reference: https://docs.telethon.dev/en/stable/quick-references/client-reference.html
- Telethon sessions: https://docs.telethon.dev/en/stable/concepts/sessions.html
- Telethon events reference: https://docs.telethon.dev/en/stable/quick-references/events-reference.html
- mtcute quick start: https://mtcute.dev/guide
- mtcute getting updates: https://mtcute.dev/guide/intro/updates
- mtcute peers: https://mtcute.dev/guide/topics/peers
- mtcute parse modes: https://mtcute.dev/guide/topics/parse-modes
- mtcute raw API: https://mtcute.dev/guide/topics/raw-api
- mtcute `sendText` reference: https://ref.mtcute.dev/funcs/_mtcute_core.highlevel_methods.sendText.html

## What VTOL Already Matches Well

- `Client.start()` already gives VTOL a strong first-step auth flow similar in spirit to Telethon's `start()` and mtcute's `start()`.
- Session persistence is in place with `MemorySession`, `StringSession`, and `SQLiteSession`.
- Raw TL coverage remains accessible through `Client.invoke()`, which aligns with Telethon's raw request support and mtcute's documented raw API escape hatch.
- The client already has real update state sync and recovery instead of a fake event facade.
- Dialog/history pagination helpers and media helpers are present, so the missing piece is mostly ergonomics, not protocol capability.

## Where VTOL Still Feels Lower-Level

### 1. Peer handling is still too explicit

Telethon and mtcute let users pass a broad "entity-like" or `InputPeerLike` value to most high-level methods. In VTOL, the user still has to think about `tl.InputPeerType` early, or pick special-case helpers like `send_message_to_username()`.

Current VTOL surface:

- `send_message(peer tl.InputPeerType, ...)`
- `send_file(peer tl.InputPeerType, ...)`
- `send_photo(peer tl.InputPeerType, ...)`
- `resolve_input_peer(key string)` for username-oriented lookup

This is functional, but it is not yet "just use a chat reference everywhere."

### 2. Message APIs return transport-level results, not message objects

Telethon documents `send_message()` as returning a `Message`. mtcute documents `sendText()` as returning a `Message`.

VTOL currently returns `tl.UpdatesType` from `send_message()`, `send_file()`, and `send_photo()`. That preserves MTProto fidelity, but it pushes users into update decoding if they want the sent message ID, peer, or follow-up actions.

### 3. Updates are exposed as batches, not as typed events

Telethon and mtcute both teach updates through high-level handlers:

- Telethon: event handlers like new-message listeners
- mtcute: `onNewMessage`, `onUpdate`, and configurable update handling

VTOL currently exposes:

- `subscribe_updates()`
- `pump_updates_once()`
- raw `updates.Event` values containing `tl.UpdatesType` or `tl.UpdatesDifferenceType`

That is solid infrastructure, but the UX is still "manage the pump loop and inspect raw batches."

### 4. Task-oriented docs are thin

Telethon and mtcute both have clear user-facing guides for:

- signing in
- sessions
- messages
- updates
- peers/entities
- raw API usage as a fallback

VTOL's docs are currently architecture-first and stability-first. That is useful for contributors, but it does not yet teach the library from a user task perspective.

### 5. There is no strong formatting story for rich text

mtcute explicitly documents parse modes and treats raw text+entities as the underlying model with helpers on top. Telethon also presents a user-friendly message abstraction and formatting-oriented docs.

VTOL currently only offers plain string message helpers at the public client layer. Users who want entities, formatting, or richer send parameters need to drop into raw TL quickly.

### 6. Conversations and handler ergonomics are missing

Both libraries make request-response chat workflows easier:

- Telethon has conversation-oriented patterns
- mtcute has a documented `Conversation` abstraction

VTOL has enough primitives to build this, but no first-class conversation helper yet.

### 7. The happy path still leaks library internals

The current README and examples prove capability, but the library still introduces concepts in this order:

1. subsystem layout
2. session backends
3. debug logging
4. generation workflow

Telethon and mtcute instead lead with:

1. create client
2. start/login
3. send a message
4. receive updates

That ordering matters for perceived maturity.

## Highest-Impact DX Improvements

### Priority 1: Add a `PeerLike` input story

Introduce a small public abstraction that high-level methods accept directly.

Possible direction:

- `string` values like `'me'`, `'self'`, usernames, and cached `user:123` / `channel:456`
- `ResolvedPeer`
- `tl.InputPeerType`
- maybe a dedicated `PeerLike` sum type plus `resolve_peer_like()`

Then add ergonomic wrappers such as:

- `send_text(peer PeerLike, text string, options SendTextOptions)`
- `send_photo(peer PeerLike, ...)`
- `get_history_for(peer PeerLike, ...)`

This is the single biggest gap between VTOL and both comparison libraries.

### Priority 2: Return a high-level sent-message object

Add a small VTOL-owned wrapper for commonly used message operations.

The wrapper does not need to replace generated TL types. It only needs to make the common path pleasant:

- sent message ID
- peer info
- text/caption access
- raw update access
- helpers like `reply()`, `edit()`, or `delete()` later

A thin `SentMessage` or `MessageHandle` type would already move VTOL much closer to Telethon/mtcute.

### Priority 3: Add an event facade over `updates.Manager`

Keep the current recovery-capable update engine, but layer typed handlers on top.

Possible first slice:

- `client.on_new_message(handler)`
- `client.on_raw_update(handler)`
- optional filters by chat, sender, outgoing, and simple text pattern
- `client.idle()` or `client.run_until_disconnected()`

This should compile down to the existing `subscribe_updates()` and `pump_updates_once()` machinery rather than replacing it.

### Priority 4: Publish user-facing guides, not just architecture docs

Recommended doc set:

- `docs/quick-start.md`
- `docs/auth-and-sessions.md`
- `docs/peers.md`
- `docs/messages.md`
- `docs/updates.md`
- `docs/raw-api.md`

The important shift is to document VTOL the same way Telethon and mtcute are learned: by tasks and concepts, not by internal architecture.

### Priority 5: Add text entity / parse mode support

Do not overfit this into the client core. Follow mtcute's direction instead:

- treat rich text as `{ text, entities }`
- add optional helpers for markdown/html parsing on top

This keeps the protocol model honest while still improving the common send path.

### Priority 6: Add a conversation helper

Likely shape:

- `client.conversation(peer PeerLike) !Conversation`
- `conversation.send_text(...)`
- `conversation.wait_for_reply(...)`
- `conversation.wait_for_message(...)`

This is not the first DX improvement to build, but it is one of the clearest markers of "Telethon-class usability."

## Lower-Priority but Still Valuable

- Add QR login if MTProto support is ready and the implementation can stay thin.
- Add item iterators in addition to page iterators so users can consume dialogs and messages one-by-one instead of only per page.
- Add a small "quick reference" doc listing the most important `Client` methods, similar to Telethon's client reference.
- Accept session file paths and session strings more directly in the main constructor path so the first example becomes shorter.
- Add more result normalization helpers so common methods do not force users to unpack raw `tl.*` unions early.

## Suggested Implementation Order

1. Docs-first pass: quick start, peers, messages, updates, raw API.
2. `PeerLike` normalization for high-level client methods.
3. `send_text()` returning a VTOL message wrapper while keeping raw methods available.
4. Event facade with `on_new_message()` and `idle()`.
5. Rich text entity helpers.
6. Conversation API.

## Bottom Line

VTOL is already much closer to Telethon and mtcute in protocol capability than the current docs and examples suggest.

The biggest remaining gap is not coverage. It is that VTOL still makes the user think in raw TL terms too early:

- `InputPeerType` instead of "chat-like"
- `tl.UpdatesType` instead of "message"
- manual pump loops instead of handlers
- contributor docs instead of task docs

If you want the fastest path toward a Telethon/mtcute feel, focus on those four gaps first.
