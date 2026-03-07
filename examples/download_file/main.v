module main

import os
import vtol.example_support
import vtol.media

const default_history_limit = 50

struct StdoutProgressReporter {}

fn (r StdoutProgressReporter) report(progress media.TransferProgress) {
	if progress.total > 0 {
		println('downloaded ${progress.transferred}/${progress.total} bytes (part ${
			progress.part_index + 1}/${progress.total_parts})')
		return
	}
	println('downloaded ${progress.transferred} bytes (part ${progress.part_index + 1}/${progress.total_parts})')
}

fn main() {
	run() or {
		eprintln('download_file: ${err}')
		exit(1)
	}
}

fn run() ! {
	session_file := example_support.session_file_from_env()
	peer_key := example_support.first_non_empty_env([
		'VTOL_EXAMPLE_PEER',
	]) or { 'me' }
	output_path := example_support.first_non_empty_env([
		'VTOL_EXAMPLE_OUTPUT',
	]) or { '' }
	history_limit := example_support.env_int([
		'VTOL_EXAMPLE_HISTORY_LIMIT',
	], default_history_limit)

	mut client := example_support.new_client_from_env(session_file)!
	defer {
		client.disconnect() or {}
	}

	client.connect()!
	example_support.require_restored_session(client, session_file)!

	peer := client.resolve_input_peer(peer_key)!
	history := client.get_history(peer, history_limit)!
	target := example_support.find_download_target(history)!
	target_path := if output_path.len > 0 { output_path } else { target.default_name }
	parent_dir := os.dir(target_path)
	if parent_dir.len > 0 && parent_dir != '.' {
		os.mkdir_all(parent_dir)!
	}

	result := client.download_file_reference(target.reference, media.DownloadOptions{
		part_size:     64 * 1024
		cdn_supported: false
		reporter:      StdoutProgressReporter{}
	})!
	if result.has_cdn_redirect {
		return error('download was redirected to a CDN; rerun with a different message or media type')
	}

	os.write_file_array(target_path, result.bytes)!
	println('wrote ${result.bytes.len} bytes to ${target_path}')
}
