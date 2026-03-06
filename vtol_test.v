module vtol

fn test_new_client_validates_required_fields() {
	_ := new_client(ClientConfig{}) or {
		assert err.msg() == 'client config app_id must be greater than zero'
		return
	}
	assert false
}

fn test_new_client_exposes_primary_dc() {
	client := new_client(ClientConfig{
		app_id:     1
		app_hash:   'test-hash'
		dc_options: [
			DcOption{
				id:   2
				host: '149.154.167.50'
				port: 443
			},
		]
	}) or { panic(err) }

	assert client.client_state() == .disconnected

	if dc := client.primary_dc() {
		assert dc.id == 2
		assert dc.port == 443
	} else {
		assert false
	}
}
