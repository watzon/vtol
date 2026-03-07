module updates

import rpc
import tl

pub struct StateVector {
pub mut:
	pts  i64
	qts  i64
	seq  int
	date int
}

pub struct SubscriptionConfig {
pub:
	buffer_size int = 64
	drop_oldest bool
}

pub enum EventKind {
	live
	recovered
}

pub struct Event {
pub:
	kind       EventKind                = .live
	batch      tl.UpdatesType           = tl.UpdatesTooLong{}
	difference tl.UpdatesDifferenceType = tl.UnknownUpdatesDifferenceType{}
	state      StateVector
}

pub struct Subscription {
pub:
	id     int
	events chan Event
	config SubscriptionConfig
}

pub struct ManagerConfig {
pub:
	recovery_timeout_ms int = 10_000
}

pub interface DifferenceSource {
mut:
	invoke(function tl.Function, options rpc.CallOptions) !tl.Object
}

struct SubscriptionState {
	events chan Event
	config SubscriptionConfig
}

enum StepResult {
	ignored
	applied
	gap
}

struct BatchDecision {
	ignore  bool
	recover bool
	state   StateVector
}

pub struct Manager {
pub:
	config ManagerConfig
mut:
	initialized          bool
	state                StateVector
	next_subscription_id int = 1
	subscriptions        map[int]SubscriptionState
}

pub fn new_manager(config ManagerConfig) Manager {
	return Manager{
		config:        ManagerConfig{
			recovery_timeout_ms: if config.recovery_timeout_ms > 0 {
				config.recovery_timeout_ms
			} else {
				10_000
			}
		}
		subscriptions: map[int]SubscriptionState{}
	}
}

pub fn (m Manager) is_initialized() bool {
	return m.initialized
}

pub fn (m Manager) current_state() ?StateVector {
	if !m.initialized {
		return none
	}
	return m.state
}

pub fn (mut m Manager) seed(state StateVector) StateVector {
	m.state = normalize_state_vector(state)
	m.initialized = true
	return m.state
}

pub fn (mut m Manager) bootstrap(mut source DifferenceSource) !StateVector {
	result := source.invoke(tl.UpdatesGetState{}, rpc.CallOptions{
		timeout_ms: m.config.recovery_timeout_ms
	})!
	state := state_vector_from_object(result)!
	return m.seed(state)
}

pub fn (mut m Manager) subscribe(config SubscriptionConfig) !Subscription {
	normalized := normalize_subscription_config(config)
	id := m.next_subscription_id
	m.next_subscription_id++
	events := chan Event{cap: normalized.buffer_size}
	m.subscriptions[id] = SubscriptionState{
		events: events
		config: normalized
	}
	return Subscription{
		id:     id
		events: events
		config: normalized
	}
}

pub fn (mut m Manager) unsubscribe(id int) {
	if id in m.subscriptions {
		m.subscriptions.delete(id)
	}
}

pub fn (mut m Manager) ingest(batch tl.UpdatesType, mut source DifferenceSource) ! {
	if !m.initialized {
		m.bootstrap(mut source)!
	}
	m.apply_batch(batch, mut source)!
}

pub fn (mut m Manager) recover(mut source DifferenceSource) ! {
	if !m.initialized {
		m.bootstrap(mut source)!
		return
	}
	m.recover_difference(mut source)!
}

pub fn state_vector_from_updates_state(state tl.UpdatesStateType) !StateVector {
	match state {
		tl.UpdatesState {
			return StateVector{
				pts:  state.pts
				qts:  state.qts
				seq:  state.seq
				date: state.date
			}
		}
		else {
			return error('expected updates.state, got ${state.qualified_name()}')
		}
	}
}

fn state_vector_from_object(object tl.Object) !StateVector {
	match object {
		tl.UpdatesState {
			return StateVector{
				pts:  object.pts
				qts:  object.qts
				seq:  object.seq
				date: object.date
			}
		}
		else {
			return error('expected updates.state, got ${object.qualified_name()}')
		}
	}
}

fn normalize_state_vector(state StateVector) StateVector {
	return StateVector{
		pts:  if state.pts > 0 { state.pts } else { 0 }
		qts:  if state.qts > 0 { state.qts } else { 0 }
		seq:  if state.seq > 0 { state.seq } else { 0 }
		date: if state.date > 0 { state.date } else { 0 }
	}
}

fn normalize_subscription_config(config SubscriptionConfig) SubscriptionConfig {
	return SubscriptionConfig{
		buffer_size: if config.buffer_size > 0 { config.buffer_size } else { 64 }
		drop_oldest: config.drop_oldest
	}
}

fn (mut m Manager) apply_batch(batch tl.UpdatesType, mut source DifferenceSource) ! {
	mut decision := classify_batch(m.state, batch)
	if decision.ignore {
		return
	}
	if decision.recover {
		m.recover_difference(mut source)!
		decision = classify_batch(m.state, batch)
		if decision.ignore {
			return
		}
		if decision.recover {
			return error('update gap persisted after getDifference recovery')
		}
	}
	m.state = decision.state
	m.publish(Event{
		kind:  .live
		batch: batch
		state: m.state
	})
}

