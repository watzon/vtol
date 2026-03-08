# Updates

VTOL's update story is built for long-lived clients. The public surface gives you a typed message handler for the common path and keeps the lower-level recovery-capable update manager available underneath.

## The Common Path

For most applications, the happy path is:

1. restore or log in
2. register a handler with `on_new_message()`
3. keep the client alive with `run_until_disconnected()`, `idle()`, or your own pump loop

```v
handler_id := client.on_new_message(fn (event vtol.NewMessageEvent) ! {
	if event.text == '!ping' {
		event.reply('pong')!
	}
})!
defer {
	client.remove_event_handler(handler_id)
}

client.run_until_disconnected()!
```

`run_until_disconnected()` is an alias for `idle()`. Both connect the client and keep calling `pump_updates_once()` until the client disconnects.

## `NewMessageEvent`

The high-level handler receives `NewMessageEvent`.

Useful fields include:

- `id`
- `text`
- `date`
- `outgoing`
- `forwarded`
- `chat`
- `sender`
- `kind`
- raw `message`, `media`, `update`, `batch`, and `difference` values when available

That means you can stay in a message-oriented model most of the time without losing access to the underlying update data.

`NewMessageEvent` also exposes `reply()`, `reply_with()`, `respond()`, and `respond_with()` for the common “answer this event” flow.

## Filtering New-Message Handlers

Use `on_new_message_with_config()` when you want lightweight filtering in the client layer.

```v
handler_id := client.on_new_message_with_config(vtol.NewMessageHandlerConfig{
	chat:          'me'
	incoming:      true
	forwards:      false
	pattern:       '^/deploy(?:\\s|$)'
}, fn (event vtol.NewMessageEvent) ! {
	println('Matched: ${event.text}')
})!
```

Available filters:

- `chat`
- `sender`
- `from_users`
- `incoming`
- `outgoing`
- `forwards`
- regex `pattern`
- `pattern_matcher`

The `chat` and `sender` filters use the same normalized key rules documented in `docs/peers.md`.

`from_users` is a Telethon-style alias for sender filtering.

`forwards` is tri-state:

- unset: do not filter on forwarded status
- `true`: only forwarded messages
- `false`: only non-forwarded messages

If you only need regex or predicate matching, VTOL also exposes convenience helpers:

```v
_ = client.on_new_message_pattern('[Hh]ello', fn (event vtol.NewMessageEvent) ! {
	println('regex match: ${event.text}')
})!

_ = client.on_new_message_matcher(fn (event vtol.NewMessageEvent) bool {
	return event.forwarded
}, fn (event vtol.NewMessageEvent) ! {
	println('forwarded message: ${event.text}')
})!
```

## Live vs Recovered Events

`event.kind` tells you whether the message came from:

- `.live`: the normal streaming path
- `.recovered`: a recovery pass after VTOL detected a gap and fetched differences

For many apps, you should treat both as real events. The distinction is still useful when you want different logging, metrics, or replay behavior.

## Manual Pump Loops

If you do not want to block forever in `idle()`, drive updates yourself with `pump_updates_once()`.

```v
for {
	client.pump_updates_once()!
}
```

This is the right shape when you need to integrate VTOL into your own scheduler, shutdown flow, or event loop.

## Recovery Behavior

`pump_updates_once()` is recovery-aware.

When `rpc.EngineConfig.auto_reconnect` is enabled, VTOL will:

- reconnect after a transport failure
- ask Telegram for the missing difference
- dispatch recovered events to handlers
- persist the updated session and update state

That is why handler callbacks can see both live and recovered events.

## Reading Update State

If you want the current synchronized update state:

```v
state := client.sync_update_state()!
println('pts=${state.pts} qts=${state.qts} seq=${state.seq}')
```

You can also inspect the most recently known state with:

```v
if state := client.update_state() {
	println(state.pts)
}
```

## Raw Update Handlers

Use `on_raw_update()` when you need direct access to VTOL's update batches and recovered differences.

```v
handler_id := client.on_raw_update(fn (event vtol.RawUpdateEvent) ! {
	if event.has_batch_value {
		println(event.batch.qualified_name())
	}
	if event.has_difference_value {
		println(event.difference.qualified_name())
	}
})!
```

This is the right layer when you are:

- building your own event abstraction
- debugging update behavior
- working with update constructors VTOL does not normalize yet

## Lower-Level Subscription APIs

VTOL still exposes the underlying manager-oriented APIs:

- `subscribe_updates(config)`
- `apply_updates(batch)`
- `sync_update_state()`

Use them if you want to work directly with `updates.Subscription` and `updates.Event`.

Most application code should start with `on_new_message()`.

## Recommended Mental Model

- use `on_new_message()` for bots and long-lived app code
- use `run_until_disconnected()` or `idle()` when VTOL can own the event loop
- use `pump_updates_once()` when your application owns the loop
- use `on_raw_update()` or `subscribe_updates()` when you need a lower-level integration
