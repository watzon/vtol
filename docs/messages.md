# Messages

VTOL's high-level message surface is built around two ideas:

- pass peer-like values instead of constructing `tl.InputPeerType` early
- get back a `SentMessage` for common send flows

If you need the raw `tl.UpdatesType`, VTOL still exposes `*_updates` variants. The normal path should start with the high-level wrappers.

## Sending Text

The default send method is `send_text()`.

```v
sent := client.send_text('me', 'hello from VTOL')!
println(sent.id)
println(sent.text)
println(sent.peer.key)
```

`send_message()` is an alias for the same flow.

## Formatting Text

VTOL uses a simple rich-text model:

- `plain_text(text)`
- `rich_text(text, entities)`
- `parse_markdown(text)`
- `parse_html(text)`

### Markdown

```v
message := vtol.parse_markdown('*bold* and `code`')!
sent := client.send_text('me', message)!
println(sent.has_entities_value)
```

### HTML

```v
message := vtol.parse_html('<b>bold</b> and <code>code</code>')!
client.send_text('me', message)!
```

If parsing fails, you can fall back to plain text:

```v
formatted := vtol.parse_markdown(input) or { vtol.plain_text(input) }
client.send_text('me', formatted)!
```

## Send Options

Use `send_text_with()` when you need common Telegram send flags without dropping into raw TL.

```v
sent := client.send_text_with('telegram', 'quiet reply', vtol.SendOptions{
	reply_to_message_id:           123
	has_reply_to_message_id_value: true
	silent:                        true
	disable_link_preview:          true
})!
```

Current stable options include:

- reply target
- silent send
- link-preview control
- scheduled send date

## What `SentMessage` Gives You

`send_text()`, `send_file()`, and `send_photo()` return `SentMessage`.

That wrapper includes:

- `id`
- `peer`
- `text`
- `date`
- `outgoing`
- extracted `message`, `media`, and `entities` when VTOL can normalize them
- the original raw `updates` payload

This lets common code stay message-oriented while still keeping the underlying Telegram result available.

## Sending Files

Use `send_file()` or `send_file_path()` for generic documents.

```v
sent := client.send_file_path('me', './report.txt', vtol.SendFileOptions{
	caption: 'daily report'
})!
println(sent.id)
```

`SendFileOptions` covers common file-send concerns such as:

- caption
- MIME type
- document attributes
- reply target
- silent send
- scheduled send
- spoiler and file/media flags where Telegram supports them

## Sending Photos

Use `send_photo()` or `send_photo_path()` for photo-specific sends.

```v
sent := client.send_photo_path('me', './photo.jpg', vtol.SendPhotoOptions{
	caption: 'hello'
	spoiler: true
})!
println(sent.id)
```

`SendPhotoOptions` covers the photo-oriented version of the same idea, including caption, spoiler, TTL, reply, silent send, and scheduling.

## When You Need Raw Send Results

If you want the exact `tl.UpdatesType` instead of `SentMessage`, use:

- `send_text_updates()`
- `send_text_updates_with()`
- `send_file_updates()`
- `send_photo_updates()`

That is useful when:

- VTOL does not yet normalize the specific part of the result you need
- you want to inspect the exact update constructors
- you are building another abstraction on top of the raw API

## Fetching Message History

VTOL's fetch helpers are page-oriented.

### One page

```v
page := client.get_history_page('me', vtol.HistoryPageOptions{
	limit: 20
})!

println(page.messages.len)
println(page.has_more)
```

`HistoryPage` gives you:

- `messages`
- `topics`
- `chats`
- `users`
- `total_count`
- `has_more`
- `next_options`

### Simple fetch

```v
history := client.get_history('me', 10)!
println(history.qualified_name())
```

`get_history()` returns the raw `tl.MessagesMessagesType`. Use it when you want the simplest fetch call and you are comfortable matching on TL variants.

### Iterate through many messages

```v
client.each_history_message('me', vtol.HistoryPageOptions{
	limit:     50
	max_pages: 3
}, fn (message tl.MessageType) ! {
	println(message.qualified_name())
})!
```

### Collect a bounded batch

```v
batch := client.collect_history('me', vtol.HistoryPageOptions{
	limit:     50
	max_pages: 5
	max_items: 200
})!

println(batch.messages.len)
```

## Recommended Mental Model

- use `send_text()` and `SentMessage` for the common path
- use `parse_markdown()` or `parse_html()` when you want formatting
- use `get_history_page()` when you want to browse history cleanly
- use raw `tl.*` unions only when the high-level surface is not enough

For that raw path, see `docs/raw-api.md`.
