# Peers

Most high-level VTOL methods accept a peer-like input instead of forcing you to construct a raw `tl.InputPeerType` first.

That is the normal way to work with:

- `send_text()`
- `send_file()`
- `send_photo()`
- `get_history()`
- `get_history_page()`
- `conversation()`

## Supported Peer-Like Inputs

VTOL currently accepts these peer-like values:

- `string`
- `vtol.ResolvedPeer`
- concrete `tl.InputPeer*` variants such as `tl.InputPeerSelf`, `tl.InputPeerUser`, `tl.InputPeerChat`, and `tl.InputPeerChannel`

The normalization entry point is `resolve_peer_like(...)`.

## String Inputs

String inputs are the most ergonomic option.

### `me` and `self`

Use `me` or `self` to target the current account.

```v
client.send_text('me', 'hello')!
client.send_text('self', 'hello again')!
```

### Usernames

Use a username when VTOL can resolve the peer remotely.

```v
client.send_text('telegram', 'hello')!
client.send_text('@durov', 'ping')!
```

VTOL normalizes usernames internally, so `telegram` and `@telegram` are treated the same.

### Cached peer keys

VTOL also understands cache keys such as:

- `user:42`
- `chat:123`
- `channel:456`

Those keys only work after VTOL has already cached that peer from:

- authorization
- a username lookup
- dialog loading
- history loading

If you try to use `user:42` before VTOL has that peer cached, the client returns an error instead of making a remote lookup.

## Resolving Peers Explicitly

Use `resolve_peer()` or `resolve_peer_like()` when you want the normalized peer metadata up front.

```v
peer := client.resolve_peer('telegram')!
println(peer.key)
println(peer.username)

sent := client.send_text(peer, 'hello from a pre-resolved peer')!
println(sent.peer.key)
```

`ResolvedPeer` contains:

- a stable VTOL cache key
- the normalized username when one exists
- the raw `tl.PeerType`
- the raw `tl.InputPeerType`
- any users or chats that were resolved alongside it

## Cached Lookups

If you only want to know whether VTOL already has a peer locally, use:

- `cached_peer(key)`
- `cached_input_peer(key)`

These do not hit the network.

That makes them useful when you want:

- a fast path with no remote resolution
- to decide whether a cache key is safe to reuse
- to keep explicit control over network behavior

## When To Use Raw `InputPeer*`

Passing a raw `tl.InputPeerType` is still valid when you already have one, for example from a raw TL response or a stored application-level mapping.

```v
input_peer := tl.InputPeerUser{
	user_id:     user_id
	access_hash: access_hash
}

client.send_text(input_peer, 'hello')!
```

But for the common path, prefer string or `ResolvedPeer` inputs. They keep the calling code shorter and let VTOL own the normalization rules.

## Common Patterns

### Send to Saved Messages

```v
client.send_text('me', 'saved')!
```

### Resolve once, reuse many times

```v
peer := client.resolve_peer('telegram')!
client.send_text(peer, 'first')!
client.send_text(peer, 'second')!
history := client.get_history_page(peer, vtol.HistoryPageOptions{
	limit: 20
})!
println(history.messages.len)
```

### Resolve from dialogs before using cache keys

```v
dialogs := client.get_dialog_page(vtol.DialogPageOptions{
	limit: 20
})!

// A later call can now reuse keys from peers VTOL cached while loading dialogs.
client.send_text('channel:123456', 'hello') or {
	eprintln(err)
}
```

## Practical Rule

Use peer-like strings for application code. Drop down to `ResolvedPeer` or raw `tl.InputPeer*` only when you need precise control or you are bridging to the raw API.
