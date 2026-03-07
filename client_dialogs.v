module vtol

import tl

// get_dialogs fetches a single page of dialogs and returns the raw Telegram response.
pub fn (mut c Client) get_dialogs(limit int) !tl.MessagesDialogsType {
	page := c.get_dialog_page(DialogPageOptions{
		limit: limit
	})!
	return page.response
}

// get_dialog_page fetches and normalizes one page of dialogs.
pub fn (mut c Client) get_dialog_page(options DialogPageOptions) !DialogPage {
	normalized := normalize_dialog_page_options(options)
	result := c.invoke(tl.MessagesGetDialogs{
		exclude_pinned:      normalized.exclude_pinned
		folder_id:           normalized.folder_id
		has_folder_id_value: normalized.has_folder_id_value
		offset_date:         normalized.offset_date
		offset_id:           normalized.offset_id
		offset_peer:         normalized.offset_peer
		limit:               normalized.limit
		hash:                normalized.hash
	})!
	response := expect_messages_dialogs(result)!
	c.cache_dialog_entities(response)
	return dialog_page_from_response(normalized, response)!
}

// get_chats fetches chat records by numeric chat ids.
pub fn (mut c Client) get_chats(chat_ids []i64) !tl.MessagesChatsType {
	result := c.invoke(tl.MessagesGetChats{
		id: chat_ids.clone()
	})!
	return expect_messages_chats(result)!
}

// get_history fetches a single page of history and returns the raw Telegram response.
pub fn (mut c Client) get_history[T](peer T, limit int) !tl.MessagesMessagesType {
	page := c.get_history_page(peer, HistoryPageOptions{
		limit: limit
	})!
	return page.response
}

// get_history_page fetches and normalizes one page of message history.
pub fn (mut c Client) get_history_page[T](peer T, options HistoryPageOptions) !HistoryPage {
	resolved := c.resolve_peer_like(peer)!
	normalized := normalize_history_page_options(options)
	result := c.invoke(tl.MessagesGetHistory{
		peer:        resolved.input_peer
		offset_id:   normalized.offset_id
		offset_date: normalized.offset_date
		add_offset:  normalized.add_offset
		limit:       normalized.limit
		max_id:      normalized.max_id
		min_id:      normalized.min_id
		hash:        normalized.hash
	})!
	response := expect_messages_messages(result)!
	c.cache_history_entities(response)
	return history_page_from_response(normalized, response)!
}

// each_dialog_page iterates dialog pages until the callback or options stop pagination.
pub fn (mut c Client) each_dialog_page(options DialogPageOptions, callback DialogPageCallback) ! {
	base := normalize_dialog_page_options(options)
	mut current := base
	mut page_count := 0
	mut item_count := 0
	for {
		if base.max_pages > 0 && page_count >= base.max_pages {
			return
		}
		if base.max_items > 0 && item_count >= base.max_items {
			return
		}
		mut request := current
		if base.max_items > 0 {
			remaining := base.max_items - item_count
			if remaining <= 0 {
				return
			}
			if remaining < request.limit {
				request = DialogPageOptions{
					...current
					limit: remaining
				}
			}
		}
		page := c.get_dialog_page(request)!
		if page.dialogs.len == 0 {
			return
		}
		callback(page)!
		page_count++
		item_count += page.dialogs.len
		if !page.has_more {
			return
		}
		current = page.next_options
	}
}

// collect_dialogs paginates dialogs and returns a deduplicated aggregate batch.
pub fn (mut c Client) collect_dialogs(options DialogPageOptions) !DialogBatch {
	base := normalize_dialog_page_options(options)
	mut current := base
	mut page_count := 0
	mut item_count := 0
	mut batch := DialogBatch{}
	mut dialog_keys := map[string]bool{}
	mut message_keys := map[string]bool{}
	mut chat_keys := map[string]bool{}
	mut user_keys := map[string]bool{}
	for {
		if base.max_pages > 0 && page_count >= base.max_pages {
			break
		}
		if base.max_items > 0 && item_count >= base.max_items {
			break
		}
		mut request := current
		if base.max_items > 0 {
			remaining := base.max_items - item_count
			if remaining <= 0 {
				break
			}
			if remaining < request.limit {
				request = DialogPageOptions{
					...current
					limit: remaining
				}
			}
		}
		page := c.get_dialog_page(request)!
		if page.dialogs.len == 0 {
			break
		}
		batch.pages << page
		append_dialog_page_items(mut batch, page, mut dialog_keys, mut message_keys, mut
			chat_keys, mut user_keys)
		page_count++
		item_count += page.dialogs.len
		if !page.has_more {
			break
		}
		current = page.next_options
	}
	return batch
}

