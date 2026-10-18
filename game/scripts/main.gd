extends Node2D
const AgentScript = preload("res://scripts/agent.gd")
const MapScript = preload("res://scripts/office_map.gd")
const MeetingScript = preload("res://scripts/meeting_manager.gd")
var office: OfficeMap
var team: Array[HQAgent] = []
var meeting: MeetingManager
var world_root := Node2D.new()
var reservations: Dictionary = {}
var paused := false
var speed := 1.0
var clock := 0.0
var mission_time := -1.0
var selected := 0
var status_label: Label
var detail: RichTextLabel
var dialogue: RichTextLabel
var log_view: RichTextLabel
var state_labels: Array[Label] = []
var meet_button: Button
var mission_button: Button
var pause_button: Button
var report_button: Button
var report_dialog: AcceptDialog
var import_dialog: AcceptDialog
var drag := false
var last_pointer := Vector2.ZERO
var saved_mission: Dictionary = {}
var status_accumulator := 0.0
var touch_points: Dictionary = {}

func _ready() -> void:
	Engine.max_fps = 30
	add_child(world_root)
	world_root.position = Vector2(-12, 5)
	world_root.scale = Vector2.ONE * 1.04
	office = MapScript.new()
	world_root.add_child(office)
	for i in 4:
		var agent: HQAgent = AgentScript.new()
		agent.setup(i, office)
		world_root.add_child(agent)
		team.append(agent)
		reservations[agent.tile] = i
		agent.arrived.connect(_on_arrived)
	meeting = MeetingScript.new()
	meeting.message_changed.connect(_on_message)
	meeting.completed.connect(_on_meeting_complete)
	_build_ui()
	_load_summary()
	_refresh()
	get_tree().auto_accept_quit = false

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_PAUSED:
		paused = true
		_save_summary()
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_save_summary()
		get_tree().quit()

func _process(delta: float) -> void:
	if not paused:
		clock += delta * speed
		for agent in team:
			agent.tick(delta * speed, reservations)
		meeting.tick(delta * speed)
		if mission_time >= 0:
			mission_time += delta * speed
			if mission_time >= 6:
				mission_time = -1
				_start_meeting()
	status_accumulator += delta
	if status_accumulator >= 0.2:
		status_accumulator = 0
		_refresh()

func _on_arrived(agent: HQAgent) -> void:
	if meeting.active:
		agent.set_status("MEETING", "Duduk di kursi meeting miliknya")
	else:
		agent.set_status("WORKING", "Mengetik di meja kerja - mode demo")

func _start_meeting() -> void:
	if meeting.active or mission_time >= 0 or _moving():
		return
	if meeting.begin(team):
		dialogue.text = "[color=#f6b95c]MEETING[/color]\nRobot menuju kursi masing-masing. Dialog akan dimulai setelah semua tiba."
		_log("Meeting dipanggil. Empat kursi telah dipesan.")
		_refresh()

func _start_mission() -> void:
	if meeting.active or mission_time >= 0 or _moving():
		return
	mission_time = 0
	for agent in team:
		agent.set_status("WORKING", "Menyiapkan materi meeting demo")
	dialogue.text = "[color=#62dfb0]MISI DEMO[/color]\nAgent menyiapkan materi, lalu berkumpul untuk meeting. Analisis file dan LLM belum aktif."
	_log("Misi demo dimulai. Tidak memakai data pengguna atau LLM.")
	_refresh()

func _on_message(index: int, message: String) -> void:
	dialogue.text = "[color=#%s]%s BERBICARA[/color]\n%s" % [team[index].tint.to_html(false), team[index].title.to_upper(), message.get_slice(": ", 1)]
	_log(message)
	_refresh()

func _on_meeting_complete() -> void:
	dialogue.text = "[color=#62dfb0]MEETING SELESAI[/color]\nNotulen tersedia. Semua agent kembali ke meja kerja."
	_log("Meeting selesai. Robot kembali bekerja.")
	_save_summary()

func _moving() -> bool:
	for agent in team:
		if agent.state == "WALKING":
			return true
	return false

func _refresh() -> void:
	var busy := meeting.active or mission_time >= 0 or _moving()
	meet_button.disabled = busy or paused
	mission_button.disabled = busy or paused
	report_button.disabled = meeting.transcript.is_empty()
	pause_button.text = "Lanjutkan" if paused else "Jeda"
	status_label.text = "DIJEDA" if paused else ("MEETING AKTIF" if meeting.active else ("MISI DEMO" if mission_time >= 0 else "KANTOR SIAP"))
	for i in team.size():
		state_labels[i].text = "%s    %s" % [team[i].title, team[i].state]
		team[i].selected = i == selected
	var agent := team[selected]
	detail.text = "[font_size=22][color=#%s]%s[/color][/font_size]\n%s\n\n[color=#8097af]STATUS[/color]  %s\n%s\n\n[color=#8097af]LOKASI[/color]  %s\n\n[color=#8097af]CATATAN TERAKHIR[/color]\n%s" % [agent.tint.to_html(false), agent.title, ["Validasi dan persiapan data", "KPI dan agregasi deterministik", "Interpretasi dan rekomendasi", "Notulen dan laporan"][selected], agent.state, agent.activity, _room_name(agent.tile), "\n".join(agent.history.slice(maxi(0, agent.history.size() - 3)))]

