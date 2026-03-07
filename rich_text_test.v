module vtol

import tl

fn assert_bold(entity tl.MessageEntityType, offset int, length int) {
	match entity {
		tl.MessageEntityBold {
			assert entity.offset == offset
			assert entity.length == length
		}
		else {
			assert false
		}
	}
}

fn assert_italic(entity tl.MessageEntityType, offset int, length int) {
	match entity {
		tl.MessageEntityItalic {
			assert entity.offset == offset
			assert entity.length == length
		}
		else {
			assert false
		}
	}
}

fn assert_code(entity tl.MessageEntityType, offset int, length int) {
	match entity {
		tl.MessageEntityCode {
			assert entity.offset == offset
			assert entity.length == length
		}
		else {
			assert false
		}
	}
}

fn assert_pre(entity tl.MessageEntityType, offset int, length int, language string) {
	match entity {
		tl.MessageEntityPre {
			assert entity.offset == offset
			assert entity.length == length
			assert entity.language == language
		}
		else {
			assert false
		}
	}
}

fn assert_text_url(entity tl.MessageEntityType, offset int, length int, url string) {
	match entity {
		tl.MessageEntityTextUrl {
			assert entity.offset == offset
			assert entity.length == length
			assert entity.url == url
		}
		else {
			assert false
		}
	}
}

fn assert_underline(entity tl.MessageEntityType, offset int, length int) {
	match entity {
		tl.MessageEntityUnderline {
			assert entity.offset == offset
			assert entity.length == length
		}
		else {
			assert false
		}
	}
}

fn assert_strike(entity tl.MessageEntityType, offset int, length int) {
	match entity {
		tl.MessageEntityStrike {
			assert entity.offset == offset
			assert entity.length == length
		}
		else {
			assert false
		}
	}
}

fn assert_spoiler(entity tl.MessageEntityType, offset int, length int) {
	match entity {
		tl.MessageEntitySpoiler {
			assert entity.offset == offset
			assert entity.length == length
		}
		else {
			assert false
		}
	}
}

fn assert_blockquote(entity tl.MessageEntityType, offset int, length int) {
	match entity {
		tl.MessageEntityBlockquote {
			assert entity.offset == offset
			assert entity.length == length
		}
		else {
			assert false
		}
	}
}

fn test_parse_markdown_builds_entities_with_utf16_offsets() {
	value := parse_markdown('😀 **bold** [link](https://example.com)') or { panic(err) }

	assert value.text == '😀 bold link'
	assert value.entities.len == 2
	assert_bold(value.entities[0], 3, 4)
	assert_text_url(value.entities[1], 8, 4, 'https://example.com')
}

fn test_parse_markdown_supports_nested_entities_and_orders_outer_before_inner() {
	value := parse_markdown('**outer _inner_**') or { panic(err) }

	assert value.text == 'outer inner'
	assert value.entities.len == 2
	assert_bold(value.entities[0], 0, 11)
	assert_italic(value.entities[1], 6, 5)
}

fn test_parse_markdown_supports_inline_code_strike_and_spoiler() {
	value := parse_markdown('`code` ~~gone~~ ||secret||') or { panic(err) }

	assert value.text == 'code gone secret'
	assert value.entities.len == 3
	assert_code(value.entities[0], 0, 4)
	assert_strike(value.entities[1], 5, 4)
	assert_spoiler(value.entities[2], 10, 6)
}

fn test_parse_markdown_supports_code_fences_with_language() {
	value := parse_markdown('```v\nprintln("hi")\n```') or { panic(err) }

	assert value.text == 'println("hi")\n'
	assert value.entities.len == 1
	assert_pre(value.entities[0], 0, 14, 'v')
}

fn test_parse_markdown_treats_escaped_markers_as_plain_text() {
	value := parse_markdown(r'\*\*literal\*\* \[no-link](ignored)') or { panic(err) }

	assert value.text == '**literal** [no-link](ignored)'
	assert value.entities.len == 0
}

fn test_parse_markdown_leaves_unmatched_marker_as_plain_text() {
	value := parse_markdown('**broken') or { panic(err) }

	assert value.text == '**broken'
	assert value.entities.len == 0
}

fn test_parse_html_supports_common_inline_formatting() {
	value := parse_html('<b>Hello</b> <a href="https://example.com">world</a>') or { panic(err) }

	assert value.text == 'Hello world'
	assert value.entities.len == 2
	assert_bold(value.entities[0], 0, 5)
	assert_text_url(value.entities[1], 6, 5, 'https://example.com')
}

fn test_parse_html_supports_comments_entities_and_layout_tags() {
	value := parse_html('<div>Hello &amp; <u>world</u><!-- hidden --><br><blockquote>quote</blockquote></div>') or {
		panic(err)
	}

	assert value.text == 'Hello & world\nquote'
	assert value.entities.len == 2
	assert_underline(value.entities[0], 8, 5)
	assert_blockquote(value.entities[1], 14, 5)
}

fn test_parse_html_supports_pre_language_and_single_quoted_href() {
	value := parse_html('<pre lang="v">println(1)</pre> <a href=\'https://example.com?a=1&amp;b=2\'>go</a>') or {
		panic(err)
	}

	assert value.text == 'println(1) go'
	assert value.entities.len == 2
	assert_pre(value.entities[0], 0, 10, 'v')
	assert_text_url(value.entities[1], 11, 2, 'https://example.com?a=1&b=2')
}

fn test_parse_html_errors_on_missing_href() {
	_ = parse_html('<a>broken</a>') or {
		assert err.msg() == 'html link tag must include href'
		return
	}
	assert false
}

fn test_parse_html_errors_on_unexpected_closing_tag() {
	_ = parse_html('</b>') or {
		assert err.msg() == 'unexpected closing html tag </bold>'
		return
	}
	assert false
}

fn test_parse_html_errors_on_unsupported_tag() {
	_ = parse_html('<img src="x">') or {
		assert err.msg() == 'unsupported html tag <img>'
		return
	}
	assert false
}

fn test_parse_html_errors_on_unclosed_tag() {
	_ = parse_html('<b>broken') or {
		assert err.msg() == 'unclosed html tag <bold>'
		return
	}
	assert false
}
