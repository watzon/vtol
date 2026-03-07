# Client Reference

This is a short guide to the highest-value `vtol.Client` methods. It is not a full API reference. The goal is to show which method to reach for first.

## Construction

### `new_client(config)`

Create a client backed by an in-memory session.

Use it for:

- tests
- short-lived scripts
- flows where you do not want persistence

### `new_client_with_session_file(config, path)`

Create a client backed by a SQLite session file.

Use it for:

- most local applications
- bots
- scripts you want to restart without logging in again

### `new_client_with_string_session(config, value)`

Create a client from an existing encoded string session.

Use it for:

- external secret storage
- CI
- environments where a file on disk is not the right persistence model

### `new_client_with_store(config, store)`

Create a client with a custom `session.Store`.

Use it when:

- you need your own persistence backend
- you want direct access to the store object

## Lifecycle

### `connect()`

Connect the client and build the runtime from the session store if needed.

Reach for it when:

- you want to connect explicitly before other work
- you want to inspect restore state early

### `disconnect()`

Disconnect cleanly.

Call it:

- in `defer`
- during shutdown
- when you want to release network resources deterministically

### `client_state()`

Read the coarse connection state.

### `is_connected()`

Check whether the runtime is currently connected.

### `did_restore_session()`

Check whether this client instance started from an existing saved session.

## Auth

### `start(options)`

Default entry point for login or restore.

Use it for:

- user login
- bot login
- session restore

### `login_bot(bot_token)`

Explicit bot login.

### `send_login_code()`, `sign_in_code()`, `sign_in_password()`, `complete_login()`

Manual auth building blocks for custom login flows.

### `get_me()`

Fetch the current account after authorization.

## Peers

### `resolve_peer(key)`

Resolve a string peer reference into `ResolvedPeer`.

Use it when:

- you want to inspect normalized peer metadata
- you want to resolve once and reuse many times

### `resolve_peer_like(peer)`

Normalize a peer-like value into `ResolvedPeer`.

Use it when:

- you are bridging between high-level and raw code

### `cached_peer(key)` and `cached_input_peer(key)`

Check whether VTOL already knows a peer locally without a network request.

## Messages And Media

### `send_text(peer, message)`

Default high-level text send. Returns `SentMessage`.

### `send_text_with(peer, message, options)`

Text send with `SendOptions`.

### `send_file(...)`, `send_file_path(...)`

High-level file sends returning `SentMessage`.

### `send_photo(...)`, `send_photo_path(...)`

High-level photo sends returning `SentMessage`.

### `send_text_updates(...)`, `send_file_updates(...)`, `send_photo_updates(...)`

Raw-result variants for when you want `tl.UpdatesType`.

### `upload_file_*()` and `download_file*()`

Lower-level media transfer helpers for upload and download workflows.

## Dialogs And History

### `get_dialog_page(options)`

Fetch dialogs through a page wrapper instead of working with raw result unions immediately.

### `get_history_page(peer, options)`

Default history browser for application code.

### `each_dialog()`, `each_history_message()`

Iterate across many pages without open-coding the pagination loop.

### `collect_dialogs()`, `collect_history()`

Fetch bounded batches when you want a simple aggregate result.

## Updates

### `on_new_message(handler)`

Default high-level message handler.

### `on_new_message_with_config(config, handler)`

Filtered message handler.

### `on_raw_update(handler)`

Lower-level handler for raw update batches and recovered differences.

### `idle()`

Run the update loop until disconnection.

### `pump_updates_once()`

Advance updates one step when your application owns the main loop.

### `sync_update_state()` and `update_state()`

Bootstrap or inspect the current update state.

## Raw API And Debugging

### `invoke(function)`

Escape hatch to the generated raw Telegram API.

### `invoke_with_options(function, options)`

Raw call with per-request RPC options.

### `rpc_debug_events()` and `clear_rpc_debug_events()`

Inspect or clear the bounded in-memory RPC debug history.

## Recommended First Methods

If you are learning VTOL, start here:

1. `new_client_with_session_file()`
2. `start()`
3. `send_text()`
4. `on_new_message()`
5. `get_history_page()`
6. `invoke()` only when you need the raw API