// each_dialog iterates dialogs one item at a time across pages.
pub fn (mut c Client) each_dialog(options DialogPageOptions, callback DialogCallback) ! {
	base := normalize_dialog_page_options(options)
	mut current := base
	mut page_count := 0
	mut item_count := 0
	for {
		if base.max_pages > 0 && page_count >= base.max_pages {
			return
		}
		if base.max_items > 0 && item_count >= base.max_items {
			return
		}
		mut request := current
		if base.max_items > 0 {
			remaining := base.max_items - item_count
			if remaining <= 0 {
				return
			}
			if remaining < request.limit {
				request = DialogPageOptions{
					...current
					limit: remaining
				}
			}
		}
		page := c.get_dialog_page(request)!
		if page.dialogs.len == 0 {
			return
		}
		for dialog in page.dialogs {
			callback(dialog)!
		}
		page_count++
		item_count += page.dialogs.len
		if !page.has_more {
			return
		}
		current = page.next_options
	}
}

// each_history_page iterates history pages until the callback or options stop pagination.
pub fn (mut c Client) each_history_page[T](peer T, options HistoryPageOptions, callback HistoryPageCallback) ! {
	base := normalize_history_page_options(options)
	mut current := base
	mut page_count := 0
	mut item_count := 0
	for {
		if base.max_pages > 0 && page_count >= base.max_pages {
			return
		}
		if base.max_items > 0 && item_count >= base.max_items {
			return
		}
		mut request := current
		if base.max_items > 0 {
			remaining := base.max_items - item_count
			if remaining <= 0 {
				return
			}
			if remaining < request.limit {
				request = HistoryPageOptions{
					...current
					limit: remaining
				}
			}
		}
		page := c.get_history_page(peer, request)!
		if page.messages.len == 0 {
			return
		}
		callback(page)!
		page_count++
		item_count += page.messages.len
		if !page.has_more {
			return
		}
		current = page.next_options
	}
}

// each_history_message iterates history messages one item at a time across pages.
pub fn (mut c Client) each_history_message[T](peer T, options HistoryPageOptions, callback HistoryMessageCallback) ! {
	base := normalize_history_page_options(options)
	mut current := base
	mut page_count := 0
	mut item_count := 0
	for {
		if base.max_pages > 0 && page_count >= base.max_pages {
			return
		}
		if base.max_items > 0 && item_count >= base.max_items {
			return
		}
		mut request := current
		if base.max_items > 0 {
			remaining := base.max_items - item_count
			if remaining <= 0 {
				return
			}
			if remaining < request.limit {
				request = HistoryPageOptions{
					...current
					limit: remaining
				}
			}
		}
		page := c.get_history_page(peer, request)!
		if page.messages.len == 0 {
			return
		}
		for message in page.messages {
			callback(message)!
		}
		page_count++
		item_count += page.messages.len
		if !page.has_more {
			return
		}
		current = page.next_options
	}
}

// collect_history paginates message history and returns a deduplicated aggregate batch.
pub fn (mut c Client) collect_history[T](peer T, options HistoryPageOptions) !HistoryBatch {
	base := normalize_history_page_options(options)
	mut current := base
	mut page_count := 0
	mut item_count := 0
	mut batch := HistoryBatch{}
	mut message_keys := map[string]bool{}
	mut topic_keys := map[string]bool{}
	mut chat_keys := map[string]bool{}
	mut user_keys := map[string]bool{}
	for {
		if base.max_pages > 0 && page_count >= base.max_pages {
			break
		}
		if base.max_items > 0 && item_count >= base.max_items {
			break
		}
		mut request := current
		if base.max_items > 0 {
			remaining := base.max_items - item_count
			if remaining <= 0 {
				break
			}
			if remaining < request.limit {
				request = HistoryPageOptions{
					...current
					limit: remaining
				}
			}
		}
		page := c.get_history_page(peer, request)!
		if page.messages.len == 0 {
			break
		}
		batch.pages << page
		append_history_page_items(mut batch, page, mut message_keys, mut topic_keys, mut
			chat_keys, mut user_keys)
		page_count++
		item_count += page.messages.len
		if !page.has_more {
			break
		}
		current = page.next_options
	}
	return batch
}

