# send_message

The client keeps the high-level API thin over generated TL methods while still handling peer resolution and caching.

```v
import tl
import vtol

mut client := vtol.new_client(vtol.ClientConfig{
	app_id:   12345
	app_hash: 'your-app-hash'
	dc_options: [
		vtol.DcOption{
			id:   2
			host: '149.154.167.50'
			port: 443
		},
	]
}) or {
	panic(err)
}

client.connect() or { panic(err) }
defer {
	client.disconnect() or {}
}

peer := client.resolve_input_peer('telegram') or { panic(err) }
updates := client.send_message(peer, 'hello from VTOL') or { panic(err) }

match updates {
	tl.UpdateShortSentMessage {
		println('sent message id ${updates.id}')
	}
	else {
		println('server returned ${updates.qualified_name()}')
	}
}
```

If you prefer a single call, `client.send_message_to_username('telegram', 'hello from VTOL')` uses the same cache-backed resolution path.