func _room_name(tile: Vector2i) -> String:
	var index := office.room_at(tile)
	return "Koridor" if index < 0 else OfficeMap.ROOM_NAMES[index]

func _log(message: String) -> void:
	log_view.append_text("[color=#617d99]%02d:%02d[/color]  %s\n" % [int(clock) / 60, int(clock) % 60, message])

func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var ui := Control.new()
	ui.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(ui)
	_panel(ui, Rect2(24, 22, 1392, 76), Color("101d2d"))
	_label(ui, "AGENT / HQ", Rect2(45, 35, 260, 35), 27, Color("edf5ff"))
	_label(ui, "KANTOR AI  /  OFFLINE PLAYGROUND", Rect2(46, 71, 430, 20), 12, Color("8097af"))
	status_label = _label(ui, "KANTOR SIAP", Rect2(745, 46, 230, 30), 16, Color("62dfb0"))
	_label(ui, "FASE 1  ·  DEMO TANPA LLM", Rect2(1090, 45, 305, 30), 15, Color("f6b95c"))
	_panel(ui, Rect2(1070, 116, 346, 555), Color("101d2d"))
	_label(ui, "TIM KAMU", Rect2(1090, 132, 290, 28), 15, Color("8097af"))
	for i in 4:
		var index := i
		var button := _button(ui, "", Rect2(1090, 172 + i * 43, 305, 38), func(): selected = index; _refresh())
		var label := Label.new()
		label.position = Vector2(12, 5)
		label.size = Vector2(285, 28)
		label.add_theme_font_size_override("font_size", 16)
		label.add_theme_color_override("font_color", OfficeMap.ROOM_COLORS[i])
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		button.add_child(label)
		state_labels.append(label)
	detail = _rich(ui, Rect2(1090, 362, 302, 285), 15)
	_panel(ui, Rect2(24, 584, 1028, 87), Color("101d2d"))
	dialogue = _rich(ui, Rect2(44, 599, 985, 65), 17)
	dialogue.text = "[color=#48a9ff]SELAMAT DATANG DI AGENT HQ[/color]\nTap robot untuk detail. Panggil meeting untuk melihat tim berjalan, duduk, dan berdialog."
	_panel(ui, Rect2(24, 688, 1392, 98), Color("101d2d"))
	mission_button = _button(ui, "Mulai Misi Demo", Rect2(42, 703, 212, 53), _start_mission, Color("225f50"))
	meet_button = _button(ui, "Panggil Meeting", Rect2(268, 703, 212, 53), _start_meeting, Color("26588d"))
	pause_button = _button(ui, "Jeda", Rect2(494, 703, 110, 53), func(): paused = not paused; _refresh())
	_button(ui, "x1 / x2", Rect2(618, 703, 110, 53), func(): speed = 2.0 if speed == 1.0 else 1.0; _log("Kecepatan animasi x%d" % int(speed)))
	_button(ui, "Upload Data", Rect2(742, 703, 160, 53), func(): import_dialog.popup_centered(Vector2i(560, 230)))
	report_button = _button(ui, "Notulen", Rect2(916, 703, 145, 53), _show_minutes)
	_button(ui, "Reset Kamera", Rect2(1075, 703, 320, 53), func(): world_root.position = Vector2(-12, 5); world_root.scale = Vector2.ONE * 1.04)
	_label(ui, "Tap robot / ruangan · Geser untuk pan · Scroll / pinch untuk zoom · Spasi: jeda · M: meeting", Rect2(44, 759, 1300, 20), 12, Color("8097af"))
	log_view = _rich(ui, Rect2(35, 121, 375, 65), 12)
	log_view.modulate.a = 0.65
	log_view.scroll_following = true
	report_dialog = AcceptDialog.new()
	report_dialog.title = "Notulen meeting demo"
	ui.add_child(report_dialog)
	import_dialog = AcceptDialog.new()
	import_dialog.title = "Analisis file - tahap berikutnya"
	import_dialog.dialog_text = "Fase 1 adalah game playable.\nImpor CSV/XLSX, perhitungan KPI, PDF/Excel dan AI\nbelum diimplementasikan. Tidak ada file yang diunggah."
	ui.add_child(import_dialog)

