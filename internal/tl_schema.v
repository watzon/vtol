module internal

import json
import hash.crc32
import net.http
import os
import strconv

pub enum TlSection {
	types
	functions
}

pub enum TlFieldKind {
	normal
	flag_carrier
	conditional
}

pub struct TlSource {
pub:
	name         string
	download_url string
	blob_sha     string
	raw_path     string
}

pub struct TlSnapshot {
pub:
	layer           int
	schema_revision string
	normalized_path string
	sources         []TlSource
}

pub struct TlField {
pub:
	name          string
	original_name string
	tl_type       string
	kind          TlFieldKind
	flag_carrier  string
	flag_bit      int
	is_flag_bool  bool
}

pub struct TlEntry {
pub:
	name         string
	constructor  u32
	result_type  string
	section      TlSection
	fields       []TlField
	qualified_id string
}

pub struct TlDocument {
pub:
	entries []TlEntry
}

struct GitHubContent {
	name         string
	download_url string
	sha          string
}

pub fn fetch_telethon_schema(target_dir string) !TlSnapshot {
	os.mkdir_all(target_dir)!
	raw_dir := os.join_path(target_dir, 'raw')
	os.mkdir_all(raw_dir)!

	contents_url := 'https://api.github.com/repos/LonamiWebs/Telethon/contents/telethon_generator/data?ref=v1'
	response := http.get(contents_url)!
	if response.status_code != 200 {
		return error('unable to fetch Telethon schema index: HTTP ${response.status_code}')
	}
	items := json.decode([]GitHubContent, response.body)!
	mut wanted := map[string]GitHubContent{}
	for item in items {
		if item.name == 'api.tl' || item.name == 'mtproto.tl' {
			wanted[item.name] = item
		}
	}
	if wanted.len != 2 {
		return error('Telethon schema index did not contain api.tl and mtproto.tl')
	}

	ordered_names := ['mtproto.tl', 'api.tl']
	mut normalized_sources := []string{}
	mut sources := []TlSource{}
	mut layer := 0
	for name in ordered_names {
		item := wanted[name]
		download := http.get(item.download_url)!
		if download.status_code != 200 {
			return error('unable to fetch ${name}: HTTP ${download.status_code}')
		}
		raw_path := os.join_path(raw_dir, name)
		os.write_file(raw_path, download.body)!
		if name == 'api.tl' {
			layer = extract_layer(download.body)!
		}
		normalized_sources << normalize_schema_source(name.all_before('.tl'), download.body)
		sources << TlSource{
			name:         name.all_before('.tl')
			download_url: item.download_url
			blob_sha:     item.sha
			raw_path:     raw_path
		}
	}
	if layer <= 0 {
		return error('unable to determine Telegram layer from api.tl')
	}

	normalized := normalized_sources.join('\n\n')
	normalized_path := os.join_path(target_dir, 'normalized.tl')
	os.write_file(normalized_path, normalized)!

	snapshot := TlSnapshot{
		layer:           layer
		schema_revision: derive_schema_revision(layer, sources)
		normalized_path: normalized_path
		sources:         sources
	}
	snapshot_path := os.join_path(target_dir, 'snapshot.json')
	os.write_file(snapshot_path, json.encode(snapshot))!
	return snapshot
}

pub fn load_tl_snapshot(target_dir string) !TlSnapshot {
	snapshot_path := os.join_path(target_dir, 'snapshot.json')
	return json.decode(TlSnapshot, os.read_file(snapshot_path)!)!
}

pub fn parse_tl_document_from_path(path string) !TlDocument {
	return parse_tl_document(os.read_file(path)!)
}

