module vtol

import regex
import tl
import updates

struct RawUpdateHandlerState {
	handler RawUpdateHandler = unsafe { nil }
}

struct NewMessageHandlerState {
	config            NewMessageHandlerConfig
	handler           NewMessageHandler = unsafe { nil }
	pattern_regex     regex.RE
	has_pattern_regex bool
}

struct MessageEventContext {
	kind                 updates.EventKind
	state                updates.StateVector
	batch                tl.UpdatesType = tl.UpdatesTooLong{}
	has_batch_value      bool
	difference           tl.UpdatesDifferenceType = tl.UnknownUpdatesDifferenceType{}
	has_difference_value bool
}

// on_raw_update registers a handler for raw live and recovered update payloads.
pub fn (mut c Client) on_raw_update(handler RawUpdateHandler) !int {
	c.ensure_event_subscription()!
	id := c.next_event_handler_id
	c.next_event_handler_id++
	c.raw_update_handlers[id] = RawUpdateHandlerState{
		handler: handler
	}
	return id
}

// on_new_message registers a handler for normalized new-message events.
pub fn (mut c Client) on_new_message(handler NewMessageHandler) !int {
	return c.on_new_message_with_config(NewMessageHandlerConfig{}, handler)
}

// on_new_message_with_config registers a filtered handler for normalized new-message events.
pub fn (mut c Client) on_new_message_with_config(config NewMessageHandlerConfig, handler NewMessageHandler) !int {
	c.ensure_event_subscription()!
	normalized, pattern_regex, has_pattern_regex := normalize_new_message_handler_config(config)!
	id := c.next_event_handler_id
	c.next_event_handler_id++
	c.new_message_handlers[id] = NewMessageHandlerState{
		config:            normalized
		handler:           handler
		pattern_regex:     pattern_regex
		has_pattern_regex: has_pattern_regex
	}
	return id
}

// on_new_message_pattern registers a regex-filtered new-message handler.
pub fn (mut c Client) on_new_message_pattern(pattern string, handler NewMessageHandler) !int {
	return c.on_new_message_with_config(NewMessageHandlerConfig{
		pattern: pattern
	}, handler)
}

// on_new_message_matcher registers a custom predicate-filtered new-message handler.
pub fn (mut c Client) on_new_message_matcher(matcher NewMessagePatternMatcher, handler NewMessageHandler) !int {
	return c.on_new_message_with_config(NewMessageHandlerConfig{
		pattern_matcher: matcher
	}, handler)
}

// remove_event_handler unregisters a raw or normalized event handler by id.
pub fn (mut c Client) remove_event_handler(id int) bool {
	mut removed := false
	if id in c.raw_update_handlers {
		c.raw_update_handlers.delete(id)
		removed = true
	}
	if id in c.new_message_handlers {
		c.new_message_handlers.delete(id)
		removed = true
	}
	c.maybe_teardown_event_subscription()
	return removed
}

// idle continuously pumps updates until the client disconnects.
pub fn (mut c Client) idle() ! {
	c.connect()!
	for c.is_connected() {
		c.pump_updates_once()!
	}
}

// run_until_disconnected is an alias for idle.
pub fn (mut c Client) run_until_disconnected() ! {
	c.idle()!
}

fn (mut c Client) ensure_event_subscription() ! {
	if c.has_event_subscription {
		return
	}
	c.event_subscription = c.update_manager.subscribe(updates.SubscriptionConfig{
		buffer_size: 256
	})!
	c.has_event_subscription = true
}

fn (mut c Client) maybe_teardown_event_subscription() {
	if !c.has_event_subscription {
		return
	}
	if c.raw_update_handlers.len > 0 || c.new_message_handlers.len > 0 {
		return
	}
	c.update_manager.unsubscribe(c.event_subscription.id)
	c.event_subscription = updates.Subscription{}
	c.has_event_subscription = false
}

fn (mut c Client) dispatch_pending_event_handlers() ! {
	if !c.has_event_subscription {
		return
	}
	for {
		event := receive_managed_update_event(c.event_subscription) or { break }
		c.cache_update_entities(event)
		c.dispatch_raw_update_handlers(event)!
		c.dispatch_new_message_handlers(event)!
	}
}

fn receive_managed_update_event(subscription updates.Subscription) ?updates.Event {
	select {
		event := <-subscription.events {
			return event
		}
		else {
			return none
		}
	}
	return none
}

