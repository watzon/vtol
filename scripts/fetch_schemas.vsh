#!/usr/bin/env -S v run

import os

fn main() {
	target := os.join_path(os.getwd(), 'tl')
	println('Schema fetch scaffold for VTOL')
	println('Target module: ${target}')
	println('Next step: download Telegram TL definitions and snapshot the selected layer inputs.')
}
