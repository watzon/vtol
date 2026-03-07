# Raw API

VTOL exposes the full generated Telegram API through `Client.invoke()`. That surface is intentionally available, but it is not the default starting point for most application code.

Use the high-level client helpers first when they already cover what you need:

- `start()`
- `send_text()`
- `send_file()`
- `send_photo()`
- `get_history_page()`
- `on_new_message()`

Reach for `invoke()` when VTOL does not yet have a dedicated helper for a Telegram function you need.

## The Shape Of A Raw Call

You pass a generated TL function and get back a `tl.Object`.

```v
result := client.invoke(tl.HelpGetConfig{})!
println(result.qualified_name())
```

The client handles connection setup, wraps the request with the current layer metadata, and persists session state as needed.

## Matching On The Result

Because `invoke()` returns `tl.Object`, the normal pattern is a `match` on the concrete constructor.

```v
result := client.invoke(tl.HelpGetConfig{})!

match result {
	tl.Config {
		println('Telegram returned ${result.dc_options.len} DC option(s)')
	}
	else {
		return error('unexpected result type: ${result.qualified_name()}')
	}
}
```

## Combining High-Level Peer Resolution With Raw Calls

The raw API does not mean you have to abandon the higher-level helpers entirely. A common pattern is:

1. use VTOL to normalize a peer
2. feed the resulting `input_peer` into a raw TL request

```v
peer := client.resolve_peer('telegram')!

result := client.invoke(tl.MessagesGetHistory{
	peer:        peer.input_peer
	offset_id:   0
	offset_date: 0
	add_offset:  0
	limit:       10
	max_id:      0
	min_id:      0
	hash:        0
})!

println(result.qualified_name())
```

This is often the cleanest bridge between VTOL's ergonomic surface and a Telegram method that VTOL has not wrapped yet.

## Request Options

If you need per-call RPC options, use `invoke_with_options()`.

```v
import vtol.rpc

result := client.invoke_with_options(tl.HelpGetConfig{}, rpc.CallOptions{
	timeout_ms: 20_000
})!
```

You can also set `ClientConfig.default_call_options` to apply defaults across calls.

## When To Stay High-Level

Prefer the high-level API when:

- a method already exists for the task
- you want peer-like inputs instead of raw `InputPeer*`
- you want `SentMessage` instead of `tl.UpdatesType`
- you want typed `NewMessageEvent` handlers instead of raw update inspection

Those wrappers are the surface VTOL intends people to learn first.

## When `invoke()` Is The Right Tool

Use `invoke()` when:

- Telegram added a method VTOL has generated but not wrapped yet
- you need a TL flag or constructor VTOL's helper does not expose
- you are debugging behavior close to the protocol layer
- you are building a new VTOL helper and want to prototype with raw TL first

## Practical Rule

Think of `Client.invoke()` as the escape hatch, not the onboarding path. It is there so VTOL does not block you, not so every program has to start by manually wiring raw TL requests.
