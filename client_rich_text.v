module vtol

import encoding.html
import tl

pub struct RichText {
pub:
	text     string
	entities []tl.MessageEntityType
}

pub type RichTextInput = RichText | string | tl.TextWithEntities

enum RichEntityKind {
	bold
	italic
	code
	pre
	underline
	strike
	spoiler
	blockquote
	text_url
}

struct OpenRichEntity {
	kind   RichEntityKind
	marker string
	offset int
	extra  string
}

struct RichTextBuilder {
mut:
	text      string
	utf16_len int
	entities  []tl.MessageEntityType
}

struct MarkdownLink {
	text       string
	url        string
	next_index int
}

pub fn plain_text(text string) RichText {
	return RichText{
		text: text
	}
}

pub fn rich_text(text string, entities []tl.MessageEntityType) RichText {
	return RichText{
		text:     text
		entities: entities.clone()
	}
}

pub fn rich_text_from_tl(value tl.TextWithEntities) RichText {
	return RichText{
		text:     value.text
		entities: value.entities.clone()
	}
}

pub fn (value RichText) to_tl() tl.TextWithEntities {
	return tl.TextWithEntities{
		text:     value.text
		entities: value.entities.clone()
	}
}

pub fn (value RichText) has_entities() bool {
	return value.entities.len > 0
}

pub fn parse_markdown(input string) !RichText {
	mut builder := RichTextBuilder{}
	mut stack := []OpenRichEntity{}
	mut index := 0
	for index < input.len {
		if input[index] == `\\` && index + 1 < input.len {
			next_len := utf8_char_len(input[index + 1])
			builder.append_text(input[index + 1..index + 1 + next_len])
			index += 1 + next_len
			continue
		}
		if input[index..].starts_with('```') {
			if end := input.index_after('```', index + 3) {
				language, content := parse_markdown_code_fence(input[index + 3..end])
				builder.push_entity(.pre, content, language)
				index = end + 3
				continue
			}
		}
		if link := markdown_link_at(input, index) {
			builder.push_entity(.text_url, link.text, link.url)
			index = link.next_index
			continue
		}
		marker := markdown_marker_at(input, index)
		if marker.len > 0 {
			if stack.len > 0 && stack[stack.len - 1].marker == marker {
				open := stack[stack.len - 1]
				stack.delete(stack.len - 1)
				builder.close_entity(open)
				index += marker.len
				continue
			}
			if markdown_marker_has_closing(input, index + marker.len, marker) {
				stack << OpenRichEntity{
					kind:   markdown_entity_kind(marker)
					marker: marker
					offset: builder.utf16_len
				}
				index += marker.len
				continue
			}
		}
		char_len := utf8_char_len(input[index])
		builder.append_text(input[index..index + char_len])
		index += char_len
	}
	if stack.len > 0 {
		return error('unclosed markdown marker `${stack[stack.len - 1].marker}`')
	}
	return builder.finish()
}

pub fn parse_html(input string) !RichText {
	mut builder := RichTextBuilder{}
	mut stack := []OpenRichEntity{}
	mut index := 0
	for index < input.len {
		tag_start := input.index_after('<', index) or { -1 }
		if tag_start < 0 {
			builder.append_text(html.unescape(input[index..], all: true))
			break
		}
		if tag_start > index {
			builder.append_text(html.unescape(input[index..tag_start], all: true))
		}
		if input[tag_start..].starts_with('<!--') {
			tag_end := input.index_after('-->', tag_start + 4) or {
				return error('unterminated html comment')
			}
			index = tag_end + 3
			continue
		}
		tag_end := input.index_after('>', tag_start + 1) or {
			return error('unterminated html tag')
		}
		tag := input[tag_start + 1..tag_end].trim_space()
		if tag.len == 0 {
			return error('empty html tag')
		}
		index = tag_end + 1
		if tag[0] == `/` {
			marker := canonical_html_marker(tag[1..].trim_space())
			if marker.len == 0 {
				continue
			}
			if stack.len == 0 || stack[stack.len - 1].marker != marker {
				return error('unexpected closing html tag </${marker}>')
			}
			open := stack[stack.len - 1]
			stack.delete(stack.len - 1)
			builder.close_entity(open)
			continue
		}
		self_closing := tag.ends_with('/')
		tag_body := if self_closing { tag[..tag.len - 1].trim_space() } else { tag }
		tag_name := html_tag_name(tag_body)
		marker := canonical_html_marker(tag_name)
		if marker.len == 0 {
			if tag_name in ['br', 'br/'] {
				builder.append_text('\n')
				continue
			}
			if tag_name in ['p', 'div', 'span'] {
				continue
			}
			return error('unsupported html tag <${tag_name}>')
		}
		extra := html_entity_extra(tag_name, tag_body)!
		if self_closing {
			builder.push_entity(html_entity_kind(marker), '', extra)
			continue
		}
		stack << OpenRichEntity{
			kind:   html_entity_kind(marker)
			marker: marker
			offset: builder.utf16_len
			extra:  extra
		}
	}
	if stack.len > 0 {
		return error('unclosed html tag <${stack[stack.len - 1].marker}>')
	}
	return builder.finish()
}

