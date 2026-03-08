module vtol

import tl

struct SentMessageData {
	id                 int
	text               string
	date               int
	outgoing           bool
	message            tl.MessageType = tl.UnknownMessageType{}
	has_message_value  bool
	media              tl.MessageMediaType = tl.UnknownMessageMediaType{}
	has_media_value    bool
	entities           []tl.MessageEntityType
	has_entities_value bool
}

// sent_message_from_updates normalizes a send-method updates result into a SentMessage.
pub fn sent_message_from_updates(client &Client, peer ResolvedPeer, batch tl.UpdatesType, fallback_text string) !SentMessage {
	if short := short_sent_message_from_updates(batch, fallback_text) {
		return SentMessage{
			id:                 short.id
			peer:               peer
			text:               short.text
			date:               short.date
			outgoing:           short.outgoing
			updates:            batch
			message:            short.message
			has_message_value:  short.has_message_value
			media:              short.media
			has_media_value:    short.has_media_value
			entities:           short.entities.clone()
			has_entities_value: short.has_entities_value
			client:             unsafe { client }
		}
	}
	return error('could not normalize sent message from ${batch.qualified_name()}')
}

// respond sends a new message to the same peer as the current sent message.
pub fn (message SentMessage) respond(input RichTextInput) !SentMessage {
	if isnil(message.client) {
		return error('sent message is detached')
	}
	unsafe {
		return message.client.send_text(message.peer, input)!
	}
}

// respond_with sends a new message to the same peer with explicit send options.
pub fn (message SentMessage) respond_with(input RichTextInput, options SendOptions) !SentMessage {
	if isnil(message.client) {
		return error('sent message is detached')
	}
	unsafe {
		return message.client.send_text_with(message.peer, input, options)!
	}
}

// reply sends a reply to the current sent message.
pub fn (message SentMessage) reply(input RichTextInput) !SentMessage {
	return message.reply_with(input, SendOptions{})!
}

// reply_with sends a reply to the current sent message with explicit send options.
pub fn (message SentMessage) reply_with(input RichTextInput, options SendOptions) !SentMessage {
	if message.id <= 0 {
		return error('message id must be greater than zero')
	}
	return message.respond_with(input, SendOptions{
		...options
		reply_to_message_id:           message.id
		has_reply_to_message_id_value: true
	})!
}

// respond sends a new message to the same chat as the triggering event.
pub fn (event NewMessageEvent) respond(input RichTextInput) !SentMessage {
	return event.respond_with(input, SendOptions{})!
}

// respond_with sends a new message to the same chat with explicit send options.
pub fn (event NewMessageEvent) respond_with(input RichTextInput, options SendOptions) !SentMessage {
	if isnil(event.client) {
		return error('message event is detached')
	}
	unsafe {
		if event.chat.has_input_peer_value {
			return event.client.send_text_with(ResolvedPeer{
				key:        event.chat.key
				username:   event.chat.username
				peer:       event.chat.peer
				input_peer: event.chat.input_peer
			}, input, options)!
		}
		return event.client.send_text_with(event.chat.key, input, options)!
	}
}

// reply sends a reply to the triggering message event.
pub fn (event NewMessageEvent) reply(input RichTextInput) !SentMessage {
	return event.reply_with(input, SendOptions{})!
}

// reply_with sends a reply to the triggering message event with explicit send options.
pub fn (event NewMessageEvent) reply_with(input RichTextInput, options SendOptions) !SentMessage {
	if event.id <= 0 {
		return error('event message id must be greater than zero')
	}
	return event.respond_with(input, SendOptions{
		...options
		reply_to_message_id:           event.id
		has_reply_to_message_id_value: true
	})!
}

// first_message_from_updates returns the first message contained in an updates payload.
pub fn first_message_from_updates(batch tl.UpdatesType) ?tl.MessageType {
	messages := messages_from_updates(batch)
	if messages.len == 0 {
		return none
	}
	return messages[0]
}

// messages_from_updates extracts all message values from an updates payload.
pub fn messages_from_updates(batch tl.UpdatesType) []tl.MessageType {
	return match batch {
		tl.UpdateShort {
			if message := message_from_update(batch.update) {
				[message]
			} else {
				[]tl.MessageType{}
			}
		}
		tl.UpdatesCombined {
			collect_messages_from_update_list(batch.updates)
		}
		tl.Updates {
			collect_messages_from_update_list(batch.updates)
		}
		else {
			[]tl.MessageType{}
		}
	}
}

// message_from_update extracts the message from a single update when one exists.
pub fn message_from_update(update tl.UpdateType) ?tl.MessageType {
	match update {
		tl.UpdateNewMessage {
			return update.message
		}
		tl.UpdateNewChannelMessage {
			return update.message
		}
		else {
			return none
		}
	}
}

fn collect_messages_from_update_list(updates []tl.UpdateType) []tl.MessageType {
	mut messages := []tl.MessageType{}
	for update in updates {
		if message := message_from_update(update) {
			messages << message
		}
	}
	return messages
}

fn short_sent_message_from_updates(batch tl.UpdatesType, fallback_text string) ?SentMessageData {
	match batch {
		tl.UpdateShortSentMessage {
			return SentMessageData{
				id:                 batch.id
				text:               fallback_text
				date:               batch.date
				outgoing:           true
				media:              batch.media
				has_media_value:    batch.has_media_value
				entities:           batch.entities.clone()
				has_entities_value: batch.has_entities_value
			}
		}
		tl.UpdateShortMessage {
			return SentMessageData{
				id:                 batch.id
				text:               batch.message
				date:               batch.date
				outgoing:           batch.out
				entities:           batch.entities.clone()
				has_entities_value: batch.has_entities_value
			}
		}
		tl.UpdateShortChatMessage {
			return SentMessageData{
				id:                 batch.id
				text:               batch.message
				date:               batch.date
				outgoing:           batch.out
				entities:           batch.entities.clone()
				has_entities_value: batch.has_entities_value
			}
		}
		else {
			if message := first_message_from_updates(batch) {
				return sent_message_data_from_message(message, fallback_text)
			}
			return none
		}
	}
}

fn sent_message_data_from_message(message tl.MessageType, fallback_text string) ?SentMessageData {
	match message {
		tl.Message {
			return SentMessageData{
				id:                 message.id
				text:               if message.message.len > 0 {
					message.message
				} else {
					fallback_text
				}
				date:               message.date
				outgoing:           message.out
				message:            message
				has_message_value:  true
				media:              message.media
				has_media_value:    message.has_media_value
				entities:           message.entities.clone()
				has_entities_value: message.has_entities_value
			}
		}
		tl.MessageService {
			return SentMessageData{
				id:                message.id
				text:              fallback_text
				date:              message.date
				outgoing:          message.out
				message:           message
				has_message_value: true
			}
		}
		tl.MessageEmpty {
			return SentMessageData{
				id:                message.id
				text:              fallback_text
				message:           message
				has_message_value: true
			}
		}
		else {
			return none
		}
	}
}