fn expect_messages_dialogs(object tl.Object) !tl.MessagesDialogsType {
	match object {
		tl.MessagesDialogs {
			return object
		}
		tl.MessagesDialogsSlice {
			return object
		}
		tl.MessagesDialogsNotModified {
			return object
		}
		else {
			return error('expected messages.Dialogs, got ${object.qualified_name()}')
		}
	}
}

fn expect_messages_chats(object tl.Object) !tl.MessagesChatsType {
	match object {
		tl.MessagesChats {
			return object
		}
		tl.MessagesChatsSlice {
			return object
		}
		else {
			return error('expected messages.Chats, got ${object.qualified_name()}')
		}
	}
}

fn expect_messages_messages(object tl.Object) !tl.MessagesMessagesType {
	match object {
		tl.MessagesMessages {
			return object
		}
		tl.MessagesMessagesSlice {
			return object
		}
		tl.MessagesChannelMessages {
			return object
		}
		tl.MessagesMessagesNotModified {
			return object
		}
		else {
			return error('expected messages.Messages, got ${object.qualified_name()}')
		}
	}
}

fn normalize_dialog_page_options(options DialogPageOptions) DialogPageOptions {
	return DialogPageOptions{
		limit:               if options.limit > 0 { options.limit } else { 50 }
		offset_date:         options.offset_date
		offset_id:           options.offset_id
		offset_peer:         options.offset_peer
		exclude_pinned:      options.exclude_pinned
		folder_id:           options.folder_id
		has_folder_id_value: options.has_folder_id_value || options.folder_id > 0
		hash:                options.hash
		max_pages:           if options.max_pages > 0 { options.max_pages } else { 0 }
		max_items:           if options.max_items > 0 { options.max_items } else { 0 }
	}
}

fn normalize_history_page_options(options HistoryPageOptions) HistoryPageOptions {
	return HistoryPageOptions{
		limit:       if options.limit > 0 { options.limit } else { 50 }
		offset_id:   options.offset_id
		offset_date: options.offset_date
		add_offset:  options.add_offset
		max_id:      options.max_id
		min_id:      options.min_id
		hash:        options.hash
		max_pages:   if options.max_pages > 0 { options.max_pages } else { 0 }
		max_items:   if options.max_items > 0 { options.max_items } else { 0 }
	}
}

fn dialog_page_from_response(options DialogPageOptions, response tl.MessagesDialogsType) !DialogPage {
	dialogs := dialog_items_from_response(response)
	messages := dialog_messages_from_response(response)
	chats := dialog_chats_from_response(response)
	users := dialog_users_from_response(response)
	mut next_options := options
	mut has_more := false
	if dialogs.len > 0 {
		last_dialog := dialogs[dialogs.len - 1]
		peer := dialog_peer_from_dialog(last_dialog)!
		offset_peer, _ := input_peer_from_peer(peer, users, chats)!
		offset_id := dialog_top_message_id(last_dialog)!
		offset_date := dialog_top_message_date(last_dialog, messages) or { 0 }
		if offset_id > 0 {
			next_options = DialogPageOptions{
				limit:               options.limit
				offset_date:         offset_date
				offset_id:           offset_id
				offset_peer:         offset_peer
				exclude_pinned:      options.exclude_pinned
				folder_id:           options.folder_id
				has_folder_id_value: options.has_folder_id_value
				hash:                options.hash
				max_pages:           options.max_pages
				max_items:           options.max_items
			}
			has_more = dialogs.len >= options.limit
		}
	}
	return DialogPage{
		response:     response
		dialogs:      dialogs
		messages:     messages
		chats:        chats
		users:        users
		total_count:  dialog_total_count(response)
		has_more:     match response {
			tl.MessagesDialogsNotModified { false }
			else { has_more }
		}
		next_options: next_options
	}
}

fn history_page_from_response(options HistoryPageOptions, response tl.MessagesMessagesType) !HistoryPage {
	messages := history_messages_from_response(response)
	mut next_options := options
	mut has_more := false
	if messages.len > 0 {
		last_id := message_type_id(messages[messages.len - 1]) or { 0 }
		last_date := message_type_date(messages[messages.len - 1]) or { 0 }
		if last_id > 0 {
			next_options = HistoryPageOptions{
				limit:       options.limit
				offset_id:   last_id
				offset_date: last_date
				add_offset:  history_offset_add(options, response)
				max_id:      options.max_id
				min_id:      options.min_id
				hash:        options.hash
				max_pages:   options.max_pages
				max_items:   options.max_items
			}
			has_more = messages.len >= options.limit
		}
	}
	return HistoryPage{
		response:     response
		messages:     messages
		topics:       history_topics_from_response(response)
		chats:        history_chats_from_response(response)
		users:        history_users_from_response(response)
		total_count:  history_total_count(response)
		has_more:     match response {
			tl.MessagesMessagesNotModified { false }
			else { has_more }
		}
		next_options: next_options
	}
}

