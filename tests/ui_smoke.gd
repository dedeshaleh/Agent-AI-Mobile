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