fn (mut m Manager) recover_difference(mut source DifferenceSource) ! {
	for {
		result := source.invoke(build_get_difference_request(m.state), rpc.CallOptions{
			timeout_ms: m.config.recovery_timeout_ms
		})!
		match result {
			tl.UpdatesDifferenceEmpty {
				m.state = StateVector{
					pts:  m.state.pts
					qts:  m.state.qts
					seq:  result.seq
					date: result.date
				}
				return
			}
			tl.UpdatesDifference {
				m.state = state_vector_from_updates_state(result.state)!
				m.publish(Event{
					kind:       .recovered
					difference: result
					state:      m.state
				})
				return
			}
			tl.UpdatesDifferenceSlice {
				m.state = state_vector_from_updates_state(result.intermediate_state)!
				m.publish(Event{
					kind:       .recovered
					difference: result
					state:      m.state
				})
			}
			tl.UpdatesDifferenceTooLong {
				m.state.pts = result.pts
				_ = m.bootstrap(mut source)!
				return
			}
			else {
				return error('expected updates.Difference, got ${result.qualified_name()}')
			}
		}
	}
}

fn build_get_difference_request(state StateVector) tl.UpdatesGetDifference {
	return tl.UpdatesGetDifference{
		pts:                       int(state.pts)
		pts_limit:                 0
		has_pts_limit_value:       false
		pts_total_limit:           0
		has_pts_total_limit_value: false
		date:                      state.date
		qts:                       int(state.qts)
		qts_limit:                 0
		has_qts_limit_value:       false
	}
}

fn classify_batch(state StateVector, batch tl.UpdatesType) BatchDecision {
	mut next := state
	match batch {
		tl.UpdatesTooLong {
			return BatchDecision{
				recover: true
				state:   state
			}
		}
		tl.UpdateShortMessage {
			step := apply_pts_step(mut next, batch.pts, batch.pts_count, batch.date)
			return decision_from_single_step(state, next, step)
		}
		tl.UpdateShortChatMessage {
			step := apply_pts_step(mut next, batch.pts, batch.pts_count, batch.date)
			return decision_from_single_step(state, next, step)
		}
		tl.UpdateShortSentMessage {
			step := apply_pts_step(mut next, batch.pts, batch.pts_count, batch.date)
			return decision_from_single_step(state, next, step)
		}
		tl.UpdateShort {
			step := apply_update_step(mut next, batch.update)
			if step == .gap {
				return BatchDecision{
					recover: true
					state:   state
				}
			}
			if step == .ignored {
				return BatchDecision{
					ignore: true
					state:  state
				}
			}
			touch_date(mut next, batch.date)
		}
		tl.Updates {
			seq_step := apply_seq_step(mut next, batch.seq, batch.seq, batch.date)
			if seq_step == .gap {
				return BatchDecision{
					recover: true
					state:   state
				}
			}
			updates_step := apply_update_list(mut next, batch.updates)
			if updates_step == .gap {
				return BatchDecision{
					recover: true
					state:   state
				}
			}
			touch_date(mut next, batch.date)
		}
		tl.UpdatesCombined {
			seq_step := apply_seq_step(mut next, batch.seq_start, batch.seq, batch.date)
			if seq_step == .gap {
				return BatchDecision{
					recover: true
					state:   state
				}
			}
			updates_step := apply_update_list(mut next, batch.updates)
			if updates_step == .gap {
				return BatchDecision{
					recover: true
					state:   state
				}
			}
			touch_date(mut next, batch.date)
		}
		else {}
	}
	return BatchDecision{
		state: next
	}
}

fn decision_from_single_step(state StateVector, next StateVector, step StepResult) BatchDecision {
	return match step {
		.gap {
			BatchDecision{
				recover: true
				state:   state
			}
		}
		.ignored {
			BatchDecision{
				ignore: true
				state:  state
			}
		}
		else {
			BatchDecision{
				state: next
			}
		}
	}
}

fn apply_seq_step(mut state StateVector, seq_start int, seq_end int, date int) StepResult {
	if seq_end <= 0 {
		touch_date(mut state, date)
		return .ignored
	}
	if seq_end <= state.seq {
		return .ignored
	}
	expected_start := state.seq + 1
	resolved_start := if seq_start > 0 { seq_start } else { seq_end }
	if resolved_start != expected_start {
		return .gap
	}
	state.seq = seq_end
	touch_date(mut state, date)
	return .applied
}

fn apply_update_list(mut state StateVector, items []tl.UpdateType) StepResult {
	mut applied := false
	for update in items {
		step := apply_update_step(mut state, update)
		if step == .gap {
			return .gap
		}
		if step == .applied {
			applied = true
		}
	}
	return if applied { .applied } else { .ignored }
}

