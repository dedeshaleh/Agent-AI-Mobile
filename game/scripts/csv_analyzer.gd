extends RefCounted
class_name CSVAnalyzer

const MAX_BYTES := 20 * 1024 * 1024
const MAX_ROWS := 100000

static func analyze(text: String) -> Dictionary:
	if text.to_utf8_buffer().size() > MAX_BYTES:
		return {"ok": false, "error": "File lebih besar dari batas 20 MB."}
	text = text.replace("\uFEFF", "")
	var delimiter := _detect_delimiter(text)
	var rows := _parse_rows(text, delimiter)
	if rows.size() < 2:
		return {"ok": false, "error": "CSV perlu satu baris judul dan minimal satu baris data."}
	if rows.size() > MAX_ROWS + 1:
		return {"ok": false, "error": "CSV melebihi batas 100.000 baris."}
	var headers: Array = rows[0]
	var map := {"date": -1, "product": -1, "quantity": -1, "price": -1, "revenue": -1}
	var aliases := {"date": ["tanggal", "tanggal_transaksi", "date", "bulan", "month"], "product": ["produk", "nama_produk", "product", "item", "barang", "nama"], "quantity": ["qty", "quantity", "jumlah", "jumlah_terjual", "kuantitas"], "price": ["harga", "price", "unit_price", "harga_satuan"], "revenue": ["revenue", "pendapatan", "total_pendapatan", "total_omzet", "omzet", "sales", "total"]}
	for i in headers.size():
		var key := str(headers[i]).strip_edges().to_lower().replace(" ", "_")
		for field in aliases:
			if key in aliases[field] and map[field] < 0:
				map[field] = i
	if map.revenue < 0 and (map.quantity < 0 or map.price < 0):
		return {"ok": false, "error": "Kolom omzet/revenue atau pasangan qty + harga tidak ditemukan.", "headers": headers}
	var total := 0.0
	var valid := 0
	var skipped := 0
	var by_month := {}
	var by_product := {}
	var preview: Array = []
	for r in range(1, rows.size()):
		var row: Array = rows[r]
		if row.size() == 1 and str(row[0]).strip_edges().is_empty():
			continue
		var value := 0.0
		if map.revenue >= 0:
			var revenue_text := _cell(row, map.revenue)
			if not _valid_number(revenue_text):
				skipped += 1
				continue
			value = _number(revenue_text)
		else:
			var quantity_text := _cell(row, map.quantity)
			var price_text := _cell(row, map.price)
			if not _valid_number(quantity_text) or not _valid_number(price_text):
				skipped += 1
				continue
			value = _number(quantity_text) * _number(price_text)
		var max_column := -1
		for column_index in map.values(): max_column = maxi(max_column, int(column_index))
		if row.size() <= max_column:
			skipped += 1
			continue
		var product := _cell(row, map.product) if map.product >= 0 else "Produk"
		if product.is_empty(): product = "Tanpa nama"
		var month := _cell(row, map.date) if map.date >= 0 else "Tanpa tanggal"
		if month.length() >= 7: month = month.substr(0, 7)
		by_month[month] = float(by_month.get(month, 0.0)) + value
		by_product[product] = float(by_product.get(product, 0.0)) + value
		total += value
		valid += 1
		if preview.size() < 5: preview.append({"product": product, "month": month, "value": value})
	if valid == 0:
		return {"ok": false, "error": "Tidak ada baris dengan angka omzet yang valid."}
	var top: Array = []
	for name in by_product: top.append({"name": name, "value": by_product[name]})
	top.sort_custom(func(a, b): return a.value > b.value)
	if top.size() > 5: top.resize(5)
	return {"ok": true, "headers": headers, "rows": valid, "skipped": skipped, "total": total, "average": total / valid, "months": by_month, "products": top, "preview": preview}

static func _cell(row: Array, index: int) -> String:
	return str(row[index]).strip_edges() if index >= 0 and index < row.size() else ""

static func _number(value: String) -> float:
	return _normalize_number(value).to_float()

static func _valid_number(value: String) -> bool:
	return _normalize_number(value).is_valid_float()

static func _normalize_number(value: String) -> String:
	var s := value.strip_edges().replace("Rp", "").replace("IDR", "").replace(" ", "")
	if s.contains(",") and s.contains("."):
		if s.rfind(",") > s.rfind("."): s = s.replace(".", "").replace(",", ".")
		else: s = s.replace(",", "")
	elif s.contains("."):
		if s.get_slice(".", s.get_slice_count(".") - 1).length() == 3: s = s.replace(".", "")
	elif s.contains(","):
		var fraction := s.get_slice(",", s.get_slice_count(",") - 1)
		if fraction.length() == 3: s = s.replace(",", "")
		else: s = s.replace(",", ".")
	return s

static func _detect_delimiter(text: String) -> String:
	var line := text.get_slice("\n", 0)
	var chosen := ","
	var max_count := -1
	for candidate in [",", ";", "\t"]:
		var count := line.count(candidate)
		if count > max_count: max_count = count; chosen = candidate
	return chosen

static func _parse_rows(text: String, delimiter: String) -> Array:
	var rows: Array = []
	var row: Array = []
	var cell := ""
	var quoted := false
	var i := 0
	while i < text.length():
		var ch := text.substr(i, 1)
		if ch == '"':
			if quoted and i + 1 < text.length() and text.substr(i + 1, 1) == '"': cell += '"'; i += 1
			else: quoted = not quoted
		elif not quoted and ch == delimiter:
			row.append(cell); cell = ""
		elif not quoted and (ch == "\n" or ch == "\r"):
			row.append(cell); cell = ""
			if not row.is_empty(): rows.append(row)
			if rows.size() > MAX_ROWS + 1: return rows
			row = []
			if ch == "\r" and i + 1 < text.length() and text.substr(i + 1, 1) == "\n": i += 1
		else: cell += ch
		i += 1
	if not cell.is_empty() or not row.is_empty(): row.append(cell); rows.append(row)
	return rows
