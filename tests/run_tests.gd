extends SceneTree
const Analyzer = preload("res://scripts/csv_analyzer.gd")
const Advisor = preload("res://scripts/data_advisor.gd")
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
	assert(Advisor.answer("produk terlaris", csv).contains("Kopi"), "Agent answers top-product question from parsed facts")
	var messy_csv := Analyzer.analyze("product,revenue\nKopi,not-a-number\nTeh,5000")
	assert(Advisor.suggestions(messy_csv).contains("baris"), "Agent suggests reviewing invalid rows")
	var quoted := Analyzer.analyze("product,revenue\n\"Tea, green\",12500\nCoffee,7500")
	assert(quoted.get("ok", false) and is_equal_approx(quoted.total, 20000.0), "CSV quoted comma and direct revenue")
	assert(not Analyzer.analyze("header\nno numbers").get("ok", true), "Invalid numeric CSV is rejected")
	var xlsx_path := "user://phase2_test.xlsx"
	var zip := ZIPPacker.new()
	assert(zip.open(xlsx_path) == OK, "Create a small XLSX workbook fixture")
	zip.start_file("xl/sharedStrings.xml")
	zip.write_file("<sst><si><t>tanggal</t></si><si><t>produk</t></si><si><t>qty</t></si><si><t>harga</t></si><si><t>2026-01-02</t></si><si><t>Kopi</t></si><si><t>Teh</t></si></sst>".to_utf8_buffer())
	zip.close_file()
	zip.start_file("xl/workbook.xml")
	zip.write_file("<workbook xmlns:r=\"urn:r\"><sheets><sheet name=\"Sales\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>".to_utf8_buffer())
	zip.close_file()
	zip.start_file("xl/_rels/workbook.xml.rels")
	zip.write_file("<Relationships><Relationship Id=\"rId1\" Target=\"worksheets/sheet1.xml\"/></Relationships>".to_utf8_buffer())
	zip.close_file()
	zip.start_file("xl/styles.xml")
	zip.write_file("<styleSheet><cellXfs count=\"1\"><xf numFmtId=\"0\"/></cellXfs></styleSheet>".to_utf8_buffer())
	zip.close_file()
	zip.start_file("xl/worksheets/sheet1.xml")
	zip.write_file("<worksheet><sheetData><row r=\"1\"><c r=\"A1\" t=\"s\"><v>0</v></c><c r=\"B1\" t=\"s\"><v>1</v></c><c r=\"C1\" t=\"s\"><v>2</v></c><c r=\"D1\" t=\"s\"><v>3</v></c></row><row r=\"2\"><c r=\"A2\" t=\"s\"><v>4</v></c><c r=\"B2\" t=\"s\"><v>5</v></c><c r=\"C2\"><v>2</v></c><c r=\"D2\"><v>25000</v></c></row><row r=\"3\"><c r=\"A3\" t=\"s\"><v>4</v></c><c r=\"B3\" t=\"s\"><v>6</v></c><c r=\"C3\"><v>1</v></c><c r=\"D3\"><v>10000</v></c></row></sheetData></worksheet>".to_utf8_buffer())
	zip.close_file()
	zip.close()
	var excel_result := Analyzer.analyze_file(xlsx_path)
	assert(excel_result.get("ok", false) and is_equal_approx(excel_result.total, 60000.0), "XLSX shared strings and numeric cells produce correct KPI")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(xlsx_path))
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
