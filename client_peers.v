module vtol

import tl

// cached_input_peer returns a cached input peer without performing network resolution.
pub fn (c Client) cached_input_peer(key string) ?tl.InputPeerType {
	cache_key := normalize_cache_key(key)
	if cache_key in c.peer_cache {
		return c.peer_cache[cache_key].input_peer
	}
	return none
}

// cached_peer returns a cached ResolvedPeer without performing network resolution.
pub fn (c Client) cached_peer(key string) ?ResolvedPeer {
	cache_key := normalize_cache_key(key)
	if cache_key == 'me' || cache_key == 'self' {
		return ResolvedPeer{
			key:        'me'
			username:   'me'
			peer:       tl.PeerUser{}
			input_peer: tl.InputPeerSelf{}
		}
	}
	if cache_key in c.peer_cache {
		return resolved_peer_from_cached(c.peer_cache[cache_key])
	}
	return none
}

// resolve_input_peer resolves a cache key or username into an input peer.
pub fn (mut c Client) resolve_input_peer(key string) !tl.InputPeerType {
	resolved := c.resolve_peer(key)!
	return resolved.input_peer
}

// resolve_peer_like normalizes supported peer-like inputs into a ResolvedPeer.
pub fn (mut c Client) resolve_peer_like[T](peer T) !ResolvedPeer {
	$if T is string {
		return c.resolve_peer(peer)!
	} $else $if T is ResolvedPeer {
		return peer
	} $else $if T is tl.InputPeerEmpty {
		return resolved_peer_from_input_peer(tl.InputPeerType(peer), c.peer_cache) or {
			return error('unsupported input peer')
		}
	} $else $if T is tl.InputPeerSelf {
		return resolved_peer_from_input_peer(tl.InputPeerType(peer), c.peer_cache) or {
			return error('unsupported input peer')
		}
	} $else $if T is tl.InputPeerChat {
		return resolved_peer_from_input_peer(tl.InputPeerType(peer), c.peer_cache) or {
			return error('unsupported input peer')
		}
	} $else $if T is tl.InputPeerUser {
		return resolved_peer_from_input_peer(tl.InputPeerType(peer), c.peer_cache) or {
			return error('unsupported input peer')
		}
	} $else $if T is tl.InputPeerChannel {
		return resolved_peer_from_input_peer(tl.InputPeerType(peer), c.peer_cache) or {
			return error('unsupported input peer')
		}
	} $else $if T is tl.InputPeerUserFromMessage {
		return resolved_peer_from_input_peer(tl.InputPeerType(peer), c.peer_cache) or {
			return error('unsupported input peer')
		}
	} $else $if T is tl.InputPeerChannelFromMessage {
		return resolved_peer_from_input_peer(tl.InputPeerType(peer), c.peer_cache) or {
			return error('unsupported input peer')
		}
	} $else {
		return error('unsupported peer reference')
	}
}

// resolve_peer resolves a cache key or username into a ResolvedPeer.
pub fn (mut c Client) resolve_peer(key string) !ResolvedPeer {
	cache_key := normalize_cache_key(key)
	if cached := c.cached_peer(cache_key) {
		return cached
	}
	if cache_key.contains(':') {
		return error('peer ${key} is not cached; remote resolution currently requires a username')
	}
	return c.resolve_username(cache_key)!
}

// resolve_username resolves a Telegram username and caches the result for later reuse.
pub fn (mut c Client) resolve_username(username string) !ResolvedPeer {
	normalized := normalize_username(username)
	if normalized.len == 0 {
		return error('username must not be empty')
	}
	if normalized in c.peer_cache {
		cached := c.peer_cache[normalized]
		return ResolvedPeer{
			key:        cached.key
			username:   cached.username
			peer:       cached.peer
			input_peer: cached.input_peer
		}
	}
	result := c.invoke(tl.ContactsResolveUsername{
		username: normalized
	})!
	resolved := expect_contacts_resolved_peer(result)!
	entry := resolved_peer_from_contacts(resolved)!
	c.cache_resolved_peer(entry)
	c.persist_session()!
	return entry
}

fn (mut c Client) cache_authorization(authorization tl.AuthAuthorizationType) {
	c.peer_cache['me'] = CachedPeer{
		key:        'me'
		username:   'me'
		input_peer: tl.InputPeerSelf{}
		peer:       tl.PeerUser{}
	}
	match authorization {
		tl.AuthAuthorization {
			c.cache_user_aliases(authorization.user)
		}
		else {}
	}
}

