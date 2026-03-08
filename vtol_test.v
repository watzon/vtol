module vtol

import session

fn test_new_client_validates_required_fields() {
	_ := new_client(ClientConfig{}) or {
		assert err.msg() == 'client config app_id must be greater than zero'
		return
	}
	assert false
}

fn test_new_client_exposes_primary_dc() {
	client := new_client(ClientConfig{
		app_id:   1
		app_hash: 'test-hash'
	}) or { panic(err) }

	assert client.client_state() == .disconnected

	if dc := client.primary_dc() {
		assert dc.id == 1
		assert dc.port == 443
	} else {
		assert false
	}
}

fn test_new_client_requires_explicit_dc_in_test_mode() {
	_ := new_client(ClientConfig{
		app_id:    1
		app_hash:  'test-hash'
		test_mode: true
	}) or {
		assert err.msg() == 'client config must define at least one dc option in test mode'
		return
	}
	assert false
}

fn test_new_client_with_string_session_restores_encoded_state() {
	mut store := session.new_string_session('') or { panic(err) }
	store.save(session.SessionData{
		state: session.SessionState{
			dc_id:           2
			dc_address:      '149.154.167.50'
			dc_port:         443
			auth_key:        []u8{len: 256, init: u8(1)}
			auth_key_id:     77
			server_salt:     55
			session_id:      99
			layer:           201
			schema_revision: 'test-layer'
			created_at:      1_700_000_000
		}
	}) or { panic(err) }

	mut client := new_client_with_string_session(ClientConfig{
		app_id:   1
		app_hash: 'test-hash'
	}, store.encoded()) or { panic(err) }

	_, restored := client.build_runtime() or { panic(err) }

	assert restored
}