fn rich_text_from_input(input RichTextInput) RichText {
	return match input {
		string {
			plain_text(input)
		}
		RichText {
			rich_text(input.text, input.entities)
		}
		tl.TextWithEntities {
			rich_text_from_tl(input)
		}
	}
}

fn (mut builder RichTextBuilder) append_text(value string) {
	if value.len == 0 {
		return
	}
	builder.text += value
	builder.utf16_len += utf16_code_unit_len(value)
}

fn (mut builder RichTextBuilder) push_entity(kind RichEntityKind, value string, extra string) {
	offset := builder.utf16_len
	builder.append_text(value)
	length := builder.utf16_len - offset
	if length <= 0 {
		return
	}
	builder.entities << rich_entity(kind, offset, length, extra)
}

fn (mut builder RichTextBuilder) close_entity(open OpenRichEntity) {
	length := builder.utf16_len - open.offset
	if length <= 0 {
		return
	}
	builder.entities << rich_entity(open.kind, open.offset, length, open.extra)
}

fn (builder RichTextBuilder) finish() !RichText {
	mut entities := builder.entities.clone()
	sort_message_entities(mut entities)
	return RichText{
		text:     builder.text
		entities: entities
	}
}

fn rich_entity(kind RichEntityKind, offset int, length int, extra string) tl.MessageEntityType {
	return match kind {
		.bold {
			tl.MessageEntityType(tl.MessageEntityBold{
				offset: offset
				length: length
			})
		}
		.italic {
			tl.MessageEntityType(tl.MessageEntityItalic{
				offset: offset
				length: length
			})
		}
		.code {
			tl.MessageEntityType(tl.MessageEntityCode{
				offset: offset
				length: length
			})
		}
		.pre {
			tl.MessageEntityType(tl.MessageEntityPre{
				offset:   offset
				length:   length
				language: extra
			})
		}
		.underline {
			tl.MessageEntityType(tl.MessageEntityUnderline{
				offset: offset
				length: length
			})
		}
		.strike {
			tl.MessageEntityType(tl.MessageEntityStrike{
				offset: offset
				length: length
			})
		}
		.spoiler {
			tl.MessageEntityType(tl.MessageEntitySpoiler{
				offset: offset
				length: length
			})
		}
		.blockquote {
			tl.MessageEntityType(tl.MessageEntityBlockquote{
				offset: offset
				length: length
			})
		}
		.text_url {
			tl.MessageEntityType(tl.MessageEntityTextUrl{
				offset: offset
				length: length
				url:    extra
			})
		}
	}
}

fn sort_message_entities(mut entities []tl.MessageEntityType) {
	for i in 1 .. entities.len {
		mut j := i
		for j > 0 {
			left_offset, left_length := message_entity_bounds(entities[j - 1])
			right_offset, right_length := message_entity_bounds(entities[j])
			if left_offset < right_offset {
				break
			}
			if left_offset == right_offset && left_length >= right_length {
				break
			}
			entities[j - 1], entities[j] = entities[j], entities[j - 1]
			j--
		}
	}
}

fn message_entity_bounds(entity tl.MessageEntityType) (int, int) {
	return match entity {
		tl.MessageEntityBold {
			entity.offset, entity.length
		}
		tl.MessageEntityItalic {
			entity.offset, entity.length
		}
		tl.MessageEntityCode {
			entity.offset, entity.length
		}
		tl.MessageEntityPre {
			entity.offset, entity.length
		}
		tl.MessageEntityTextUrl {
			entity.offset, entity.length
		}
		tl.MessageEntityUnderline {
			entity.offset, entity.length
		}
		tl.MessageEntityStrike {
			entity.offset, entity.length
		}
		tl.MessageEntitySpoiler {
			entity.offset, entity.length
		}
		tl.MessageEntityBlockquote {
			entity.offset, entity.length
		}
		else {
			0, 0
		}
	}
}

