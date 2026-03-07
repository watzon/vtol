module auth

import crypto
import os
import tl
import transport

fn test_live_authorization_handshake() {
	if os.getenv('VTOL_RUN_TELEGRAM_AUTH') != '1' {
		return
	}
	mut engine := transport.new_engine(transport.EngineConfig{
		endpoints: [
			transport.Endpoint{
				id:   2
				host: '149.154.167.50'
				port: 443
			},
		]
		timeouts:  transport.Timeouts{
			connect_ms: 10_000
			read_ms:    20_000
			write_ms:   20_000
		}
	}) or { panic(err) }
	defer {
		engine.disconnect() or {}
	}

	result := authenticate(mut engine, ExchangeConfig{
		dc_id: 2
	}) or { panic(err) }

	assert result.auth_key.len == crypto.auth_key_size
	assert result.auth_key_id != 0
	assert result.session_id != 0
	assert result.layer == tl.current_layer_info().layer
}
