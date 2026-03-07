module internal

import os
import time

fn test_verify_generated_tl_module_accepts_checked_in_outputs() {
	root := repo_root()
	schema_dir := os.join_path(root, 'tl', 'schema')
	tl_dir := os.join_path(root, 'tl')

	summary := verify_generated_tl_module(schema_dir, tl_dir) or { panic(err) }
	snapshot := load_tl_snapshot(schema_dir) or { panic(err) }
	document := parse_tl_document_from_path(snapshot.normalized_path) or { panic(err) }

	assert summary.layer == snapshot.layer
	assert summary.constructor_count == document.entries.filter(it.section == .types).len
	assert summary.function_count == document.entries.filter(it.section == .functions).len
}

fn test_verify_generated_tl_module_rejects_stale_outputs() {
	root := repo_root()
	schema_dir := os.join_path(root, 'tl', 'schema')
	temp_tl_dir := os.join_path(os.vtmp_dir(), 'vtol-tl-stale-${os.getpid()}-${time.now().unix_micro()}')
	os.mkdir_all(temp_tl_dir) or { panic(err) }
	defer {
		os.rmdir_all(temp_tl_dir) or {}
	}

	for name in ['generated_schema_types.v', 'generated_schema_dispatch.v'] {
		source_path := os.join_path(root, 'tl', name)
		target_path := os.join_path(temp_tl_dir, name)
		os.cp(source_path, target_path) or { panic(err) }
	}
	os.write_file(os.join_path(temp_tl_dir, 'generated_schema_dispatch.v'), '// stale checkout\n') or {
		panic(err)
	}

	verify_generated_tl_module(schema_dir, temp_tl_dir) or {
		assert err.msg().contains('generated_schema_dispatch.v is out of date')
		return
	}
	assert false
}

fn repo_root() string {
	return os.real_path(os.join_path(os.dir(@FILE), '..'))
}