fn dialog_total_count(response tl.MessagesDialogsType) int {
	return match response {
		tl.MessagesDialogs { response.dialogs.len }
		tl.MessagesDialogsSlice { response.count }
		tl.MessagesDialogsNotModified { response.count }
		else { 0 }
	}
}

fn history_total_count(response tl.MessagesMessagesType) int {
	return match response {
		tl.MessagesMessages { response.messages.len }
		tl.MessagesMessagesSlice { response.count }
		tl.MessagesChannelMessages { response.count }
		tl.MessagesMessagesNotModified { response.count }
		else { 0 }
	}
}

fn dialog_items_from_response(response tl.MessagesDialogsType) []tl.DialogType {
	return match response {
		tl.MessagesDialogs { response.dialogs.clone() }
		tl.MessagesDialogsSlice { response.dialogs.clone() }
		else { []tl.DialogType{} }
	}
}

fn dialog_messages_from_response(response tl.MessagesDialogsType) []tl.MessageType {
	return match response {
		tl.MessagesDialogs { response.messages.clone() }
		tl.MessagesDialogsSlice { response.messages.clone() }
		else { []tl.MessageType{} }
	}
}

fn dialog_chats_from_response(response tl.MessagesDialogsType) []tl.ChatType {
	return match response {
		tl.MessagesDialogs { response.chats.clone() }
		tl.MessagesDialogsSlice { response.chats.clone() }
		else { []tl.ChatType{} }
	}
}

fn dialog_users_from_response(response tl.MessagesDialogsType) []tl.UserType {
	return match response {
		tl.MessagesDialogs { response.users.clone() }
		tl.MessagesDialogsSlice { response.users.clone() }
		else { []tl.UserType{} }
	}
}

fn history_messages_from_response(response tl.MessagesMessagesType) []tl.MessageType {
	return match response {
		tl.MessagesMessages { response.messages.clone() }
		tl.MessagesMessagesSlice { response.messages.clone() }
		tl.MessagesChannelMessages { response.messages.clone() }
		else { []tl.MessageType{} }
	}
}

fn history_topics_from_response(response tl.MessagesMessagesType) []tl.ForumTopicType {
	return match response {
		tl.MessagesMessages { response.topics.clone() }
		tl.MessagesMessagesSlice { response.topics.clone() }
		tl.MessagesChannelMessages { response.topics.clone() }
		else { []tl.ForumTopicType{} }
	}
}

fn history_chats_from_response(response tl.MessagesMessagesType) []tl.ChatType {
	return match response {
		tl.MessagesMessages { response.chats.clone() }
		tl.MessagesMessagesSlice { response.chats.clone() }
		tl.MessagesChannelMessages { response.chats.clone() }
		else { []tl.ChatType{} }
	}
}

fn history_users_from_response(response tl.MessagesMessagesType) []tl.UserType {
	return match response {
		tl.MessagesMessages { response.users.clone() }
		tl.MessagesMessagesSlice { response.users.clone() }
		tl.MessagesChannelMessages { response.users.clone() }
		else { []tl.UserType{} }
	}
}

fn history_offset_add(options HistoryPageOptions, response tl.MessagesMessagesType) int {
	return match response {
		tl.MessagesMessagesSlice {
			if response.has_offset_id_offset_value {
				options.add_offset + response.offset_id_offset
			} else {
				options.add_offset
			}
		}
		tl.MessagesChannelMessages {
			if response.has_offset_id_offset_value {
				options.add_offset + response.offset_id_offset
			} else {
				options.add_offset
			}
		}
		else {
			options.add_offset
		}
	}
}

fn dialog_peer_from_dialog(dialog tl.DialogType) !tl.PeerType {
	match dialog {
		tl.Dialog {
			return dialog.peer
		}
		else {
			return error('unsupported dialog type ${dialog.qualified_name()}')
		}
	}
}

