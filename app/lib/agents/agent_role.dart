/// Identitas empat agent dan state mesin (PRD §3.2, §7).
///
/// Urutan deklarasi enum = indeks yang dipakai di protokol Unity (0–3).
library;

import 'package:flutter/material.dart';

enum OfficeRoom {
  data('Ruang Data', Color(0xFF48A9FF)),
  analysis('Ruang Analisis', Color(0xFF62DFB0)),
  meeting('Ruang Meeting', Color(0xFFF6B95C)),
  report('Ruang Laporan', Color(0xFFEE86B9));

  const OfficeRoom(this.label, this.color);
  final String label;
  final Color color;

  static OfficeRoom fromIndex(int i) => values[i];
}

enum AgentRole {
  data('Data', 'Validasi dan persiapan data', OfficeRoom.data),
  analyst('Analyst', 'KPI dan agregasi deterministik', OfficeRoom.analysis),
  strategist('Strategist', 'Interpretasi dan rekomendasi', OfficeRoom.meeting),
  reporter('Reporter', 'Notulen dan laporan', OfficeRoom.report);

  const AgentRole(this.title, this.duty, this.homeRoom);
  final String title;
  final String duty;
  final OfficeRoom homeRoom;
  Color get color => homeRoom.color;

  static AgentRole fromIndex(int i) => values[i];
}

/// `IDLE -> ASSIGNED -> WALKING -> WORKING -> WAITING_TOOL/WAITING_LLM ->
/// MEETING -> REVIEW -> DONE`; error `FAILED`; jeda `PAUSED`.
enum AgentState {
  idle('IDLE'),
  assigned('ASSIGNED'),
  walking('WALKING'),
  working('WORKING'),
  waitingTool('WAITING_TOOL'),
  waitingLlm('WAITING_LLM'),
  meeting('MEETING'),
  talking('TALKING'),
  review('REVIEW'),
  done('DONE'),
  failed('FAILED'),
  paused('PAUSED');

  const AgentState(this.wire);

  /// Nilai yang dikirim ke Unity dan disimpan di log.
  final String wire;

  static AgentState fromWire(String s) => values.firstWhere((v) => v.wire == s, orElse: () => idle);
}
