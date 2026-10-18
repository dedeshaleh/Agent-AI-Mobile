extends RefCounted
class_name XLSXReader

const MAX_XML_BYTES := 20 * 1024 * 1024
const MAX_ROWS := 100001
const MAX_COLUMNS := 512

static func read_rows(path: String) -> Dictionary:
	var zip := ZIPReader.new()
	var err := zip.open(path)
	if err != OK:
		return {"ok": false, "error": "File XLSX tidak valid atau tidak bisa dibuka."}
	var parts := zip.get_files()
	if not zip.file_exists("xl/workbook.xml") or not zip.file_exists("xl/_rels/workbook.xml.rels"):
		zip.close()
		return {"ok": false, "error": "Struktur XLSX tidak lengkap. Simpan ulang sebagai .xlsx."}
	var strings_bytes := zip.read_file("xl/sharedStrings.xml") if zip.file_exists("xl/sharedStrings.xml") else PackedByteArray()
	var workbook_bytes := zip.read_file("xl/workbook.xml")
	var rels_bytes := zip.read_file("xl/_rels/workbook.xml.rels")
	if strings_bytes.size() + workbook_bytes.size() + rels_bytes.size() > MAX_XML_BYTES:
		zip.close()
		return {"ok": false, "error": "Isi XML workbook terlalu besar (batas 20 MB)."}
	var strings := _read_shared_strings(strings_bytes)
	var target := _first_sheet(workbook_bytes, rels_bytes)
	if target.is_empty() or not zip.file_exists(target):
		zip.close()
		return {"ok": false, "error": "Lembar pertama workbook tidak ditemukan."}
	var sheet_bytes := zip.read_file(target)
	var styles: Array = []
	if zip.file_exists("xl/styles.xml"):
		var style_bytes := zip.read_file("xl/styles.xml")
		if style_bytes.size() > MAX_XML_BYTES:
			zip.close()
			return {"ok": false, "error": "Format workbook terlalu besar."}
		styles = _read_date_styles(style_bytes)
	zip.close()
	if sheet_bytes.size() > MAX_XML_BYTES:
		return {"ok": false, "error": "Lembar pertama melebihi batas 20 MB."}
	return _read_sheet(sheet_bytes, strings, styles)

static func _xml(buffer: PackedByteArray) -> XMLParser:
	var parser := XMLParser.new()
	parser.open_buffer(buffer)
	return parser

static func _attributes(parser: XMLParser) -> Dictionary:
	var attrs := {}
	for i in parser.get_attribute_count():
		attrs[parser.get_attribute_name(i)] = parser.get_attribute_value(i)
	return attrs

static func _read_shared_strings(buffer: PackedByteArray) -> Array:
	var values: Array = []
	var parser := _xml(buffer)
	var inside_si := false
	var inside_t := false
	var current := ""
	while parser.read() == OK:
		var kind := parser.get_node_type()
		var name := parser.get_node_name() if kind == XMLParser.NODE_ELEMENT or kind == XMLParser.NODE_ELEMENT_END else ""
		if kind == XMLParser.NODE_ELEMENT:
			if name == "si": inside_si = true; current = ""
			elif name == "t" and inside_si: inside_t = true
		elif kind == XMLParser.NODE_TEXT and inside_t:
			current += parser.get_node_data()
		elif kind == XMLParser.NODE_ELEMENT_END:
			if name == "t": inside_t = false
			elif name == "si": values.append(current); inside_si = false
	return values

static func _first_sheet(workbook: PackedByteArray, relationships: PackedByteArray) -> String:
	var relationship_id := ""
	var parser := _xml(workbook)
	while parser.read() == OK:
		if parser.get_node_type() == XMLParser.NODE_ELEMENT and parser.get_node_name() == "sheet":
			var attrs := _attributes(parser)
			relationship_id = str(attrs.get("r:id", attrs.get("id", "")))
			break
	if relationship_id.is_empty(): return ""
	parser = _xml(relationships)
	while parser.read() == OK:
		if parser.get_node_type() != XMLParser.NODE_ELEMENT or parser.get_node_name() != "Relationship": continue
		var attrs := _attributes(parser)
		if attrs.get("Id", "") == relationship_id:
			var target := str(attrs.get("Target", "")).trim_prefix("/")
			if target.begins_with("xl/"): return target
			return "xl/" + target.trim_prefix("../")
	return ""

