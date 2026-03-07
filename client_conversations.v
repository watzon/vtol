module vtol

import tl
import updates

pub fn (mut c Client) conversation[T](peer T) !Conversation {
	c.connect()!
	c.ensure_update_state()!
	resolved := c.resolve_peer_like(peer)!
	subscription := c.update_manager.subscribe(updates.SubscriptionConfig{
		buffer_size: 256
	})!
	return Conversation{
		peer:         resolved
		client:       c
		subscription: subscription
	}
}

pub fn (conversation Conversation) is_closed() bool {
	return conversation.closed
}

pub fn (mut conversation Conversation) close() {
	if conversation.closed {
		return
	}
	if !isnil(conversation.client) {
		unsafe {
			conversation.client.update_manager.unsubscribe(conversation.subscription.id)
		}
	}
	conversation.subscription = updates.Subscription{}
	conversation.pending_messages = []NewMessageEvent{}
	conversation.closed = true
}

pub fn (mut conversation Conversation) send_text(message RichTextInput) !SentMessage {
	mut client := conversation.client_ref()!
	return client.send_text(conversation.peer, message)!
}

pub fn (mut conversation Conversation) send_message(message RichTextInput) !SentMessage {
	return conversation.send_text(message)!
}

pub fn (mut conversation Conversation) wait_for_message() !NewMessageEvent {
	mut client := conversation.client_ref()!
	for {
		conversation.buffer_pending_messages(client.peer_cache)
		if event := conversation.take_next_pending_message() {
			return event
		}
		client.pump_updates_once()!
		conversation.buffer_pending_messages(client.peer_cache)
		if event := conversation.take_next_pending_message() {
			return event
		}
		if !client.is_connected() {
			return error('client disconnected before receiving conversation message')
		}
	}
	return error('conversation wait loop terminated unexpectedly')
}

pub fn (mut conversation Conversation) wait_for_reply(message SentMessage) !NewMessageEvent {
	if message.id <= 0 {
		return error('message id must be greater than zero')
	}
	if message.peer.key != conversation.peer.key {
		return error('message peer does not match conversation peer')
	}
	mut client := conversation.client_ref()!
	for {
		conversation.buffer_pending_messages(client.peer_cache)
		if event := conversation.take_pending_reply(message.id) {
			return event
		}
		client.pump_updates_once()!
		conversation.buffer_pending_messages(client.peer_cache)
		if event := conversation.take_pending_reply(message.id) {
			return event
		}
		if !client.is_connected() {
			return error('client disconnected before receiving conversation reply')
		}
	}
	return error('conversation wait loop terminated unexpectedly')
}

fn (conversation Conversation) client_ref() !&Client {
	if conversation.closed {
		return error('conversation is closed')
	}
	if isnil(conversation.client) {
		return error('conversation is detached')
	}
	return conversation.client
}

fn (mut conversation Conversation) buffer_pending_messages(cache map[string]CachedPeer) {
	for {
		event := receive_managed_update_event(conversation.subscription) or { break }
		for item in new_message_events_from_manager_event(event, cache) {
			if !event_peer_matches_filter(item.chat, conversation.peer.key) {
				continue
			}
			conversation.pending_messages << item
		}
	}
}

fn (mut conversation Conversation) take_next_pending_message() ?NewMessageEvent {
	if conversation.pending_messages.len == 0 {
		return none
	}
	item := conversation.pending_messages[0]
	conversation.pending_messages.delete(0)
	return item
}

fn (mut conversation Conversation) take_pending_reply(message_id int) ?NewMessageEvent {
	for index, item in conversation.pending_messages {
		if item.outgoing {
			continue
		}
		reply_to_id := message_reply_to_message_id(item.message) or { continue }
		if reply_to_id != message_id {
			continue
		}
		conversation.pending_messages.delete(index)
		return item
	}
	return none
}

fn message_reply_to_message_id(message tl.MessageType) ?int {
	match message {
		tl.Message {
			if !message.has_reply_to_value {
				return none
			}
			return reply_header_message_id(message.reply_to)
		}
		tl.MessageService {
			if !message.has_reply_to_value {
				return none
			}
			return reply_header_message_id(message.reply_to)
		}
		else {
			return none
		}
	}
}

fn reply_header_message_id(reply_to tl.MessageReplyHeaderType) ?int {
	match reply_to {
		tl.MessageReplyHeader {
			if !reply_to.has_reply_to_msg_id_value {
				return none
			}
			return reply_to.reply_to_msg_id
		}
		else {
			return none
		}
	}
}
