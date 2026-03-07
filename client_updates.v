module vtol

import tl
import updates

pub fn (mut c Client) sync_update_state() !updates.StateVector {
	c.connect()!
	return c.ensure_update_state()!
}

pub fn (mut c Client) subscribe_updates(config updates.SubscriptionConfig) !updates.Subscription {
	c.connect()!
	c.ensure_update_state()!
	return c.update_manager.subscribe(config)!
}

pub fn (mut c Client) apply_updates(batch tl.UpdatesType) ! {
	c.connect()!
	c.ensure_update_state()!
	mut source := RuntimeDifferenceSource{
		runtime: c.runtime
	}
	c.update_manager.ingest(batch, mut source)!
}

pub fn (mut c Client) pump_updates_once() ! {
	c.connect()!
	c.ensure_update_state()!
	c.runtime.pump_once() or {
		if !c.config.rpc_config.auto_reconnect {
			return err
		}
		c.runtime.disconnect() or {}
		c.runtime.connect()!
		mut source := RuntimeDifferenceSource{
			runtime: c.runtime
		}
		c.update_manager.recover(mut source)!
		c.persist_session()!
		return
	}
	for batch in c.runtime.drain_updates() {
		mut source := RuntimeDifferenceSource{
			runtime: c.runtime
		}
		c.update_manager.ingest(batch, mut source)!
	}
	c.persist_session()!
}

fn (mut c Client) ensure_update_state() !updates.StateVector {
	if state := c.update_manager.current_state() {
		return state
	}
	mut source := RuntimeDifferenceSource{
		runtime: c.runtime
	}
	return c.update_manager.bootstrap(mut source)!
}
