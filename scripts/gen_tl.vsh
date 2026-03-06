#!/usr/bin/env -S v run

import os

fn main() {
	target := os.join_path(os.getwd(), 'tl')
	println('TL generation scaffold for VTOL')
	println('Target module: ${target}')
	println('Next step: parse normalized schema inputs and emit generated constructors, functions, and codecs.')
}
