class_name MeetingManager
extends RefCounted
signal message_changed(index: int, message: String)
signal completed
var active := false
var started := false
var turn := -1
var elapsed := 0.0
var agents: Array[HQAgent] = []
var transcript: Array[String] = []
const DIALOGUE := [
	"Data: Pemeriksaan data siap. Ini dialog demo; belum ada file pengguna yang dianalisis.",
	"Analyst: KPI akan dihitung oleh kode. Belum ada angka penjualan pada demo ini.",
	"Strategist: Kita perlu memeriksa mapping kolom sebelum menyimpulkan hasil.",
	"Reporter: Notulen demo selesai. Tahap berikutnya: impor CSV dan validasi hasil."
]

func begin(team: Array[HQAgent]) -> bool:
	if active:
		return false
	agents = team
	active = true
	started = false
	turn = -1
	elapsed = 0
	transcript.clear()
	for i in agents.size():
		agents[i].go(OfficeMap.SEATS[i])
	return true

func tick(delta: float) -> void:
	if not active:
		return
	if not started:
		for i in agents.size():
			if agents[i].tile != OfficeMap.SEATS[i] or agents[i].state == "WALKING":
				return
		started = true
		for agent in agents:
			agent.set_status("MEETING", "Duduk dan menunggu giliran")
		_next_turn()
		return
	elapsed += delta
	if elapsed >= 5.0:
		_next_turn()

func _next_turn() -> void:
	elapsed = 0
	if turn >= 0:
		agents[turn].speaking = false
		agents[turn].set_status("MEETING", "Mendengarkan rekan")
	turn += 1
	if turn >= agents.size():
		active = false
		for agent in agents:
			agent.go(OfficeMap.HOMES[agent.agent_id])
		completed.emit()
		return
	agents[turn].speaking = true
	agents[turn].set_status("TALKING", "Menyampaikan pembaruan demo")
	transcript.append(DIALOGUE[turn])
	message_changed.emit(turn, DIALOGUE[turn])