fn (c Client) dispatch_raw_update_handlers(event updates.Event) ! {
	if c.raw_update_handlers.len == 0 {
		return
	}
	wrapped := raw_update_event_from_manager_event(event)
	for id, handler_state in c.raw_update_handlers {
		handler_state.handler(wrapped) or {
			return error('raw update handler ${id} failed: ${err}')
		}
	}
}

fn (c Client) dispatch_new_message_handlers(event updates.Event) ! {
	if c.new_message_handlers.len == 0 {
		return
	}
	items := new_message_events_from_manager_event(event, c.peer_cache, c)
	for item in items {
		for id, handler_state in c.new_message_handlers {
			if !new_message_event_matches_config(item, handler_state) {
				continue
			}
			handler_state.handler(item) or {
				return error('new message handler ${id} failed: ${err}')
			}
		}
	}
}

fn raw_update_event_from_manager_event(event updates.Event) RawUpdateEvent {
	return RawUpdateEvent{
		kind:                 event.kind
		state:                event.state
		batch:                event.batch
		has_batch_value:      event.kind == .live
		difference:           event.difference
		has_difference_value: event.kind == .recovered
	}
}

fn normalize_new_message_handler_config(config NewMessageHandlerConfig) !(NewMessageHandlerConfig, regex.RE, bool) {
	mut pattern_regex := regex.RE{}
	mut has_pattern_regex := false
	if config.pattern.len > 0 {
		pattern_regex = regex.regex_opt(config.pattern) or {
			return error('invalid new-message pattern `${config.pattern}`: ${err}')
		}
		has_pattern_regex = true
	}
	return NewMessageHandlerConfig{
		chat:            normalize_cache_key(config.chat)
		sender:          normalize_cache_key(config.sender)
		from_users:      normalize_cache_key(config.from_users)
		incoming:        config.incoming
		outgoing:        config.outgoing
		forwards:        config.forwards
		pattern:         config.pattern
		pattern_matcher: config.pattern_matcher
	}, pattern_regex, has_pattern_regex
}

fn new_message_event_matches_config(event NewMessageEvent, handler_state NewMessageHandlerState) bool {
	config := handler_state.config
	if config.chat.len > 0 && !event_peer_matches_filter(event.chat, config.chat) {
		return false
	}
	if config.sender.len > 0 {
		if !event.has_sender_value {
			return false
		}
		if !event_peer_matches_filter(event.sender, config.sender) {
			return false
		}
	}
	if config.from_users.len > 0 {
		if !event.has_sender_value {
			return false
		}
		if !event_peer_matches_filter(event.sender, config.from_users) {
			return false
		}
	}
	if config.incoming != config.outgoing {
		if config.incoming && event.outgoing {
			return false
		}
		if config.outgoing && !event.outgoing {
			return false
		}
	}
	if wanted_forward := config.forwards {
		if event.forwarded != wanted_forward {
			return false
		}
	}
	if handler_state.has_pattern_regex && !handler_state.pattern_regex.matches_string(event.text) {
		return false
	}
	if config.pattern_matcher != unsafe { nil } && !config.pattern_matcher(event) {
		return false
	}
	return true
}

fn event_peer_matches_filter(peer EventPeer, filter string) bool {
	if filter.len == 0 {
		return true
	}
	if peer.key == filter {
		return true
	}
	if peer.username.len > 0 && peer.username == filter {
		return true
	}
	if filter == 'self' && peer.key == 'me' {
		return true
	}
	return false
}

fn new_message_events_from_manager_event(event updates.Event, cache map[string]CachedPeer, client &Client) []NewMessageEvent {
	mut items := match event.kind {
		.live {
			new_message_events_from_batch(event.batch, MessageEventContext{
				kind:            event.kind
				state:           event.state
				batch:           event.batch
				has_batch_value: true
			}, cache)
		}
		.recovered {
			new_message_events_from_difference(event.difference, MessageEventContext{
				kind:                 event.kind
				state:                event.state
				difference:           event.difference
				has_difference_value: true
			}, cache)
		}
	}
	for index in 0 .. items.len {
		unsafe {
			items[index].client = client
		}
	}
	return items
}

