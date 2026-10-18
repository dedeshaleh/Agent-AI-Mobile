extends SceneTree
var game: Node
var failures := 0

func check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error(message)

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	game = load("res://scenes/Main.tscn").instantiate()
	root.add_child(game)
	await process_frame
	check(game.csv_picker.use_native_dialog, "CSV picker uses native Android document picker")
	var analytics: Control = load("res://scripts/analytics_panel.gd").new()
	game.ui_layer.add_child(analytics)
	analytics.setup({"rows": 1, "skipped": 0, "total": 12000.0, "average": 12000.0, "products": [{"name": "Kopi", "value": 12000.0}], "months": {"2026-01": 12000.0}, "preview": [{"month": "2026-01", "product": "Kopi", "value": 12000.0}]}, func(): pass, func(_question: String): pass)
	check(analytics.get_child_count() >= 6, "Analytics dashboard renders KPI, product ranking and preview")
	var question_field: LineEdit = analytics.find_child("QuestionInput", true, false)
	var field_tap := InputEventScreenTouch.new()
	field_tap.index = 10
	field_tap.position = question_field.get_global_rect().get_center()
	field_tap.pressed = true
	game._input(field_tap)
	field_tap.pressed = false
	game._input(field_tap)
	await process_frame
	check(question_field.has_focus(), "Touch focuses the analytics question field")
	analytics.queue_free()
	game._start_mission()
	check(game.mission_time == 0, "Demo mission starts")
	game.paused = true
	var before: float = game.clock
	game._process(1.0)
	check(game.clock == before, "Pause freezes simulation")
	game.paused = false
	for i in 2000:
		game._process(1.0 / 30.0)
	check(game.meeting.transcript.size() == 4, "Demo mission completes meeting")
	check(not game.meeting.active, "Meeting finishes")
	game._show_minutes()
	game.report_dialog.hide()
	game._save_summary()
	check(FileAccess.file_exists("user://mission_summary.json"), "Summary saved")
	game.meeting.transcript.clear()
	game._load_summary()
	check(game.meeting.transcript.size() == 4, "Summary restored")
	var meeting_button: Button = game.find_children("*", "Button", true, false).filter(func(b: Button): return b.text == "Panggil Meeting")[0]
	var tap := InputEventScreenTouch.new()
	tap.position = meeting_button.global_position + meeting_button.size * 0.5
	tap.pressed = true
	game._input(tap)
	await process_frame
	tap.pressed = false
	game._input(tap)
	await process_frame
	check(game.meeting.active, "Screen touch activates the meeting button")
	for i in 2000:
		game._process(1.0 / 30.0)
	check(not game.meeting.active, "Screen touch meeting finishes")
	check(game.meeting.transcript.size() == 4, "Screen touch meeting records dialogue")
	game._zoom(50)
	check(game.world_root.scale.x <= 1.7001, "Zoom clamped")
	game.world_root.position = Vector2(-12, 5)
	game.world_root.scale = Vector2.ONE * 1.04
	game._refresh()
	if "--capture" in OS.get_cmdline_user_args():
		await process_frame
		await RenderingServer.frame_post_draw
		var capture := root.get_texture().get_image()
		var target := ProjectSettings.globalize_path("res://../build/preview.png")
		capture.save_png(target)
		print("SCREENSHOT: ", target)
	print("UI SMOKE: %d failures (mission, pause, minutes, persistence, zoom)" % failures)
	quit(0 if failures == 0 else 1)
