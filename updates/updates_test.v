module updates

import rpc
import tl

struct FakeSource {
mut:
	responses []tl.Object
	calls     []string
}

fn (mut s FakeSource) invoke(function tl.Function, options rpc.CallOptions) !tl.Object {
	s.calls << function.method_name()
	if s.responses.len == 0 {
		return error('no fake response queued for ${function.method_name()}')
	}
	response := s.responses[0]
	s.responses = s.responses[1..].clone()
	return response
}

fn test_manager_bootstrap_and_ignore_duplicate_short_update() {
	mut source := FakeSource{
		responses: [
			tl.Object(tl.UpdatesState{
				pts:          0
				qts:          0
				date:         100
				seq:          0
				unread_count: 0
			}),
		]
	}
	mut manager := new_manager(ManagerConfig{})
	subscription := manager.subscribe(SubscriptionConfig{
		buffer_size: 2
	}) or { panic(err) }

	manager.ingest(tl.UpdatesType(tl.UpdateShortSentMessage{
		id:              10
		pts:             1
		pts_count:       1
		date:            101
		media:           tl.UnknownMessageMediaType{}
		has_media_value: false
	}), mut source) or { panic(err) }
	manager.ingest(tl.UpdatesType(tl.UpdateShortSentMessage{
		id:              10
		pts:             1
		pts_count:       1
		date:            101
		media:           tl.UnknownMessageMediaType{}
		has_media_value: false
	}), mut source) or { panic(err) }

	first := receive_event(subscription) or { panic(err) }
	assert first.kind == .live
	assert source.calls == ['updates.getState']
	assert receive_event(subscription) == none

	if state := manager.current_state() {
		assert state.pts == 1
		assert state.date == 101
	} else {
		assert false
	}
}

fn test_manager_recovers_gap_before_applying_live_update() {
	mut source := FakeSource{
		responses: [
			tl.Object(tl.UpdatesState{
				pts:          0
				qts:          0
				date:         100
				seq:          0
				unread_count: 0
			}),
			tl.Object(tl.UpdatesDifference{
				new_messages:           []tl.MessageType{}
				new_encrypted_messages: []tl.EncryptedMessageType{}
				other_updates:          []tl.UpdateType{}
				chats:                  []tl.ChatType{}
				users:                  []tl.UserType{}
				state:                  tl.UpdatesState{
					pts:          1
					qts:          0
					date:         101
					seq:          0
					unread_count: 0
				}
			}),
		]
	}
	mut manager := new_manager(ManagerConfig{})
	subscription := manager.subscribe(SubscriptionConfig{
		buffer_size: 4
	}) or { panic(err) }

	manager.ingest(tl.UpdatesType(tl.UpdateShortSentMessage{
		id:              11
		pts:             2
		pts_count:       1
		date:            102
		media:           tl.UnknownMessageMediaType{}
		has_media_value: false
	}), mut source) or { panic(err) }

	recovered := receive_event(subscription) or { panic(err) }
	live := receive_event(subscription) or { panic(err) }

	assert recovered.kind == .recovered
	assert live.kind == .live
	assert source.calls == ['updates.getState', 'updates.getDifference']

	if state := manager.current_state() {
		assert state.pts == 2
		assert state.date == 102
	} else {
		assert false
	}
}

fn test_manager_tracks_qts_updates() {
	mut source := FakeSource{
		responses: [
			tl.Object(tl.UpdatesState{
				pts:          0
				qts:          0
				date:         100
				seq:          0
				unread_count: 0
			}),
		]
	}
	mut manager := new_manager(ManagerConfig{})

	manager.ingest(tl.UpdatesType(tl.UpdateShort{
		update: tl.UpdateType(tl.UpdateNewEncryptedMessage{
			message: tl.UnknownEncryptedMessageType{}
			qts:     1
		})
		date:   101
	}), mut source) or { panic(err) }

	if state := manager.current_state() {
		assert state.qts == 1
		assert state.date == 101
	} else {
		assert false
	}
}

fn test_subscription_drop_oldest_keeps_latest_event() {
	mut source := FakeSource{
		responses: [
			tl.Object(tl.UpdatesState{
				pts:          0
				qts:          0
				date:         100
				seq:          0
				unread_count: 0
			}),
		]
	}
	mut manager := new_manager(ManagerConfig{})
	subscription := manager.subscribe(SubscriptionConfig{
		buffer_size: 1
		drop_oldest: true
	}) or { panic(err) }

	manager.ingest(tl.UpdatesType(tl.UpdateShortSentMessage{
		id:              12
		pts:             1
		pts_count:       1
		date:            101
		media:           tl.UnknownMessageMediaType{}
		has_media_value: false
	}), mut source) or { panic(err) }
	manager.ingest(tl.UpdatesType(tl.UpdateShortSentMessage{
		id:              13
		pts:             2
		pts_count:       1
		date:            102
		media:           tl.UnknownMessageMediaType{}
		has_media_value: false
	}), mut source) or { panic(err) }

	event := receive_event(subscription) or { panic(err) }
	match event.batch {
		tl.UpdateShortSentMessage {
			assert event.batch.id == 13
		}
		else {
			assert false
		}
	}
	assert receive_event(subscription) == none
}

fn test_manager_accepts_channel_updates_without_global_pts_recovery() {
	mut source := FakeSource{
		responses: [
			tl.Object(tl.UpdatesState{
				pts:          100
				qts:          0
				date:         100
				seq:          1
				unread_count: 0
			}),
		]
	}
	mut manager := new_manager(ManagerConfig{})
	subscription := manager.subscribe(SubscriptionConfig{
		buffer_size: 2
	}) or { panic(err) }

	manager.ingest(tl.UpdatesType(tl.Updates{
		updates: [
			tl.UpdateType(tl.UpdateNewChannelMessage{
				message:   tl.UnknownMessageType{}
				pts:       9000
				pts_count: 1
			}),
		]
		users:   []tl.UserType{}
		chats:   []tl.ChatType{}
		date:    200
		seq:     2
	}), mut source) or { panic(err) }

	event := receive_event(subscription) or { panic(err) }
	assert event.kind == .live
	assert source.calls == ['updates.getState']

	if state := manager.current_state() {
		assert state.pts == 100
		assert state.seq == 2
		assert state.date == 200
	} else {
		assert false
	}
}

fn test_manager_ignores_channel_too_long_without_forcing_global_difference() {
	mut source := FakeSource{
		responses: [
			tl.Object(tl.UpdatesState{
				pts:          50
				qts:          0
				date:         100
				seq:          3
				unread_count: 0
			}),
		]
	}
	mut manager := new_manager(ManagerConfig{})
	subscription := manager.subscribe(SubscriptionConfig{
		buffer_size: 2
	}) or { panic(err) }

	manager.ingest(tl.UpdatesType(tl.Updates{
		updates: [
			tl.UpdateType(tl.UpdateChannelTooLong{
				channel_id: 77
				pts:        1234
			}),
		]
		users:   []tl.UserType{}
		chats:   []tl.ChatType{}
		date:    201
		seq:     4
	}), mut source) or { panic(err) }

	event := receive_event(subscription) or { panic(err) }
	assert event.kind == .live
	assert source.calls == ['updates.getState']

	if state := manager.current_state() {
		assert state.pts == 50
		assert state.seq == 4
		assert state.date == 201
	} else {
		assert false
	}
}

fn receive_event(subscription Subscription) ?Event {
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
