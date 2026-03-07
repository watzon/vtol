#!/usr/bin/env -S v run

import internal
import os

fn main() {
	repo_root := os.real_path(os.join_path(os.dir(@FILE), '..'))
	schema_dir := os.join_path(repo_root, 'tl', 'schema')
	tl_dir := os.join_path(repo_root, 'tl')
	summary := internal.verify_generated_tl_module(schema_dir, tl_dir) or { panic(err) }
	println('Verified TL checkout for layer ${summary.layer}')
	println('Constructors: ${summary.constructor_count}')
	println('Functions: ${summary.function_count}')
}