pub fn parse_tl_document(input string) !TlDocument {
	mut entries := []TlEntry{}
	mut section := TlSection.types
	for raw_line in input.split_into_lines() {
		line := raw_line.trim_space()
		if line.len == 0 || line.starts_with('//') {
			continue
		}
		if line == '---types---' {
			section = .types
			continue
		}
		if line == '---functions---' {
			section = .functions
			continue
		}
		if !line.ends_with(';') || !line.contains(' = ') {
			continue
		}
		entry := parse_tl_entry(line[..line.len - 1], section)!
		if entry.name == 'vector' && entry.result_type == 'Vector<t>' {
			continue
		}
		entries << entry
	}
	return TlDocument{
		entries: entries
	}
}

pub fn custom_result_types(doc TlDocument) []string {
	mut seen := map[string]bool{}
	mut types := []string{}
	for entry in doc.entries {
		if entry.section != .types {
			continue
		}
		if is_builtin_tl_type(entry.result_type) {
			continue
		}
		if entry.result_type in seen {
			continue
		}
		seen[entry.result_type] = true
		types << entry.result_type
	}
	types.sort()
	return types
}

pub fn constructors_by_result_type(doc TlDocument) map[string][]TlEntry {
	mut grouped := map[string][]TlEntry{}
	for entry in doc.entries {
		if entry.section != .types || is_builtin_tl_type(entry.result_type) {
			continue
		}
		mut current := grouped[entry.result_type] or { []TlEntry{} }
		current << entry
		grouped[entry.result_type] = current
	}
	return grouped
}

fn normalize_schema_source(name string, input string) string {
	mut lines := []string{}
	lines << '// source: ${name}'
	lines << '---types---'
	for raw_line in input.split_into_lines() {
		line := raw_line.trim_space()
		if line.len == 0 {
			continue
		}
		if line.starts_with('//') {
			continue
		}
		lines << line
	}
	return lines.join('\n')
}

fn extract_layer(input string) !int {
	for raw_line in input.split_into_lines() {
		line := raw_line.trim_space()
		if line.starts_with('// LAYER ') {
			layer := line.all_after('// LAYER ').int()
			if layer > 0 {
				return layer
			}
		}
	}
	return error('api.tl did not declare a layer comment')
}

fn derive_schema_revision(layer int, sources []TlSource) string {
	mut segments := []string{}
	for source in sources {
		segments << '${source.name}-${source.blob_sha[..8]}'
	}
	return 'telethon-v1-layer-${layer}-' + segments.join('-')
}

fn parse_tl_entry(line string, section TlSection) !TlEntry {
	parts := line.split(' = ')
	if parts.len != 2 {
		return error('invalid TL entry: ${line}')
	}
	left := parts[0]
	result_type := normalize_tl_type(parts[1])
	mut tokens := left.split(' ')
	tokens = tokens.filter(it.len > 0)
	if tokens.len == 0 {
		return error('invalid TL entry with empty left side: ${line}')
	}
	name_and_id := tokens[0]
	hash_index := name_and_id.last_index('#') or { -1 }
	mut name := name_and_id
	mut constructor := u32(0)
	mut constructor_hex := ''
	if hash_index >= 0 {
		name = name_and_id[..hash_index]
		constructor_hex = name_and_id[hash_index + 1..]
		constructor_value := strconv.parse_uint(constructor_hex, 16, 32)!
		constructor = u32(constructor_value)
	} else {
		constructor = infer_tl_constructor_id(line)
		constructor_hex = '${constructor:08x}'
	}
	mut fields := []TlField{}
	for token in tokens[1..] {
		if token.starts_with('{') && token.ends_with('}') {
			continue
		}
		if !token.contains(':') {
			continue
		}
		field_raw_name := token.all_before(':')
		field_raw_type := token.all_after(':')
		field_name := sanitize_field_name(field_raw_name)
		field_type := normalize_tl_type(field_raw_type)
		if field_type == '#' {
			fields << TlField{
				name:          field_name
				original_name: field_raw_name
				tl_type:       field_type
				kind:          .flag_carrier
			}
			continue
		}
		if field_type.contains('?') && field_type.contains('.') {
			condition := field_type.all_before('?')
			base_type := field_type.all_after('?')
			carrier := condition.all_before('.')
			bit := condition.all_after('.').int()
			fields << TlField{
				name:          field_name
				original_name: field_raw_name
				tl_type:       normalize_tl_type(base_type)
				kind:          .conditional
				flag_carrier:  carrier
				flag_bit:      bit
				is_flag_bool:  normalize_tl_type(base_type) == 'true'
			}
			continue
		}
		fields << TlField{
			name:          field_name
			original_name: field_raw_name
			tl_type:       field_type
			kind:          .normal
		}
	}
	return TlEntry{
		name:         name
		constructor:  constructor
		result_type:  result_type
		section:      section
		fields:       fields
		qualified_id: '${name}#${constructor_hex}'
	}
}

