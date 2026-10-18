class_name HQAgent
extends Node2D
signal arrived(agent: HQAgent)
var agent_id := 0
var title := "Data"
var tint := Color("48a9ff")
var state := "IDLE"
var activity := "Siap menerima misi"
var tile := Vector2i.ZERO
var path: Array[Vector2i] = []
var office: OfficeMap
var phase := 0.0
var selected := false
var speaking := false
var next_tile := Vector2i(-1, -1)
var history: Array[String] = []

func setup(index: int, map: OfficeMap) -> void:
	agent_id = index
	office = map
	title = ["Data", "Analyst", "Strategist", "Reporter"][index]
	tint = OfficeMap.ROOM_COLORS[index]
	tile = OfficeMap.HOMES[index]
	position = office.world(Vector2(tile))
	set_status("IDLE", "Siap menerima misi")

func set_status(value: String, description: String) -> void:
	state = value
	activity = description
	history.append(description)
	if history.size() > 16:
		history.pop_front()

func go(destination: Vector2i) -> bool:
	var result := office.route(tile, destination)
	if result.is_empty():
		set_status("FAILED", "Tujuan tidak dapat dijangkau")
		return false
	path = result
	if not path.is_empty() and path[0] == tile:
		path.pop_front()
	set_status("WALKING", "Berjalan menuju tempat tugas")
	return true

func tick(delta: float, reservations: Dictionary) -> void:
	phase += delta
	if state == "WALKING":
		if path.is_empty():
			set_status("WORKING", "Sudah tiba di tempat tugas")
			arrived.emit(self)
		else:
			var target := path[0]
			if next_tile.x < 0:
				if reservations.has(target) and reservations[target] != agent_id:
					# Replan around reserved tiles; never swap through another robot.
					var blocked: Array[Vector2i] = []
					for reserved: Vector2i in reservations:
						if reservations[reserved] != agent_id and not office.grid.is_point_solid(reserved):
							blocked.append(reserved)
							office.grid.set_point_solid(reserved, true)
					var destination: Vector2i = path.back()
					var alternate := office.route(tile, destination)
					for reserved in blocked:
						office.grid.set_point_solid(reserved, false)
					if alternate.size() > 1:
						alternate.pop_front()
						path = alternate
					queue_redraw()
					return
				reservations[target] = agent_id
				next_tile = target
			position = position.move_toward(office.world(Vector2(target)), delta * 76.0)
			if position.distance_to(office.world(Vector2(target))) < 0.1:
				if reservations.get(tile, -1) == agent_id:
					reservations.erase(tile)
				tile = target
				next_tile = Vector2i(-1, -1)
				path.pop_front()
	z_index = int(position.y)
	queue_redraw()

func _draw() -> void:
	var walk := state == "WALKING" and next_tile.x >= 0
	var bob := sin(phase * 13.0) * 2.0 if walk else sin(phase * 2.0) * 0.8
	var seated := state in ["MEETING", "TALKING", "WORKING"]
	var base := Vector2(0, -3 if seated else -7)
	draw_set_transform(Vector2.ZERO, 0, Vector2(1.0, 0.45))
	draw_circle(Vector2(0, 3), 15, Color(0, 0, 0, 0.33))
	if selected:
		draw_arc(Vector2.ZERO, 21, 0, TAU, 32, tint, 2.5, true)
	draw_set_transform(Vector2.ZERO)
	var stride := sin(phase * 13.0) * 4.0 if walk else 0.0
	draw_line(base + Vector2(-5, -2), Vector2(-6 + stride, 0), tint.darkened(0.4), 5, true)
	draw_line(base + Vector2(5, -2), Vector2(6 - stride, 0), tint.darkened(0.4), 5, true)
	var torso := Rect2(base + Vector2(-11, -21 + bob), Vector2(22, 22))
	draw_style_box(_rounded(tint.darkened(0.2), 6), torso)
	draw_circle(base + Vector2(0, -12 + bob), 3, tint.lightened(0.6))
	var typing := sin(phase * 14.0) * 2.0 if state == "WORKING" else stride
	draw_line(base + Vector2(-12, -16 + bob), base + Vector2(-15, -6 + bob + typing), tint, 4, true)
	draw_line(base + Vector2(12, -16 + bob), base + Vector2(15, -6 + bob - typing), tint, 4, true)
	var head := Rect2(base + Vector2(-14, -42 + bob), Vector2(28, 23))
	draw_style_box(_rounded(tint, 7), head)
	draw_style_box(_rounded(Color("101f2e"), 4), head.grow(-4))
	var blink := fmod(phase + agent_id, 4.8) < 0.14
	for x in [-5, 5]:
		draw_line(base + Vector2(x, -33 + bob), base + Vector2(x, (-33 if blink else -29) + bob), Color("c7f9ff"), 2, true)
	draw_line(base + Vector2(0, -42 + bob), base + Vector2(0, -48 + bob), tint.darkened(0.1), 2)
	draw_circle(base + Vector2(0, -49 + bob), 3, Color("b2ffcf"))
	if speaking:
		for i in 3:
			draw_circle(base + Vector2(-7 + i * 7, -64 + sin(phase * 7 + i) * 2), 2.5, Color.WHITE)
	if state == "DONE":
		draw_arc(base + Vector2(0, -30), 21 + sin(phase * 4) * 2, 0, TAU, 24, Color(tint, 0.45), 1, true)
	draw_string(ThemeDB.fallback_font, Vector2(-32, 20), title, HORIZONTAL_ALIGNMENT_CENTER, 64, 12, Color("dce8f5"))

func _rounded(color: Color, radius: int) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.set_corner_radius_all(radius)
	return style