fn utf16_code_unit_len(value string) int {
	mut total := 0
	for codepoint in value.runes() {
		total += if u32(codepoint) > 0xffff { 2 } else { 1 }
	}
	return total
}

fn utf8_char_len(first_byte u8) int {
	if first_byte < 0x80 {
		return 1
	}
	if (first_byte & 0xe0) == 0xc0 {
		return 2
	}
	if (first_byte & 0xf0) == 0xe0 {
		return 3
	}
	if (first_byte & 0xf8) == 0xf0 {
		return 4
	}
	return 1
}

fn markdown_marker_at(input string, index int) string {
	for marker in ['```', '**', '__', '~~', '||', '`', '*', '_'] {
		if input[index..].starts_with(marker) {
			return marker
		}
	}
	return ''
}

fn markdown_marker_has_closing(input string, start int, marker string) bool {
	if start >= input.len {
		return false
	}
	return input.index_after(marker, start) != none
}

fn markdown_entity_kind(marker string) RichEntityKind {
	return match marker {
		'**', '__' { .bold }
		'*', '_' { .italic }
		'~~' { .strike }
		'||' { .spoiler }
		'`' { .code }
		'```' { .pre }
		else { .bold }
	}
}

fn parse_markdown_code_fence(raw string) (string, string) {
	newline_index := raw.index('\n') or { -1 }
	if newline_index < 0 {
		return raw.trim_space(), ''
	}
	language := raw[..newline_index].trim_space()
	content := raw[newline_index + 1..]
	return language, content
}

fn markdown_link_at(input string, index int) ?MarkdownLink {
	if !input[index..].starts_with('[') {
		return none
	}
	label_end := input.index_after('](', index + 1) or { return none }
	url_end := input.index_after(')', label_end + 2) or { return none }
	label := input[index + 1..label_end]
	url := input[label_end + 2..url_end]
	if label.len == 0 || url.len == 0 {
		return none
	}
	return MarkdownLink{
		text:       label
		url:        url
		next_index: url_end + 1
	}
}

fn html_tag_name(tag string) string {
	mut end := tag.len
	for idx, value in tag {
		if value.is_space() {
			end = idx
			break
		}
	}
	return tag[..end].trim_space().to_lower()
}

fn canonical_html_marker(tag string) string {
	return match tag.to_lower() {
		'b', 'strong' { 'bold' }
		'i', 'em' { 'italic' }
		'u' { 'underline' }
		's', 'strike', 'del' { 'strike' }
		'code' { 'code' }
		'pre' { 'pre' }
		'spoiler', 'tg-spoiler' { 'spoiler' }
		'blockquote' { 'blockquote' }
		'a' { 'text_url' }
		else { '' }
	}
}

fn html_entity_kind(marker string) RichEntityKind {
	return match marker {
		'bold' { .bold }
		'italic' { .italic }
		'underline' { .underline }
		'strike' { .strike }
		'code' { .code }
		'pre' { .pre }
		'spoiler' { .spoiler }
		'blockquote' { .blockquote }
		'text_url' { .text_url }
		else { .bold }
	}
}

fn html_entity_extra(tag_name string, tag_body string) !string {
	return match tag_name {
		'a' {
			extract_html_attribute(tag_body, 'href') or {
				return error('html link tag must include href')
			}
		}
		'pre' {
			extract_html_attribute(tag_body, 'language') or {
				extract_html_attribute(tag_body, 'lang') or { '' }
			}
		}
		else {
			''
		}
	}
}

fn extract_html_attribute(tag_body string, name string) ?string {
	lower := tag_body.to_lower()
	search := '${name.to_lower()}='
	start := lower.index(search) or { return none }
	value_start := start + search.len
	if value_start >= tag_body.len {
		return none
	}
	quote := tag_body[value_start]
	if quote == `"` || quote == `'` {
		value_end := tag_body.index_after(quote.ascii_str(), value_start + 1) or { return none }
		return html.unescape(tag_body[value_start + 1..value_end], all: true)
	}
	mut value_end := value_start
	for value_end < tag_body.len && !tag_body[value_end].is_space() {
		value_end++
	}
	return html.unescape(tag_body[value_start..value_end], all: true)
}
