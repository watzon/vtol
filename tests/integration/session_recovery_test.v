module integration

import os
import time
import vtol
import vtol.rpc
import vtol.tl
import vtol.updates

@[heap]
struct LiveDifferenceSource {
mut:
	client &vtol.Client
	calls  []string
}

fn (mut s LiveDifferenceSource) invoke(function tl.Function, options rpc.CallOptions) !tl.Object {
	s.calls << function.method_name()
	return s.client.invoke_with_options(function, options)!
}

fn test_live_bot_session_restore_and_update_recovery() {
	app_id := os.getenv('VTOL_TEST_API_ID')
	app_hash := os.getenv('VTOL_TEST_API_HASH')
	bot_token := os.getenv('VTOL_TEST_BOT_TOKEN')
	if app_id.len == 0 || app_hash.len == 0 || bot_token.len == 0 {
		return
	}

	temp_dir := os.join_path(os.temp_dir(), 'vtol-live-session-${time.now().unix_nano()}')
	os.mkdir_all(temp_dir) or { panic(err) }
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	session_path := os.join_path(temp_dir, 'session.sqlite')

	mut initial := vtol.new_client_with_session_file(live_client_config(app_id, app_hash),
		session_path) or { panic(err) }
	defer {
		initial.disconnect() or {}
	}

	_ = initial.login_bot(bot_token) or { panic(err) }
	_ = initial.get_me() or { panic(err) }
	live_state := initial.sync_update_state() or { panic(err) }
	assert !initial.did_restore_session()
	assert os.exists(session_path)

	initial.disconnect() or { panic(err) }

	mut restored := vtol.new_client_with_session_file(live_client_config(app_id, app_hash),
		session_path) or { panic(err) }
	defer {
		restored.disconnect() or {}
	}

	restored_state := restored.sync_update_state() or { panic(err) }
	assert restored.did_restore_session()

	me := restored.get_me() or { panic(err) }
	match me {
		tl.UsersUserFull {
			assert me.users.len > 0
		}
		else {
			assert false
		}
	}

	mut manager := updates.new_manager(updates.ManagerConfig{})
	subscription := manager.subscribe(updates.SubscriptionConfig{
		buffer_size: 1
	}) or { panic(err) }
	seeded := manager.seed(updates.StateVector{
		pts:  if restored_state.pts > 0 { restored_state.pts - 1 } else { restored_state.pts }
		qts:  if restored_state.qts > 0 { restored_state.qts - 1 } else { restored_state.qts }
		seq:  if restored_state.seq > 0 { restored_state.seq - 1 } else { restored_state.seq }
		date: if restored_state.date > 0 { restored_state.date - 1 } else { restored_state.date }
	})
	mut source := LiveDifferenceSource{
		client: &restored
	}

	manager.recover(mut source) or { panic(err) }

	assert source.calls == ['updates.getDifference']

	current := manager.current_state() or { panic('expected recovered update state') }
	assert current.pts >= seeded.pts
	assert current.qts >= seeded.qts
	assert current.date >= seeded.date
	assert current.date >= live_state.date - 1

	if event := receive_integration_event(subscription) {
		assert event.kind == .recovered
	}
}

fn live_client_config(app_id string, app_hash string) vtol.ClientConfig {
	return vtol.ClientConfig{
		app_id:     app_id.int()
		app_hash:   app_hash
		dc_options: [
			vtol.DcOption{
				id:   2
				host: os.getenv_opt('VTOL_TEST_DC_HOST') or { '149.154.167.50' }
				port: 443
			},
		]
		test_mode:  os.getenv('VTOL_TEST_MODE') == '1'
	}
}

fn receive_integration_event(subscription updates.Subscription) ?updates.Event {
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