func _panel(parent: Node, rect: Rect2, color: Color) -> void:
	var panel := Panel.new()
	panel.position = rect.position
	panel.size = rect.size
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.set_corner_radius_all(14)
	style.border_color = Color("22374d")
	style.set_border_width_all(1)
	panel.add_theme_stylebox_override("panel", style)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(panel)

func _label(parent: Node, value: String, rect: Rect2, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = value
	label.position = rect.position
	label.size = rect.size
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(label)
	return label

func _rich(parent: Node, rect: Rect2, font_size: int) -> RichTextLabel:
	var label := RichTextLabel.new()
	label.position = rect.position
	label.size = rect.size
	label.bbcode_enabled = true
	label.add_theme_font_size_override("normal_font_size", font_size)
	label.add_theme_color_override("default_color", Color("d1dfef"))
	parent.add_child(label)
	return label

func _button(parent: Node, value: String, rect: Rect2, callback: Callable, color := Color("1d3046")) -> Button:
	var button := Button.new()
	button.text = value
	button.position = rect.position
	button.size = rect.size
	button.add_theme_font_size_override("font_size", 17)
	for variant in ["normal", "hover", "pressed", "disabled"]:
		var style := StyleBoxFlat.new()
		style.bg_color = color.lightened(0.12) if variant in ["hover", "pressed"] else color
		if variant == "disabled":
			style.bg_color = color.darkened(0.5)
		style.set_corner_radius_all(9)
		button.add_theme_stylebox_override(variant, style)
	button.pressed.connect(callback)
	parent.add_child(button)
	return button

func _show_minutes() -> void:
	report_dialog.dialog_text = "DEMO - bukan hasil analisis file / LLM\n\n" + "\n\n".join(meeting.transcript) + "\n\nTersimpan lokal. Ekspor PDF/Excel belum tersedia."
	report_dialog.popup_centered(Vector2i(850, 400))

func _save_summary() -> void:
	var file := FileAccess.open("user://mission_summary.json", FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify({"version": 1, "demo": true, "transcript": meeting.transcript, "clock": clock}))

func _load_summary() -> void:
	if not FileAccess.file_exists("user://mission_summary.json"):
		return
	var parsed = JSON.parse_string(FileAccess.get_file_as_string("user://mission_summary.json"))
	if parsed is Dictionary and parsed.get("version") == 1:
		clock = float(parsed.get("clock", 0))
		var lines = parsed.get("transcript", [])
		if lines is Array:
			for line in lines:
				if line is String:
					meeting.transcript.append(line)
		_log("Notulen terakhir dipulihkan. Posisi robot dimulai dari meja kerja.")

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_SPACE:
			paused = not paused
			_refresh()
		if event.keycode == KEY_M and not paused:
			_start_meeting()
	if event is InputEventMagnifyGesture:
		_zoom(event.factor)
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			_zoom(1.08)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			_zoom(1.0 / 1.08)
		elif event.button_index == MOUSE_BUTTON_LEFT:
			drag = event.pressed
			last_pointer = event.position
			if event.pressed:
				_pick(event.position)
	if event is InputEventMouseMotion and drag:
		world_root.position += event.relative
	if event is InputEventScreenTouch:
		if event.pressed:
			touch_points[event.index] = event.position
			if touch_points.size() == 1:
				_pick(event.position)
		else:
			touch_points.erase(event.index)
	if event is InputEventScreenDrag:
		if not touch_points.has(event.index):
			return
		if touch_points.size() == 1:
			world_root.position += event.relative
		else:
			var keys := touch_points.keys()
			var old_distance: float = touch_points[keys[0]].distance_to(touch_points[keys[1]])
			touch_points[event.index] = event.position
			var new_distance: float = touch_points[keys[0]].distance_to(touch_points[keys[1]])
			if old_distance > 10:
				_zoom(new_distance / old_distance)
		touch_points[event.index] = event.position

func _zoom(factor: float) -> void:
	var current := world_root.scale.x
	var next := clampf(current * factor, 0.7, 1.7)
	var center := Vector2(535, 365)
	world_root.position = center - (center - world_root.position) * next / current
	world_root.scale = Vector2.ONE * next

func _pick(point: Vector2) -> void:
	if point.x > 1060 or point.y < 105 or point.y > 575:
		return
	var local := world_root.to_local(point)
	for agent in team:
		if local.distance_to(agent.position - Vector2(0, 24)) < 35:
			selected = agent.agent_id
			_refresh()
			return
	var room := office.room_at(office.cell(local))
	if room >= 0:
		var occupants: Array[String] = []
		for agent in team:
			if office.room_at(agent.tile) == room:
				occupants.append(agent.title)
		dialogue.text = "[color=#%s]%s[/color]\nAgent di ruangan: %s" % [OfficeMap.ROOM_COLORS[room].to_html(false), OfficeMap.ROOM_NAMES[room], ", ".join(occupants) if not occupants.is_empty() else "belum ada"]
