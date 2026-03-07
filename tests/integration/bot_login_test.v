module integration

import os
import tl
import vtol

fn test_live_bot_login_and_get_me() {
	app_id := os.getenv('VTOL_TEST_API_ID')
	app_hash := os.getenv('VTOL_TEST_API_HASH')
	bot_token := os.getenv('VTOL_TEST_BOT_TOKEN')
	if app_id.len == 0 || app_hash.len == 0 || bot_token.len == 0 {
		return
	}
	mut client := vtol.new_client(vtol.ClientConfig{
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
	}) or { panic(err) }
	defer {
		client.disconnect() or {}
	}

	_ = client.login_bot(bot_token) or { panic(err) }
	me := client.get_me() or { panic(err) }

	match me {
		tl.UsersUserFull {
			assert me.users.len > 0
		}
		else {
			assert false
		}
	}
}
