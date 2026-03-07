module vtol

import os

fn test_examples_compile() {
	for path in [
		'./examples/auth_basic',
		'./examples/send_message',
		'./examples/download_file',
		'./examples/watch_updates',
	] {
		result := os.execute('v -check ${path}')
		assert result.exit_code == 0, 'failed to compile ${path}: ${result.output}'
	}
}
