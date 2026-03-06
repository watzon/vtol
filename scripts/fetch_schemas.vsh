#!/usr/bin/env -S v run

import internal
import os

fn main() {
	repo_root := os.real_path(os.join_path(os.dir(@FILE), '..'))
	target := os.join_path(repo_root, 'tl', 'schema')
	snapshot := internal.fetch_telethon_schema(target) or { panic(err) }
	println('Fetched Telethon TL schema layer ${snapshot.layer}')
	println('Snapshot: ${os.join_path(target, 'snapshot.json')}')
	println('Normalized schema: ${snapshot.normalized_path}')
}
