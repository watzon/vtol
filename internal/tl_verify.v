module internal

import os
import time

pub fn verify_generated_tl_module(schema_dir string, tl_dir string) !TlGenerationSummary {
	temp_dir := os.join_path(os.vtmp_dir(), 'vtol-tl-verify-${os.getpid()}-${time.now().unix_micro()}')
	os.mkdir_all(temp_dir)!
	defer {
		os.rmdir_all(temp_dir) or {}
	}

	summary := generate_tl_module(schema_dir, temp_dir)!
	for name in ['generated_schema_types.v', 'generated_schema_dispatch.v'] {
		expected_path := os.join_path(temp_dir, name)
		actual_path := os.join_path(tl_dir, name)
		expected := os.read_file(expected_path)!
		actual := os.read_file(actual_path)!
		if actual != expected {
			return error('${name} is out of date with ${schema_dir}; run `v run scripts/gen_tl.vsh`')
		}
	}

	return summary
}