fn normalize_tl_type(input string) string {
	mut value := input.trim_space()
	if value.starts_with('!') {
		value = value[1..]
	}
	value = value.replace('vector<', 'Vector<')
	if value.starts_with('Vector ') {
		value = value.replace_once('Vector ', 'Vector<') + '>'
	}
	return value
}

fn infer_tl_constructor_id(line string) u32 {
	parts := line.split(' = ')
	if parts.len != 2 {
		return 0
	}
	left := parts[0]
	result := parts[1]
	mut tokens := left.split(' ')
	tokens = tokens.filter(it.len > 0)
	if tokens.len == 0 {
		return 0
	}
	mut representation := tokens[0]
	for token in tokens[1..] {
		if token.starts_with('{') && token.ends_with('}') {
			representation += ' ' + token[1..token.len - 1]
			continue
		}
		if token.contains(':') {
			name := token.all_before(':')
			mut typ := token.all_after(':')
			if typ.contains('?true') {
				continue
			}
			typ = typ.replace('bytes', 'string')
			typ = typ.replace('<', ' ')
			typ = typ.replace('>', '')
			representation += ' ${name}:${typ}'
			continue
		}
		representation += ' ' + token.replace('<', ' ').replace('>', '')
	}
	representation += ' = ' + result.replace('<', ' ').replace('>', '')
	return crc32.sum(representation.bytes())
}

pub fn is_builtin_tl_type(name string) bool {
	return match name {
		'int', 'long', 'double', 'string', 'bytes', 'int128', 'int256', 'Bool', 'true', 'Object',
		'X' {
			true
		}
		else {
			name.starts_with('Vector<')
		}
	}
}

pub fn sanitize_field_name(name string) string {
	mut sanitized := name.replace('.', '_')
	sanitized = snake_case(sanitized)
	if sanitized in ['as', 'asm', 'assert', 'atomic', 'break', 'chan', 'const', 'continue', 'defer',
		'else', 'enum', 'fn', 'for', 'global', 'go', 'goto', 'if', 'import', 'in', 'interface',
		'is', 'lock', 'match', 'module', 'mut', 'none', 'or', 'pub', 'return', 'rlock', 'select',
		'shared', 'sizeof', 'spawn', 'static', 'struct', 'thread', 'type', 'union', 'unsafe'] {
		return '${sanitized}_value'
	}
	return sanitized
}

pub fn pascal_case(name string) string {
	mut out := ''
	for chunk in name.replace('.', '_').split('_') {
		if chunk.len == 0 {
			continue
		}
		out += chunk[..1].to_upper() + chunk[1..]
	}
	return out
}

pub fn snake_case(name string) string {
	mut out := []u8{}
	for index, ch in name {
		if ch == `.` || ch == `-` || ch == ` ` {
			out << `_`
			continue
		}
		if ch >= `A` && ch <= `Z` {
			if index > 0 && out.len > 0 && out[out.len - 1] != `_` {
				out << `_`
			}
			out << u8(ch + 32)
			continue
		}
		out << u8(ch)
	}
	return out.bytestr()
}