fn new_message_events_from_batch(batch tl.UpdatesType, context MessageEventContext, cache map[string]CachedPeer) []NewMessageEvent {
	mut items := []NewMessageEvent{}
	match batch {
		tl.UpdateShortMessage {
			if item := new_message_event_from_short_message(batch, context, cache) {
				items << item
			}
		}
		tl.UpdateShortChatMessage {
			if item := new_message_event_from_short_chat_message(batch, context, cache) {
				items << item
			}
		}
		tl.UpdateShort {
			if item := new_message_event_from_update(batch.update, []tl.UserType{}, []tl.ChatType{},
				context, cache)
			{
				items << item
			}
		}
		tl.Updates {
			for update in batch.updates {
				if item := new_message_event_from_update(update, batch.users, batch.chats,
					context, cache)
				{
					items << item
				}
			}
		}
		tl.UpdatesCombined {
			for update in batch.updates {
				if item := new_message_event_from_update(update, batch.users, batch.chats,
					context, cache)
				{
					items << item
				}
			}
		}
		else {}
	}
	return items
}

fn new_message_events_from_difference(diff tl.UpdatesDifferenceType, context MessageEventContext, cache map[string]CachedPeer) []NewMessageEvent {
	mut items := []NewMessageEvent{}
	mut seen := map[string]bool{}
	match diff {
		tl.UpdatesDifference {
			for message in diff.new_messages {
				if item := new_message_event_from_full_message(message, diff.users, diff.chats,
					context, tl.UpdateType(tl.UnknownUpdateType{}), false, cache)
				{
					append_unique_new_message_event(mut items, mut seen, item)
				}
			}
			for update in diff.other_updates {
				if item := new_message_event_from_update(update, diff.users, diff.chats,
					context, cache)
				{
					append_unique_new_message_event(mut items, mut seen, item)
				}
			}
		}
		tl.UpdatesDifferenceSlice {
			for message in diff.new_messages {
				if item := new_message_event_from_full_message(message, diff.users, diff.chats,
					context, tl.UpdateType(tl.UnknownUpdateType{}), false, cache)
				{
					append_unique_new_message_event(mut items, mut seen, item)
				}
			}
			for update in diff.other_updates {
				if item := new_message_event_from_update(update, diff.users, diff.chats,
					context, cache)
				{
					append_unique_new_message_event(mut items, mut seen, item)
				}
			}
		}
		else {}
	}
	return items
}

fn append_unique_new_message_event(mut items []NewMessageEvent, mut seen map[string]bool, item NewMessageEvent) {
	identity := new_message_event_identity(item)
	if identity in seen {
		return
	}
	seen[identity] = true
	items << item
}

fn new_message_event_identity(event NewMessageEvent) string {
	if event.chat.key.len > 0 {
		return '${event.chat.key}:${event.id}'
	}
	return 'message:${event.id}:${event.date}'
}

fn new_message_event_from_update(update tl.UpdateType, users []tl.UserType, chats []tl.ChatType, context MessageEventContext, cache map[string]CachedPeer) ?NewMessageEvent {
	match update {
		tl.UpdateNewMessage {
			return new_message_event_from_full_message(update.message, users, chats, context,
				update, true, cache)
		}
		tl.UpdateNewChannelMessage {
			return new_message_event_from_full_message(update.message, users, chats, context,
				update, true, cache)
		}
		else {
			return none
		}
	}
}

fn new_message_event_from_full_message(message tl.MessageType, users []tl.UserType, chats []tl.ChatType, context MessageEventContext, update tl.UpdateType, has_update bool, cache map[string]CachedPeer) ?NewMessageEvent {
	data := sent_message_data_from_message(message, '') or { return none }
	chat, sender, has_sender := event_peers_from_message(message, users, chats, cache)
	return NewMessageEvent{
		kind:                 context.kind
		state:                context.state
		id:                   data.id
		text:                 data.text
		date:                 data.date
		outgoing:             data.outgoing
		forwarded:            message_is_forwarded(data.message)
		chat:                 chat
		sender:               sender
		has_sender_value:     has_sender
		message:              data.message
		has_message_value:    data.has_message_value
		media:                data.media
		has_media_value:      data.has_media_value
		entities:             data.entities.clone()
		has_entities_value:   data.has_entities_value
		update:               update
		has_update_value:     has_update
		batch:                context.batch
		has_batch_value:      context.has_batch_value
		difference:           context.difference
		has_difference_value: context.has_difference_value
	}
}