fn (mut c Client) cache_resolved_peer(peer ResolvedPeer) {
	c.peer_cache[peer.key] = CachedPeer{
		key:        peer.key
		username:   peer.username
		input_peer: peer.input_peer
		peer:       peer.peer
	}
	if peer.username.len > 0 {
		c.peer_cache[normalize_cache_key(peer.username)] = CachedPeer{
			key:        peer.key
			username:   peer.username
			input_peer: peer.input_peer
			peer:       peer.peer
		}
	}
}

fn (mut c Client) cache_dialog_entities(response tl.MessagesDialogsType) {
	users := dialog_users_from_response(response)
	chats := dialog_chats_from_response(response)
	c.cache_user_entities(users)
	c.cache_chat_entities(chats)
	for dialog in dialog_items_from_response(response) {
		peer := dialog_peer_from_dialog(dialog) or { continue }
		resolved := resolved_peer_from_page_entities(peer, users, chats) or { continue }
		c.cache_resolved_peer(resolved)
	}
}

fn (mut c Client) cache_history_entities(response tl.MessagesMessagesType) {
	c.cache_user_entities(history_users_from_response(response))
	c.cache_chat_entities(history_chats_from_response(response))
}

fn (mut c Client) cache_user_aliases(user tl.UserType) {
	match user {
		tl.User {
			if user.has_username_value {
				c.peer_cache[normalize_cache_key(user.username)] = CachedPeer{
					key:        'user:${user.id}'
					username:   normalize_username(user.username)
					input_peer: tl.InputPeerSelf{}
					peer:       tl.PeerUser{
						user_id: user.id
					}
				}
			}
		}
		else {}
	}
}

fn (mut c Client) cache_user_entities(users []tl.UserType) {
	for user in users {
		match user {
			tl.User {
				input_peer := if user.self {
					tl.InputPeerType(tl.InputPeerSelf{})
				} else if user.has_access_hash_value {
					tl.InputPeerType(tl.InputPeerUser{
						user_id:     user.id
						access_hash: user.access_hash
					})
				} else {
					continue
				}
				key := if user.self { 'me' } else { 'user:${user.id}' }
				username := if user.has_username_value {
					normalize_username(user.username)
				} else {
					''
				}
				c.cache_resolved_peer(ResolvedPeer{
					key:        key
					username:   username
					peer:       tl.PeerUser{
						user_id: user.id
					}
					input_peer: input_peer
					users:      [tl.UserType(user)]
				})
			}
			else {}
		}
	}
}

fn (mut c Client) cache_chat_entities(chats []tl.ChatType) {
	for chat in chats {
		match chat {
			tl.Chat {
				c.cache_resolved_peer(ResolvedPeer{
					key:        'chat:${chat.id}'
					peer:       tl.PeerChat{
						chat_id: chat.id
					}
					input_peer: tl.InputPeerChat{
						chat_id: chat.id
					}
					chats:      [tl.ChatType(chat)]
				})
			}
			tl.ChatForbidden {
				c.cache_resolved_peer(ResolvedPeer{
					key:        'chat:${chat.id}'
					peer:       tl.PeerChat{
						chat_id: chat.id
					}
					input_peer: tl.InputPeerChat{
						chat_id: chat.id
					}
					chats:      [tl.ChatType(chat)]
				})
			}
			tl.Channel {
				if !chat.has_access_hash_value {
					continue
				}
				c.cache_resolved_peer(ResolvedPeer{
					key:        'channel:${chat.id}'
					username:   if chat.has_username_value {
						normalize_username(chat.username)
					} else {
						''
					}
					peer:       tl.PeerChannel{
						channel_id: chat.id
					}
					input_peer: tl.InputPeerChannel{
						channel_id:  chat.id
						access_hash: chat.access_hash
					}
					chats:      [tl.ChatType(chat)]
				})
			}
			tl.ChannelForbidden {
				c.cache_resolved_peer(ResolvedPeer{
					key:        'channel:${chat.id}'
					peer:       tl.PeerChannel{
						channel_id: chat.id
					}
					input_peer: tl.InputPeerChannel{
						channel_id:  chat.id
						access_hash: chat.access_hash
					}
					chats:      [tl.ChatType(chat)]
				})
			}
			else {}
		}
	}
}

