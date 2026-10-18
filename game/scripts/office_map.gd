class_name OfficeMap
extends Node2D
## The same logical grid drives rendering, picking, collision and navigation.
const SIZE := Vector2i(20, 16)
const TILE := Vector2(48, 24)
const ORIGIN := Vector2(540, 125)
const ROOM_NAMES := ["DATA LAB", "ANALYSIS", "MEETING", "REPORT STUDIO"]
const ROOM_COLORS := [Color("48a9ff"), Color("62dfb0"), Color("f6b95c"), Color("ee86b9")]
const ROOMS := [Rect2i(1, 1, 8, 6), Rect2i(11, 1, 8, 6), Rect2i(1, 9, 8, 6), Rect2i(11, 9, 8, 6)]
const HOMES := [Vector2i(4, 4), Vector2i(14, 4), Vector2i(3, 12), Vector2i(14, 12)]
const SEATS := [Vector2i(3, 11), Vector2i(6, 11), Vector2i(3, 13), Vector2i(6, 13)]
var grid := AStarGrid2D.new()
var furniture: Array[Vector2i] = [Vector2i(4, 3), Vector2i(5, 3), Vector2i(14, 3), Vector2i(15, 3), Vector2i(14, 11), Vector2i(15, 11), Vector2i(4, 11), Vector2i(5, 11), Vector2i(4, 12), Vector2i(5, 12), Vector2i(4, 13), Vector2i(5, 13)]

func _init() -> void:
	grid.region = Rect2i(Vector2i.ZERO, SIZE)
	grid.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_NEVER
	grid.update()
	for y in SIZE.y:
		for x in SIZE.x:
			var p := Vector2i(x, y)
			grid.set_point_solid(p, not is_floor(p) or p in furniture)

func is_floor(p: Vector2i) -> bool:
	if not Rect2i(Vector2i.ZERO, SIZE).has_point(p):
		return false
	if p.x in [9, 10] or p.y in [7, 8]:
		return true
	for rect in ROOMS:
		if rect.has_point(p):
			return true
	return false

func room_at(p: Vector2i) -> int:
	for i in ROOMS.size():
		if ROOMS[i].has_point(p):
			return i
	return -1

func world(p: Vector2) -> Vector2:
	return ORIGIN + Vector2((p.x - p.y) * TILE.x / 2.0, (p.x + p.y) * TILE.y / 2.0)

func cell(p: Vector2) -> Vector2i:
	var q := p - ORIGIN
	return Vector2i(roundi(q.x / TILE.x + q.y / TILE.y), roundi(q.y / TILE.y - q.x / TILE.x))

func route(from: Vector2i, to: Vector2i) -> Array[Vector2i]:
	if not grid.is_in_boundsv(from) or not grid.is_in_boundsv(to):
		return []
	if grid.is_point_solid(from) or grid.is_point_solid(to):
		return []
	return grid.get_id_path(from, to)

func diamond(center: Vector2, color: Color) -> void:
	var points := PackedVector2Array([center + Vector2(0, -12), center + Vector2(24, 0), center + Vector2(0, 12), center + Vector2(-24, 0)])
	draw_colored_polygon(points, color)
	draw_polyline(points + PackedVector2Array([points[0]]), Color(1, 1, 1, 0.055), 1.0, true)

func box(p: Vector2i, color: Color, height: float = 21.0) -> void:
	var c := world(Vector2(p))
	var top := c - Vector2(0, height)
	draw_colored_polygon(PackedVector2Array([top + Vector2(-22, 0), top + Vector2(0, 11), c + Vector2(0, 11), c + Vector2(-22, 0)]), color.darkened(0.35))
	draw_colored_polygon(PackedVector2Array([top + Vector2(0, 11), top + Vector2(22, 0), c + Vector2(22, 0), c + Vector2(0, 11)]), color.darkened(0.55))
	diamond(top, color)

func _draw() -> void:
	for y in SIZE.y:
		for x in SIZE.x:
			var p := Vector2i(x, y)
			if not is_floor(p):
				continue
			var room := room_at(p)
			var color: Color = Color("1b2b3b") if room < 0 else ROOM_COLORS[room].darkened(0.79)
			if (x + y) % 2 == 0:
				color = color.lightened(0.035)
			diamond(world(Vector2(p)) + Vector2(0, 7), Color("080f19"))
			diamond(world(Vector2(p)), color)
	# Rear walls leave explicit openings onto the two corridors.
	for i in ROOMS.size():
		var rect: Rect2i = ROOMS[i]
		var a := world(Vector2(rect.position)) + Vector2(-24, 0)
		var b := world(Vector2(rect.position + Vector2i(rect.size.x - 1, 0))) + Vector2(0, -12)
		var c := world(Vector2(rect.position + Vector2i(0, rect.size.y - 1))) + Vector2(0, 12)
		draw_line(a, b, ROOM_COLORS[i].darkened(0.4), 4.0, true)
		draw_line(a, c, ROOM_COLORS[i].darkened(0.55), 4.0, true)
		var title := world(Vector2(rect.position)) + Vector2(-12, -25)
		draw_string(ThemeDB.fallback_font, title, ROOM_NAMES[i], HORIZONTAL_ALIGNMENT_LEFT, -1, 13, ROOM_COLORS[i])
	for p in furniture:
		var room := room_at(p)
		box(p, Color("597289") if room != 2 else Color("846644"))
		if room != 2:
			var c := world(Vector2(p)) - Vector2(0, 32)
			draw_style_box(_screen_style(), Rect2(c - Vector2(12, 8), Vector2(25, 17)))
			draw_line(c + Vector2(-7, 0), c + Vector2(7, 0), ROOM_COLORS[room], 2)
	for p in SEATS:
		draw_circle(world(Vector2(p)), 9, Color("a38658"))
	for p in HOMES:
		if p not in SEATS:
			draw_circle(world(Vector2(p)), 8, Color("42576a"))
	for p in [Vector2i(1, 6), Vector2i(18, 6), Vector2i(1, 14), Vector2i(18, 14)]:
		box(p, Color("46615b"), 10)
		draw_circle(world(Vector2(p)) - Vector2(0, 21), 11, Color("57a581"))

func _screen_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color("0a1725")
	style.set_corner_radius_all(3)
	return style
