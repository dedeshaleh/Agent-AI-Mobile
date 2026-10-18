extends Control

var values: Dictionary = {}

func _draw() -> void:
	var keys: Array = values.keys()
	keys.sort()
	if keys.size() > 8: keys = keys.slice(keys.size() - 8)
	var font := ThemeDB.fallback_font
	var max_value := 1.0
	for key in keys: max_value = maxf(max_value, float(values[key]))
	for line in 4:
		var y := 24.0 + line * 55.0
		draw_line(Vector2(0, y), Vector2(size.x - 12, y), Color("#25394d"), 1.0)
	draw_string(font, Vector2(0, 17), "OMZET PER BULAN", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color("#90a9c2"))
	if keys.is_empty():
		draw_string(font, Vector2(25, 120), "Belum ada kolom tanggal untuk tren bulanan", HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color("#718aa4"))
		return
	var step := (size.x - 24.0) / keys.size()
	for i in keys.size():
		var h := float(values[keys[i]]) / max_value * 145.0
		var rect := Rect2(8 + i * step + 8, 234 - h, maxf(16.0, step - 18), h)
		draw_rect(rect, Color("#30c8ae"))
		draw_rect(Rect2(rect.position.x, rect.position.y, rect.size.x, 5), Color("#79f0c8"))
		draw_string(font, Vector2(rect.position.x - 8, 256), str(keys[i]), HORIZONTAL_ALIGNMENT_CENTER, step + 16, 12, Color("#a8bbd0"))