fn dialog_top_message_id(dialog tl.DialogType) !int {
	match dialog {
		tl.Dialog {
			return dialog.top_message
		}
		else {
			return error('unsupported dialog type ${dialog.qualified_name()}')
		}
	}
}

fn dialog_top_message_date(dialog tl.DialogType, messages []tl.MessageType) ?int {
	top_message_id := dialog_top_message_id(dialog) or { return none }
	for message in messages {
		if message_id := message_type_id(message) {
			if message_id == top_message_id {
				return message_type_date(message) or { none }
			}
		}
	}
	return none
}

fn message_type_id(message tl.MessageType) ?int {
	match message {
		tl.Message {
			return message.id
		}
		tl.MessageEmpty {
			return message.id
		}
		else {
			return none
		}
	}
}

fn message_type_date(message tl.MessageType) ?int {
	match message {
		tl.Message {
			return message.date
		}
		else {
			return none
		}
	}
}

fn dialog_identity(dialog tl.DialogType) ?string {
	peer := dialog_peer_from_dialog(dialog) or { return none }
	return peer_identity(peer)
}

fn peer_identity(peer tl.PeerType) ?string {
	match peer {
		tl.PeerUser {
			return 'user:${peer.user_id}'
		}
		tl.PeerChat {
			return 'chat:${peer.chat_id}'
		}
		tl.PeerChannel {
			return 'channel:${peer.channel_id}'
		}
		else {
			return none
		}
	}
}

fn message_identity(message tl.MessageType) ?string {
	match message {
		tl.Message {
			if peer_key := peer_identity(message.peer_id) {
				return '${peer_key}:${message.id}'
			}
			return 'message:${message.id}'
		}
		tl.MessageEmpty {
			return 'message-empty:${message.id}'
		}
		else {
			return none
		}
	}
}

fn chat_identity(chat tl.ChatType) ?string {
	match chat {
		tl.Chat {
			return 'chat:${chat.id}'
		}
		tl.ChatForbidden {
			return 'chat:${chat.id}'
		}
		tl.Channel {
			return 'channel:${chat.id}'
		}
		tl.ChannelForbidden {
			return 'channel:${chat.id}'
		}
		else {
			return none
		}
	}
}

fn user_identity(user tl.UserType) ?string {
	match user {
		tl.User {
			return 'user:${user.id}'
		}
		tl.UserEmpty {
			return 'user:${user.id}'
		}
		else {
			return none
		}
	}
}

fn topic_identity(topic tl.ForumTopicType) ?string {
	match topic {
		tl.ForumTopic {
			return 'topic:${topic.id}'
		}
		else {
			return none
		}
	}
}

fn append_dialog_page_items(mut batch DialogBatch, page DialogPage, mut dialog_keys map[string]bool, mut message_keys map[string]bool, mut chat_keys map[string]bool, mut user_keys map[string]bool) {
	for dialog in page.dialogs {
		if key := dialog_identity(dialog) {
			if key in dialog_keys {
				continue
			}
			dialog_keys[key] = true
		}
		batch.dialogs << dialog
	}
	for message in page.messages {
		if key := message_identity(message) {
			if key in message_keys {
				continue
			}
			message_keys[key] = true
		}
		batch.messages << message
	}
	for chat in page.chats {
		if key := chat_identity(chat) {
			if key in chat_keys {
				continue
			}
			chat_keys[key] = true
		}
		batch.chats << chat
	}
	for user in page.users {
		if key := user_identity(user) {
			if key in user_keys {
				continue
			}
			user_keys[key] = true
		}
		batch.users << user
	}
}

fn append_history_page_items(mut batch HistoryBatch, page HistoryPage, mut message_keys map[string]bool, mut topic_keys map[string]bool, mut chat_keys map[string]bool, mut user_keys map[string]bool) {
	for message in page.messages {
		if key := message_identity(message) {
			if key in message_keys {
				continue
			}
			message_keys[key] = true
		}
		batch.messages << message
	}
	for topic in page.topics {
		if key := topic_identity(topic) {
			if key in topic_keys {
				continue
			}
			topic_keys[key] = true
		}
		batch.topics << topic
	}
	for chat in page.chats {
		if key := chat_identity(chat) {
			if key in chat_keys {
				continue
			}
			chat_keys[key] = true
		}
		batch.chats << chat
	}
	for user in page.users {
		if key := user_identity(user) {
			if key in user_keys {
				continue
			}
			user_keys[key] = true
		}
		batch.users << user
	}
}