static func _read_date_styles(buffer: PackedByteArray) -> Array:
	var parser := _xml(buffer)
	var custom_ids := {}
	var formats: Array = []
	var in_xfs := false
	while parser.read() == OK:
		var kind := parser.get_node_type()
		var name := parser.get_node_name() if kind == XMLParser.NODE_ELEMENT or kind == XMLParser.NODE_ELEMENT_END else ""
		if kind == XMLParser.NODE_ELEMENT:
			var attrs := _attributes(parser)
			if name == "numFmt":
				var fmt := str(attrs.get("formatCode", "")).to_lower()
				if fmt.contains("y") or fmt.contains("d"): custom_ids[int(attrs.get("numFmtId", "-1"))] = true
			elif name == "cellXfs": in_xfs = true
			elif name == "xf" and in_xfs:
				var num_id := int(attrs.get("numFmtId", "0"))
				formats.append(num_id in [14, 15, 16, 17, 18, 19, 20, 21, 22, 45, 46, 47] or custom_ids.has(num_id))
		elif kind == XMLParser.NODE_ELEMENT_END and name == "cellXfs": in_xfs = false
	return formats

static func _read_sheet(buffer: PackedByteArray, strings: Array, date_styles: Array) -> Dictionary:
	var parser := _xml(buffer)
	var table := {}
	var max_row := -1
	var max_col := -1
	var cell_ref := ""
	var cell_type := ""
	var style_index := 0
	var value_text := ""
	var inline_text := ""
	var reading_v := false
	var reading_t := false
	while parser.read() == OK:
		var kind := parser.get_node_type()
		var name := parser.get_node_name() if kind == XMLParser.NODE_ELEMENT or kind == XMLParser.NODE_ELEMENT_END else ""
		if kind == XMLParser.NODE_ELEMENT:
			if name == "c":
				var attrs := _attributes(parser)
				cell_ref = str(attrs.get("r", ""))
				cell_type = str(attrs.get("t", ""))
				style_index = int(attrs.get("s", "0"))
				value_text = ""
				inline_text = ""
			elif name == "v": reading_v = true
			elif name == "t" and cell_type == "inlineStr": reading_t = true
		elif kind == XMLParser.NODE_TEXT:
			if reading_v: value_text += parser.get_node_data()
			elif reading_t: inline_text += parser.get_node_data()
		elif kind == XMLParser.NODE_ELEMENT_END:
			if name == "v": reading_v = false
			elif name == "t": reading_t = false
			elif name == "c":
				var address := _cell_address(cell_ref)
				var r := int(address.x)
				var c := int(address.y)
				if r >= 0 and r < MAX_ROWS and c >= 0 and c < MAX_COLUMNS:
					var value := value_text
					if cell_type == "s" and value_text.is_valid_int():
						var string_index := int(value_text)
						value = str(strings[string_index]) if string_index >= 0 and string_index < strings.size() else ""
					elif cell_type == "inlineStr": value = inline_text
					elif _is_date_style(date_styles, style_index) and value_text.is_valid_float(): value = _excel_date(value_text.to_float())
					if not table.has(r): table[r] = {}
					table[r][c] = value
					max_row = maxi(max_row, r)
					max_col = maxi(max_col, c)
	if table.is_empty(): return {"ok": false, "error": "Worksheet tidak memiliki sel dekripsi yang bisa dibaca."}
	var rows: Array = []
	for r in range(max_row + 1):
		var row: Array = []
		for c in range(max_col + 1): row.append(str(table.get(r, {}).get(c, "")))
		rows.append(row)
	return {"ok": true, "rows": rows}

static func _cell_address(reference: String) -> Vector2i:
	var col := 0
	var row_start := -1
	for i in reference.length():
		var code := reference.unicode_at(i)
		if code >= 65 and code <= 90: col = col * 26 + code - 64
		elif code >= 97 and code <= 122: col = col * 26 + code - 96
		else: row_start = i; break
	if row_start < 0: return Vector2i(-1, -1)
	var row_num := reference.substr(row_start).to_int()
	return Vector2i(row_num - 1, col - 1)

static func _is_date_style(styles: Array, index: int) -> bool:
	return index >= 0 and index < styles.size() and bool(styles[index])

static func _excel_date(serial: float) -> String:
	return Time.get_datetime_string_from_unix_time(int((serial - 25569.0) * 86400.0), true).substr(0, 10)
