#!/usr/bin/env -S v run

import internal
import os

fn main() {
	repo_root := os.real_path(os.join_path(os.dir(@FILE), '..'))
	schema_dir := os.join_path(repo_root, 'tl', 'schema')
	target := os.join_path(repo_root, 'tl')
	summary := internal.generate_tl_module(schema_dir, target) or { panic(err) }
	println('Generated TL module for layer ${summary.layer}')
	println('Constructors: ${summary.constructor_count}')
	println('Functions: ${summary.function_count}')
	println('Output dir: ${target}')
}