fn expect_contacts_resolved_peer(object tl.Object) !tl.ContactsResolvedPeer {
	match object {
		tl.ContactsResolvedPeer {
			return *object
		}
		else {
			return error('expected contacts.ResolvedPeer, got ${object.qualified_name()}')
		}
	}
}

fn resolved_peer_from_contacts(resolved tl.ContactsResolvedPeer) !ResolvedPeer {
	input_peer, key := input_peer_from_resolved_peer(resolved)!
	return ResolvedPeer{
		key:        key
		username:   resolved_peer_username(resolved)
		peer:       resolved.peer
		input_peer: input_peer
		users:      resolved.users.clone()
		chats:      resolved.chats.clone()
	}
}

fn resolved_peer_from_cached(cached CachedPeer) ResolvedPeer {
	return ResolvedPeer{
		key:        cached.key
		username:   cached.username
		peer:       cached.peer
		input_peer: cached.input_peer
	}
}

fn resolved_peer_from_input_peer(input_peer tl.InputPeerType, cache map[string]CachedPeer) ?ResolvedPeer {
	if cache_key := cache_key_from_input_peer(input_peer) {
		if cache_key in cache {
			return resolved_peer_from_cached(cache[cache_key])
		}
	}
	match input_peer {
		tl.InputPeerSelf {
			return ResolvedPeer{
				key:        'me'
				username:   'me'
				peer:       tl.PeerUser{}
				input_peer: tl.InputPeerSelf{}
			}
		}
		tl.InputPeerUser {
			return ResolvedPeer{
				key:        'user:${input_peer.user_id}'
				peer:       tl.PeerUser{
					user_id: input_peer.user_id
				}
				input_peer: input_peer
			}
		}
		tl.InputPeerChat {
			return ResolvedPeer{
				key:        'chat:${input_peer.chat_id}'
				peer:       tl.PeerChat{
					chat_id: input_peer.chat_id
				}
				input_peer: input_peer
			}
		}
		tl.InputPeerChannel {
			return ResolvedPeer{
				key:        'channel:${input_peer.channel_id}'
				peer:       tl.PeerChannel{
					channel_id: input_peer.channel_id
				}
				input_peer: input_peer
			}
		}
		tl.InputPeerUserFromMessage {
			return ResolvedPeer{
				key:        'user:${input_peer.user_id}'
				peer:       tl.PeerUser{
					user_id: input_peer.user_id
				}
				input_peer: input_peer
			}
		}
		tl.InputPeerChannelFromMessage {
			return ResolvedPeer{
				key:        'channel:${input_peer.channel_id}'
				peer:       tl.PeerChannel{
					channel_id: input_peer.channel_id
				}
				input_peer: input_peer
			}
		}
		else {
			return none
		}
	}
}

fn cache_key_from_input_peer(input_peer tl.InputPeerType) ?string {
	match input_peer {
		tl.InputPeerSelf {
			return 'me'
		}
		tl.InputPeerUser {
			return 'user:${input_peer.user_id}'
		}
		tl.InputPeerChat {
			return 'chat:${input_peer.chat_id}'
		}
		tl.InputPeerChannel {
			return 'channel:${input_peer.channel_id}'
		}
		tl.InputPeerUserFromMessage {
			return 'user:${input_peer.user_id}'
		}
		tl.InputPeerChannelFromMessage {
			return 'channel:${input_peer.channel_id}'
		}
		else {
			return none
		}
	}
}

fn input_peer_from_resolved_peer(resolved tl.ContactsResolvedPeer) !(tl.InputPeerType, string) {
	match resolved.peer {
		tl.PeerUser {
			user := find_user_by_id(resolved.users, resolved.peer.user_id) or {
				return error('resolved peer did not include user ${resolved.peer.user_id}')
			}
			if !user.has_access_hash_value {
				return error('resolved user ${user.id} is missing an access hash')
			}
			return tl.InputPeerUser{
				user_id:     user.id
				access_hash: user.access_hash
			}, 'user:${user.id}'
		}
		tl.PeerChat {
			return tl.InputPeerChat{
				chat_id: resolved.peer.chat_id
			}, 'chat:${resolved.peer.chat_id}'
		}
		tl.PeerChannel {
			channel := find_channel_by_id(resolved.chats, resolved.peer.channel_id) or {
				return error('resolved peer did not include channel ${resolved.peer.channel_id}')
			}
			return tl.InputPeerChannel{
				channel_id:  channel.id
				access_hash: channel.access_hash
			}, 'channel:${channel.id}'
		}
		else {
			return error('unsupported resolved peer ${resolved.peer.qualified_name()}')
		}
	}
}