fn new_message_event_from_short_message(update tl.UpdateShortMessage, context MessageEventContext, cache map[string]CachedPeer) ?NewMessageEvent {
	chat := event_peer_from_peer(tl.PeerType(tl.PeerUser{
		user_id: update.user_id
	}), []tl.UserType{}, []tl.ChatType{}, cache)
	sender, has_sender := if update.out {
		event_self_peer(), true
	} else {
		chat, true
	}
	return NewMessageEvent{
		kind:                 context.kind
		state:                context.state
		id:                   update.id
		text:                 update.message
		date:                 update.date
		outgoing:             update.out
		forwarded:            update.has_fwd_from_value
		chat:                 chat
		sender:               sender
		has_sender_value:     has_sender
		entities:             update.entities.clone()
		has_entities_value:   update.has_entities_value
		batch:                context.batch
		has_batch_value:      context.has_batch_value
		difference:           context.difference
		has_difference_value: context.has_difference_value
	}
}

fn new_message_event_from_short_chat_message(update tl.UpdateShortChatMessage, context MessageEventContext, cache map[string]CachedPeer) ?NewMessageEvent {
	chat := event_peer_from_peer(tl.PeerType(tl.PeerChat{
		chat_id: update.chat_id
	}), []tl.UserType{}, []tl.ChatType{}, cache)
	sender := event_peer_from_peer(tl.PeerType(tl.PeerUser{
		user_id: update.from_id
	}), []tl.UserType{}, []tl.ChatType{}, cache)
	return NewMessageEvent{
		kind:                 context.kind
		state:                context.state
		id:                   update.id
		text:                 update.message
		date:                 update.date
		outgoing:             update.out
		forwarded:            update.has_fwd_from_value
		chat:                 chat
		sender:               sender
		has_sender_value:     true
		entities:             update.entities.clone()
		has_entities_value:   update.has_entities_value
		batch:                context.batch
		has_batch_value:      context.has_batch_value
		difference:           context.difference
		has_difference_value: context.has_difference_value
	}
}

fn message_is_forwarded(message tl.MessageType) bool {
	return match message {
		tl.Message {
			message.has_fwd_from_value
		}
		else {
			false
		}
	}
}

fn event_peers_from_message(message tl.MessageType, users []tl.UserType, chats []tl.ChatType, cache map[string]CachedPeer) (EventPeer, EventPeer, bool) {
	match message {
		tl.Message {
			chat := event_peer_from_peer(message.peer_id, users, chats, cache)
			if message.has_from_id_value {
				return chat, event_peer_from_peer(message.from_id, users, chats, cache), true
			}
			if message.out {
				return chat, event_self_peer(), true
			}
			return chat, empty_event_peer(), false
		}
		tl.MessageService {
			chat := event_peer_from_peer(message.peer_id, users, chats, cache)
			if message.has_from_id_value {
				return chat, event_peer_from_peer(message.from_id, users, chats, cache), true
			}
			if message.out {
				return chat, event_self_peer(), true
			}
			return chat, empty_event_peer(), false
		}
		else {
			return empty_event_peer(), empty_event_peer(), false
		}
	}
}

fn empty_event_peer() EventPeer {
	return EventPeer{
		peer: tl.PeerUser{}
	}
}

fn event_peer_from_resolved(resolved ResolvedPeer) EventPeer {
	return EventPeer{
		key:                  resolved.key
		username:             resolved.username
		peer:                 resolved.peer
		input_peer:           resolved.input_peer
		has_input_peer_value: true
	}
}

fn event_self_peer() EventPeer {
	return EventPeer{
		key:                  'me'
		username:             'me'
		peer:                 tl.PeerUser{}
		input_peer:           tl.InputPeerSelf{}
		has_input_peer_value: true
	}
}

fn event_peer_from_peer(peer tl.PeerType, users []tl.UserType, chats []tl.ChatType, cache map[string]CachedPeer) EventPeer {
	if resolved := resolved_peer_from_page_entities(peer, users, chats) {
		return event_peer_from_resolved(resolved)
	}
	if key := peer_identity(peer) {
		if key in cache {
			return event_peer_from_resolved(resolved_peer_from_cached(cache[key]))
		}
		match peer {
			tl.PeerChat {
				return EventPeer{
					key:                  key
					username:             username_from_peer(peer, users, chats)
					peer:                 peer
					input_peer:           tl.InputPeerChat{
						chat_id: peer.chat_id
					}
					has_input_peer_value: true
				}
			}
			else {
				return EventPeer{
					key:      key
					username: username_from_peer(peer, users, chats)
					peer:     peer
				}
			}
		}
	}
	return EventPeer{
		peer: peer
	}
}
