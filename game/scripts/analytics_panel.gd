extends Control
class_name AnalyticsPanel

var data: Dictionary = {}
var close_callback: Callable

func setup(result: Dictionary, on_close: Callable) -> void:
	data = result
	close_callback = on_close
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build()

func _build() -> void:
	var bg := ColorRect.new()
	bg.color = Color("#07111f")
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var title := _label("ANALISIS DATA", Vector2(42, 25), Vector2(600, 42), 28, Color("#edf5ff"))
	var subtitle := _label("CSV lokal · hasil deterministik · tanpa upload", Vector2(44, 68), Vector2(700, 25), 15, Color("#8ca6c2"))
	var close := Button.new()
	close.text = "Tutup"
	close.position = Vector2(1270, 28)
	close.size = Vector2(120, 48)
	close.pressed.connect(close_callback)
	add_child(close)
	var summary := "%.0f baris valid  ·  %d dilewati" % [data.rows, data.skipped]
	_label(summary, Vector2(44, 111), Vector2(1000, 25), 15, Color("#62dfb0"))
	_card("TOTAL OMZET", _money(data.total), Vector2(44, 155), Color("#163d5a"))
	_card("RATA-RATA / BARIS", _money(data.average), Vector2(500, 155), Color("#173e3b"))
	_card("PRODUK TERATAS", str(data.products[0].name), Vector2(956, 155), Color("#493451"))
	_draw_chart(data.get("months", {}))
	var product_text := "TOP PRODUK\n"
	for item in data.products: product_text += "\n%s   ·   %s" % [str(item.name), _money(item.value)]
	_label(product_text, Vector2(880, 300), Vector2(510, 315), 17, Color("#d1dfef"))
	var sample := "PRATINJAU (5 BARIS)\n"
	for item in data.preview: sample += "\n%s   ·   %s   ·   %s" % [item.month, item.product, _money(item.value)]
	_label(sample, Vector2(44, 597), Vector2(1300, 175), 15, Color("#a8bbd0"))

func _card(heading: String, value: String, at: Vector2, tint: Color) -> void:
	var panel := Panel.new()
	panel.position = at
	panel.size = Vector2(420, 112)
	var style := StyleBoxFlat.new()
	style.bg_color = tint
	style.set_corner_radius_all(18)
	panel.add_theme_stylebox_override("panel", style)
	add_child(panel)
	_label(heading, at + Vector2(22, 15), Vector2(375, 25), 14, Color("#a9c0d7"))
	_label(value, at + Vector2(22, 47), Vector2(375, 50), 24, Color("#f1f7ff"))

func _draw_chart(months: Dictionary) -> void:
	var chart := Control.new()
	chart.position = Vector2(44, 300)
	chart.size = Vector2(800, 270)
	chart.set_script(load("res://scripts/month_chart.gd"))
	chart.set("values", months)
	add_child(chart)

func _label(value: String, at: Vector2, dimensions: Vector2, size: int, tint: Color) -> Label:
	var label := Label.new()
	label.text = value
	label.position = at
	label.size = dimensions
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", tint)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(label)
	return label

func _money(amount: float) -> String:
	var raw := "%.0f" % amount
	var grouped := ""
	for i in raw.length():
		if i > 0 and (raw.length() - i) % 3 == 0: grouped += "."
		grouped += raw.substr(i, 1)
	return "Rp " + grouped
