extends SceneTree
const Analyzer = preload("res://scripts/csv_analyzer.gd")
const Map = preload("res://scripts/office_map.gd")
const Agent = preload("res://scripts/agent.gd")
const Meeting = preload("res://scripts/meeting_manager.gd")
var failures: Array[String] = []

func check(ok: bool, message: String) -> void:
	if not ok:
		failures.append(message)
		push_error(message)

func _initialize() -> void:
	var csv := Analyzer.analyze("tanggal;produk;qty;harga\n2026-01-02;Kopi;2;19.500,50\n2026-02-01;\"Teh, hijau\";1;10.000")
	assert(csv.get("ok", false), "CSV with semicolon, quotes and Indonesian currency parses")
	assert(csv.rows == 2 and is_equal_approx(csv.total, 49001.0), "CSV revenue aggregation is deterministic")
	var quoted := Analyzer.analyze("product,revenue\n\"Tea, green\",12500\nCoffee,7500")
	assert(quoted.get("ok", false) and is_equal_approx(quoted.total, 20000.0), "CSV quoted comma and direct revenue")
	assert(not Analyzer.analyze("header\nno numbers").get("ok", true), "Invalid numeric CSV is rejected")
	call_deferred("run")

func run() -> void:
	var map = Map.new()
	root.add_child(map)
	for start in Map.HOMES:
		for goal in Map.SEATS:
			var path = map.route(start, goal)
			check(not path.is_empty(), "Every home must reach every meeting seat")
			for i in path.size():
				check(not map.grid.is_point_solid(path[i]), "Path crosses wall or furniture")
				if i > 0:
					var diff: Vector2i = path[i] - path[i - 1]
					check(absi(diff.x) + absi(diff.y) == 1, "Path must use adjacent tiles")
	check(map.route(Vector2i(-1, -1), Map.SEATS[0]).is_empty(), "Invalid start rejected")
	check(map.route(Map.HOMES[0], Vector2i(4, 3)).is_empty(), "Desk is not walkable")
	var team: Array[HQAgent] = []
	var reserved := {}
	for i in 4:
		var agent = Agent.new()
		agent.setup(i, map)
		root.add_child(agent)
		team.append(agent)
		reserved[agent.tile] = i
	var manager = Meeting.new()
	var returned := 0
	for cycle in 3:
		check(manager.begin(team), "Meeting should start")
		check(not manager.begin(team), "Reentrant meeting rejected")
		var finished := false
		for step in 18000:
			for agent in team:
				agent.tick(1.0 / 30.0, reserved)
			manager.tick(1.0 / 30.0)
			for a in team.size():
				check(map.is_floor(team[a].tile), "Agent left floor")
				for b in range(a + 1, team.size()):
					if team[a].position.distance_to(team[b].position) < 9:
						check(false, "Agents overlap during navigation")
			var home := true
			for i in team.size():
				home = home and team[i].tile == Map.HOMES[i] and team[i].state != "WALKING"
			if not manager.active and home:
				finished = true
				returned += 1
				break
		check(finished, "Meeting and return must complete without deadlock: cycle %d" % cycle)
		check(manager.transcript.size() == 4, "Each agent speaks exactly once")
		for i in team.size():
			check(not team[i].speaking, "Speaking flag cleared after meeting")
	check(returned == 3, "Three repeatable meeting cycles")
	print("RESULT: %d failures; %d complete meeting cycles" % [failures.size(), returned])
	quit(0 if failures.is_empty() else 1)