fn apply_update_step(mut state StateVector, update tl.UpdateType) StepResult {
	match update {
		tl.UpdateNewMessage {
			return apply_pts_step(mut state, update.pts, update.pts_count, 0)
		}
		tl.UpdateNewChannelMessage {
			return apply_pts_step(mut state, update.pts, update.pts_count, 0)
		}
		tl.UpdateEditMessage {
			return apply_pts_step(mut state, update.pts, update.pts_count, 0)
		}
		tl.UpdateEditChannelMessage {
			return apply_pts_step(mut state, update.pts, update.pts_count, 0)
		}
		tl.UpdateDeleteMessages {
			return apply_pts_step(mut state, update.pts, update.pts_count, 0)
		}
		tl.UpdateDeleteChannelMessages {
			return apply_pts_step(mut state, update.pts, update.pts_count, 0)
		}
		tl.UpdateReadHistoryInbox {
			return apply_pts_step(mut state, update.pts, update.pts_count, 0)
		}
		tl.UpdateReadHistoryOutbox {
			return apply_pts_step(mut state, update.pts, update.pts_count, 0)
		}
		tl.UpdateReadMessagesContents {
			return apply_pts_step(mut state, update.pts, update.pts_count, 0)
		}
		tl.UpdateWebPage {
			return apply_pts_step(mut state, update.pts, update.pts_count, 0)
		}
		tl.UpdatePinnedMessages {
			return apply_pts_step(mut state, update.pts, update.pts_count, 0)
		}
		tl.UpdatePinnedChannelMessages {
			return apply_pts_step(mut state, update.pts, update.pts_count, 0)
		}
		tl.UpdateFolderPeers {
			return apply_pts_step(mut state, update.pts, update.pts_count, 0)
		}
		tl.UpdateChannelTooLong {
			if update.pts > int(state.pts) {
				return .gap
			}
			return .ignored
		}
		tl.UpdateNewEncryptedMessage {
			return apply_qts_step(mut state, update.qts, 0)
		}
		tl.UpdateMessagePollVote {
			return apply_qts_step(mut state, update.qts, 0)
		}
		tl.UpdateChatParticipant {
			return apply_qts_step(mut state, update.qts, update.date)
		}
		tl.UpdateChannelParticipant {
			return apply_qts_step(mut state, update.qts, update.date)
		}
		tl.UpdateBotStopped {
			return apply_qts_step(mut state, update.qts, update.date)
		}
		tl.UpdateBotBusinessConnect {
			return apply_qts_step(mut state, update.qts, 0)
		}
		tl.UpdateBotNewBusinessMessage {
			return apply_qts_step(mut state, update.qts, 0)
		}
		tl.UpdateBotEditBusinessMessage {
			return apply_qts_step(mut state, update.qts, 0)
		}
		tl.UpdateBotDeleteBusinessMessage {
			return apply_qts_step(mut state, update.qts, 0)
		}
		tl.UpdateBotPurchasedPaidMedia {
			return apply_qts_step(mut state, update.qts, 0)
		}
		tl.UpdateBotMessageReaction {
			return apply_qts_step(mut state, update.qts, 0)
		}
		tl.UpdateBotMessageReactions {
			return apply_qts_step(mut state, update.qts, 0)
		}
		tl.UpdateBotChatBoost {
			return apply_qts_step(mut state, update.qts, 0)
		}
		tl.UpdateBotChatInviteRequester {
			return apply_qts_step(mut state, update.qts, 0)
		}
		else {
			return .ignored
		}
	}
}

fn apply_pts_step(mut state StateVector, pts int, pts_count int, date int) StepResult {
	if pts <= 0 || pts_count <= 0 {
		touch_date(mut state, date)
		return .ignored
	}
	if pts <= state.pts {
		return .ignored
	}
	expected := state.pts + pts_count
	if i64(pts) != expected {
		return .gap
	}
	state.pts = pts
	touch_date(mut state, date)
	return .applied
}

fn apply_qts_step(mut state StateVector, qts int, date int) StepResult {
	if qts <= 0 {
		touch_date(mut state, date)
		return .ignored
	}
	if qts <= state.qts {
		return .ignored
	}
	expected := state.qts + 1
	if i64(qts) != expected {
		return .gap
	}
	state.qts = qts
	touch_date(mut state, date)
	return .applied
}

fn touch_date(mut state StateVector, date int) {
	if date > state.date {
		state.date = date
	}
}

fn (mut m Manager) publish(event Event) {
	for _, subscription in m.subscriptions {
		m.publish_to_subscription(subscription, event)
	}
}

fn (mut m Manager) publish_to_subscription(subscription SubscriptionState, event Event) {
	select {
		subscription.events <- event {
			return
		}
		else {}
	}
	if !subscription.config.drop_oldest {
		return
	}
	select {
		_ := <-subscription.events {}
		else {}
	}
	select {
		subscription.events <- event {}
		else {}
	}
}