fn resolved_peer_from_page_entities(peer tl.PeerType, users []tl.UserType, chats []tl.ChatType) !ResolvedPeer {
	input_peer, key := input_peer_from_peer(peer, users, chats)!
	return ResolvedPeer{
		key:        key
		username:   username_from_peer(peer, users, chats)
		peer:       peer
		input_peer: input_peer
		users:      users.clone()
		chats:      chats.clone()
	}
}

fn input_peer_from_peer(peer tl.PeerType, users []tl.UserType, chats []tl.ChatType) !(tl.InputPeerType, string) {
	match peer {
		tl.PeerUser {
			user := find_user_by_id(users, peer.user_id) or {
				return error('peer user ${peer.user_id} was not present in the page entities')
			}
			if user.self {
				return tl.InputPeerSelf{}, 'me'
			}
			if !user.has_access_hash_value {
				return error('peer user ${user.id} is missing an access hash')
			}
			return tl.InputPeerUser{
				user_id:     user.id
				access_hash: user.access_hash
			}, 'user:${user.id}'
		}
		tl.PeerChat {
			return tl.InputPeerChat{
				chat_id: peer.chat_id
			}, 'chat:${peer.chat_id}'
		}
		tl.PeerChannel {
			channel := find_channel_by_id(chats, peer.channel_id) or {
				return error('peer channel ${peer.channel_id} was not present in the page entities')
			}
			return tl.InputPeerChannel{
				channel_id:  channel.id
				access_hash: channel.access_hash
			}, 'channel:${channel.id}'
		}
		else {
			return error('unsupported peer type ${peer.qualified_name()}')
		}
	}
}

fn username_from_peer(peer tl.PeerType, users []tl.UserType, chats []tl.ChatType) string {
	match peer {
		tl.PeerUser {
			if user := find_user_by_id(users, peer.user_id) {
				if user.has_username_value {
					return normalize_username(user.username)
				}
			}
		}
		tl.PeerChannel {
			if channel := find_channel_by_id(chats, peer.channel_id) {
				if channel.username.len > 0 {
					return normalize_username(channel.username)
				}
			}
		}
		else {}
	}
	return ''
}

fn resolved_peer_username(resolved tl.ContactsResolvedPeer) string {
	match resolved.peer {
		tl.PeerUser {
			if user := find_user_by_id(resolved.users, resolved.peer.user_id) {
				if user.has_username_value {
					return normalize_username(user.username)
				}
			}
		}
		tl.PeerChannel {
			if channel := find_channel_by_id(resolved.chats, resolved.peer.channel_id) {
				if channel.username.len > 0 {
					return normalize_username(channel.username)
				}
			}
		}
		else {}
	}
	return ''
}

fn find_user_by_id(users []tl.UserType, user_id i64) ?tl.User {
	for user in users {
		match user {
			tl.User {
				if user.id == user_id {
					return *user
				}
			}
			else {}
		}
	}
	return none
}

fn find_channel_by_id(chats []tl.ChatType, channel_id i64) ?ChannelHandle {
	for chat in chats {
		match chat {
			tl.Channel {
				if chat.id == channel_id {
					if !chat.has_access_hash_value {
						return none
					}
					return ChannelHandle{
						id:          chat.id
						access_hash: chat.access_hash
						username:    if chat.has_username_value { chat.username } else { '' }
					}
				}
			}
			tl.ChannelForbidden {
				if chat.id == channel_id {
					return ChannelHandle{
						id:          chat.id
						access_hash: chat.access_hash
					}
				}
			}
			else {}
		}
	}
	return none
}

fn normalize_username(value string) string {
	mut normalized := value.trim_space()
	if normalized.starts_with('@') {
		normalized = normalized[1..]
	}
	return normalized.to_lower()
}

fn normalize_cache_key(value string) string {
	if value.contains(':') {
		return value.to_lower()
	}
	return normalize_username(value)
}
