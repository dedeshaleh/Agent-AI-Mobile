extends RefCounted
class_name DataAdvisor

static func suggestions(data: Dictionary) -> String:
	var tips: Array[String] = []
	if int(data.get("skipped", 0)) > 0:
		tips.append("Cek %d baris yang tidak memiliki angka omzet valid." % data.skipped)
	var products: Array = data.get("products", [])
	if not products.is_empty() and float(data.get("total", 0.0)) > 0:
		var share := float(products[0].value) / float(data.total)
		if share >= 0.6: tips.append("%s menyumbang %.0f%% omzet; periksa risiko ketergantungan stok." % [products[0].name, share * 100.0])
	var months: Array = data.get("months", {}).keys()
	months.sort()
	if months.size() >= 2:
		var previous := float(data.months[months[months.size() - 2]])
		var latest := float(data.months[months[-1]])
		if previous > 0 and latest < previous:
			tips.append("Omzet %s turun %.0f%% dari %s; cek perubahan stok, harga, atau promosi." % [months[-1], (previous - latest) / previous * 100.0, months[months.size() - 2]])
	if not data.get("has_date", false): tips.append("Tambahkan kolom tanggal untuk melihat tren dari waktu ke waktu.")
	tips.append("Laba belum bisa dihitung tanpa kolom modal/HPP dan diskon yang terstruktur.")
	return "• " + "\n• ".join(tips)

static func answer(question: String, data: Dictionary) -> String:
	var q := question.to_lower()
	var products: Array = data.get("products", [])
	var total := float(data.get("total", 0.0))
	if q.contains("rata") or q.contains("average"):
		return "Rata-rata omzet per baris valid adalah Rp %s dari %d baris." % [_format(data.average), int(data.rows)]
	if q.contains("total") or q.contains("omzet") or q.contains("pendapatan") or q.contains("revenue"):
		return "Total omzet yang terhitung adalah Rp %s dari %d baris valid. Baris yang dilewati: %d." % [_format(total), int(data.rows), int(data.skipped)]
	if q.contains("rendah") or q.contains("sedikit") or q.contains("terkecil") or q.contains("bottom"):
		if not products.is_empty():
			var item: Dictionary = products[products.size() - 1]
			return "%s adalah produk dengan omzet terendah di antara produk yang terbaca: Rp %s." % [item.name, _format(float(item.value))]
	if q.contains("produk") or q.contains("laku") or q.contains("tertinggi") or q.contains("terlaris") or q.contains("top"):
		if not products.is_empty():
			return "Produk dengan omzet tertinggi adalah %s, Rp %s. Total omzet Rp %s." % [products[0].name, _format(float(products[0].value)), _format(total)]
	if q.contains("tren") or q.contains("bulan") or q.contains("turun") or q.contains("naik"):
		var months: Array = data.get("months", {}).keys()
		months.sort()
		if months.size() >= 2:
			var first: String = months[0]
			var last: String = months[-1]
			var start := float(data.months[first])
			var finish := float(data.months[last])
			var change := ((finish - start) / absf(start) * 100.0) if start != 0 else 0.0
			return "Dari %s ke %s, omzet %s dari Rp %s menjadi Rp %s (perubahan %+.1f%%)." % [first, last, "naik" if change > 0 else "turun" if change < 0 else "tetap", _format(start), _format(finish), change]
		return "Kolom tanggal belum cukup untuk menghitung tren bulanan."
	if q.contains("ringkas") or q.contains("summary") or q.contains("saran") or q.contains("cek") or q.contains("lihat"):
		return "Ringkasan: %d baris valid, total omzet Rp %s.\n%s" % [int(data.rows), _format(total), suggestions(data)]
	return "Saya menemukan %d baris valid dengan total omzet Rp %s. Tanyakan total, rata-rata, tren bulanan, produk tertinggi/terendah, atau minta ringkasan dan saran." % [int(data.rows), _format(total)]

static func _format(amount: float) -> String:
	var raw := "%.0f" % amount
	var grouped := ""
	for i in raw.length():
		if i > 0 and (raw.length() - i) % 3 == 0: grouped += "."
		grouped += raw.substr(i, 1)
	return grouped
