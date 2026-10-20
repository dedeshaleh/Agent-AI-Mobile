import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../ai/ai_provider.dart';
import '../ai/ai_router.dart';
import '../data/analysis_result.dart';
import '../data/data_advisor.dart';
import '../game_bridge/game_protocol.dart';
import '../perf/perf_monitor.dart';
import 'agent_chat.dart';
import 'agent_profile.dart';
import 'agent_role.dart';

enum MissionPhase { idle, dataPrep, analysis, strategy, meeting, report, done, failed }

class AgentStatus {
  const AgentStatus({
    required this.state,
    required this.activity,
    this.roomIndex = -1,
    this.history = const [],
    this.providerId,
    this.lastDurationMs,
    this.lastTokensPerSecond,
  });
  final AgentState state;
  final String activity;
  final int roomIndex;
  final List<String> history;

  /// Provider yang menjawab giliran terakhir agent ini (null = template).
  final String? providerId;

  /// Lama proses jawaban model terakhir dan kecepatannya.
  final int? lastDurationMs;
  final double? lastTokensPerSecond;

  String? get lastTimingLabel {
    if (lastDurationMs == null) return null;
    final secs = (lastDurationMs! / 1000).toStringAsFixed(1).replaceAll('.', ',');
    final tps = lastTokensPerSecond;
    return tps == null || tps <= 0 ? '⏱ $secs s' : '⏱ $secs s · ${tps.toStringAsFixed(0)} tok/s';
  }

  AgentStatus copyWith({
    AgentState? state,
    String? activity,
    int? roomIndex,
    String? providerId,
    int? lastDurationMs,
    double? lastTokensPerSecond,
  }) {
    final next = activity ?? this.activity;
    return AgentStatus(
      state: state ?? this.state,
      activity: next,
      roomIndex: roomIndex ?? this.roomIndex,
      history: activity == null ? history : [...history.take(15), next],
      providerId: providerId ?? this.providerId,
      lastDurationMs: lastDurationMs ?? this.lastDurationMs,
      lastTokensPerSecond: lastTokensPerSecond ?? this.lastTokensPerSecond,
    );
  }
}

class MeetingLine {
  const MeetingLine(this.agent, this.text, {this.source});
  final AgentRole agent;
  final String text;

  /// Provider id atau null bila teks berasal dari template/kode.
  final String? source;

  Map<String, Object?> toJson() => {'agent': agent.index, 'text': text, 'source': source};
  factory MeetingLine.fromJson(Map<String, Object?> j) => MeetingLine(
        AgentRole.fromIndex(j['agent'] as int),
        j['text'] as String,
        source: j['source'] as String?,
      );
}

class MissionRecord {
  const MissionRecord({
    required this.id,
    required this.startedAt,
    required this.sourceName,
    required this.transcript,
    required this.report,
    required this.facts,
  });
  final String id;
  final DateTime startedAt;
  final String sourceName;
  final List<MeetingLine> transcript;
  final String report;
  final Map<String, Object?> facts;

  Map<String, Object?> toJson() => {
        'id': id,
        'started_at': startedAt.toIso8601String(),
        'source_name': sourceName,
        'transcript': transcript.map((l) => l.toJson()).toList(),
        'report': report,
        'facts': facts,
      };
  factory MissionRecord.fromJson(Map<String, Object?> j) => MissionRecord(
        id: j['id'] as String,
        startedAt: DateTime.parse(j['started_at'] as String),
        sourceName: (j['source_name'] as String?) ?? '',
        transcript: (j['transcript'] as List).cast<Map<String, Object?>>().map(MeetingLine.fromJson).toList(),
        report: (j['report'] as String?) ?? '',
        facts: (j['facts'] as Map?)?.cast<String, Object?>() ?? const {},
      );
}

/// Menjalankan satu misi end-to-end (PRD §4) dan mengarahkan robot di game.
/// Semua angka berasal dari [AnalysisResult]; LLM hanya merangkai narasi.
class MissionOrchestrator extends ChangeNotifier {
  MissionOrchestrator({required this.game, required this.ai, required this.profiles, this.perf, this.onPersist}) {
    _sub = game.events.listen(_onGameEvent);
  }

  final GameBridge game;
  final AiRouter ai;
  final AgentProfileStore profiles;
  final PerfMonitor? perf;
  final Future<void> Function(MissionRecord record)? onPersist;

  /// Dipasang UI: tap robot di game → buka chat dengan target agent itu.
  void Function(AgentRole role)? onAgentTapped;
  late final StreamSubscription<GameEvent> _sub;

  MissionPhase phase = MissionPhase.idle;
  bool paused = false;
  int speed = 1;
  AgentRole selected = AgentRole.data;
  AnalysisResult? data;
  String? missionId;
  final transcript = <MeetingLine>[];
  String report = '';
  final log = <String>[];
  final Map<AgentRole, AgentStatus> agents = {
    for (final r in AgentRole.values)
      r: AgentStatus(state: AgentState.idle, activity: 'Siap menerima misi', roomIndex: r.homeRoom.index),
  };

  /// Teks yang sedang di-stream dari model (untuk bubble langsung).
  String streaming = '';
  AgentRole? streamingAgent;
  DateTime? streamingStartedAt;

  /// Percakapan pengguna ⇄ agent, termasuk baris sistem (log) dan transkrip meeting.
  final chat = <ChatMessage>[];

  /// Perintah pengguna sedang diproses oleh satu/beberapa agent.
  bool commanding = false;

  final _arrivals = <AgentRole, Completer<void>>{};
  Completer<void>? _seated;
  Completer<void>? _resume;
  CancelToken? _cancel;
  bool _cancelled = false;
  bool _greeted = false;
  final _speechTimers = <AgentRole, Timer>{};

  bool get missionRunning => phase != MissionPhase.idle && phase != MissionPhase.done && phase != MissionPhase.failed;
  bool get busy => missionRunning || commanding;
  bool get hasTranscript => transcript.isNotEmpty;

  // ---------------------------------------------------------------- greeting & commands

  /// Keempat robot menyapa sesuai jam saat kantor pertama kali siap.
  Future<void> greet() async {
    if (_greeted) return;
    _greeted = true;
    final greeting = greetingForHour(DateTime.now().hour);
    String line(AgentRole role) {
      final p = profiles.of(role);
      final santai = p.tone == AgentTone.santai;
      final me = santai ? 'Aku ${p.displayName}' : 'Saya ${p.displayName}';
      return switch (role) {
        AgentRole.data => '$greeting! $me. Kirim CSV/Excel, ${santai ? 'aku' : 'saya'} validasi dulu.',
        AgentRole.analyst => '$greeting! $me. KPI ${santai ? 'kuhitung' : 'saya hitung'} dengan kode, bukan tebakan.',
        AgentRole.strategist => '$greeting! $me, siap menafsirkan angka jadi rekomendasi.',
        AgentRole.reporter => '$greeting! $me, siap menyusun notulen dan laporan.',
      };
    }

    for (final role in AgentRole.values.where((r) => profiles.of(r).greets)) {
      _say(role, line(role), source: null, hold: const Duration(seconds: 6));
      await Future<void>.delayed(const Duration(milliseconds: 900));
    }
  }

  /// Perintah pengguna ke satu agent atau seluruh tim. Agent boleh
  /// mendelegasikan ke rekan (satu tingkat) lewat JSON `delegate`.
  Future<void> command(ChatTarget target, String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || busy) return;
    commanding = true;
    _cancelled = false;
    _cancel = CancelToken();
    chat.add(ChatMessage.user(trimmed, target: target));
    notifyListeners();
    try {
      final roles = target.isTeam ? AgentRole.values.where((r) => profiles.of(r).joinsTeam).toList() : [target.role!];
      if (roles.isEmpty) _log('Tidak ada agent yang diatur untuk menjawab perintah tim.');
      for (final role in roles) {
        _checkCancelled();
        await _respond(role, trimmed, fromUser: true, allowDelegate: true);
      }
    } catch (e) {
      if (!_cancelled) _log('Perintah gagal: ${_short('$e')}');
    } finally {
      commanding = false;
      notifyListeners();
    }
  }

  Future<void> _respond(AgentRole role, String instruction, {required bool fromUser, required bool allowDelegate}) async {
    await _gate();
    final profile = profiles.of(role);
    final mayDelegate = allowDelegate && profile.canDelegate;
    _set(role, state: AgentState.waitingLlm, activity: fromUser ? 'Menjawab perintah pengguna' : 'Mengerjakan tugas dari rekan');
    game.send(SetState(role, AgentState.waitingLlm));
    _beginStreaming(role);

    final facts = data?.ok == true ? 'Fakta agregat dataset (dihitung kode): ${jsonEncode(data!.toFacts())}' : 'Belum ada dataset yang dianalisis.';
    final peers = AgentRole.values.where((r) => r != role && profiles.of(r).acceptsDelegation).toList();
    final roster = peers.map((r) => '${r.title} (${r.duty})').join(', ');
    final system = 'Kamu agent "${profile.displayName}" (peran ${role.title}) di kantor AI Agent HQ; tugasmu: ${role.duty}. '
        '${peers.isEmpty ? 'Tidak ada rekan yang bisa menerima tugas.' : 'Rekan tim: $roster.'} '
        'Jawab dalam bahasa Indonesia. ${profile.styleInstruction} '
        'Spesifik, tanpa mengarang angka atau kolom yang tidak ada di fakta. '
        '${mayDelegate && peers.isNotEmpty ? 'Jika sebagian tugas lebih cocok untuk rekan, delegasikan lewat "delegate" (maksimal 2 rekan, pakai nama peran, tugas singkat dan jelas); jika tidak, kosongkan.' : 'Jangan mendelegasikan; "delegate" harus [].'} '
        'Balas HANYA JSON valid: {"reply": "...", "delegate": [{"agent": "<nama peran rekan>", "task": "..."}]}';
    final request = AiRequest(
      messages: [AiMessage.system(system), AiMessage.user('$facts\n\n${fromUser ? 'Perintah pengguna' : 'Instruksi'}: $instruction')],
      maxTokens: profile.maxTokens + 60,
      temperature: profile.temperature,
    );

    String reply;
    String? source;
    var delegates = const <({AgentRole agent, String task})>[];
    final watch = Stopwatch()..start();
    try {
      source = ai.providerIdFor(role);
      final buffer = StringBuffer();
      await for (final chunk in ai.chat(role, request, cancel: _cancel, onFallback: (id, _) => source = id)) {
        buffer.write(chunk.text);
        streaming = buffer.toString();
        notifyListeners();
      }
      final parsed = _parseCommandReply(buffer.toString(), role);
      reply = parsed.reply;
      if (mayDelegate) delegates = parsed.delegates.where((d) => profiles.of(d.agent).acceptsDelegation).toList();
      if (reply.isEmpty) throw const AiProviderException('Jawaban model kosong');
    } catch (e) {
      if (_cancelled) rethrow;
      source = null;
      reply = 'Model belum tersedia, perintah ${profile.tone == AgentTone.santai ? 'kucatat' : 'saya catat'}: "$instruction". '
          '${data?.ok == true ? 'Dataset aktif: ${data!.sourceName}, ${data!.rows} baris valid.' : 'Belum ada dataset untuk dikerjakan.'}';
    } finally {
      _endStreaming();
    }
    watch.stop();
    final timing = _timingFor(source, watch.elapsedMilliseconds);

    _say(role, reply, source: source, hold: Duration(milliseconds: (2500 + reply.length * 35).clamp(3000, 9000)), timing: timing);
    _set(
      role,
      state: AgentState.working,
      activity: fromUser ? 'Menjawab perintah pengguna' : 'Tugas dari rekan selesai',
      providerId: source,
      lastDurationMs: timing.durationMs,
      lastTokensPerSecond: timing.tokensPerSecond,
    );
    await _delay(const Duration(milliseconds: 1200));

    for (final d in delegates) {
      _checkCancelled();
      chat.add(ChatMessage.system('${role.title} → ${d.agent.title}: ${d.task}'));
      _set(d.agent, state: AgentState.assigned, activity: 'Menerima tugas dari ${role.title}');
      notifyListeners();
      await _respond(d.agent, 'Dari ${role.title}: ${d.task}', fromUser: false, allowDelegate: false);
    }
    _set(role, state: AgentState.idle, activity: 'Siap menerima perintah');
  }

  ({String reply, List<({AgentRole agent, String task})> delegates}) _parseCommandReply(String raw, AgentRole self) {
    final text = raw.trim();
    final start = text.indexOf('{');
    final end = text.lastIndexOf('}');
    if (start >= 0 && end > start) {
      try {
        final map = jsonDecode(text.substring(start, end + 1)) as Map<String, Object?>;
        final reply = (map['reply'] as String?)?.trim() ?? '';
        final delegates = <({AgentRole agent, String task})>[];
        for (final item in (map['delegate'] as List? ?? const []).take(2)) {
          if (item is! Map) continue;
          final name = (item['agent'] as String? ?? '').toLowerCase();
          final task = (item['task'] as String? ?? '').trim();
          final role = AgentRole.values.where((r) => r.title.toLowerCase() == name).firstOrNull;
          if (role == null || role == self || task.isEmpty) continue;
          delegates.add((agent: role, task: task));
        }
        return (reply: reply, delegates: delegates);
      } on FormatException {
        // Jatuh ke teks mentah di bawah.
      } on TypeError {
        // Bentuk JSON tidak sesuai; pakai teks mentah.
      }
    }
    return (reply: text.replaceAll(RegExp(r'[{}"]'), '').trim(), delegates: const []);
  }

  void _beginStreaming(AgentRole role) {
    streaming = '';
    streamingAgent = role;
    streamingStartedAt = DateTime.now();
    notifyListeners();
  }

  void _endStreaming() {
    streaming = '';
    streamingAgent = null;
    streamingStartedAt = null;
  }

  /// Durasi + tokens/s (hanya tersedia untuk model lokal lewat statistik llama.cpp).
  ({int durationMs, double? tokensPerSecond}) _timingFor(String? source, int elapsedMs) {
    double? tps;
    if (source == ProviderConfig.localId) {
      final stats = ai.localEngine.lastStats;
      for (final key in const ['gen_tokens_per_s', 'generation_tokens_per_second', 'tokens_per_second', 'output_tokens_per_s']) {
        final v = stats[key];
        if (v is num && v > 0) {
          tps = v.toDouble();
          break;
        }
      }
      if (tps != null) perf?.updateTokensPerSecond(tps);
    }
    return (durationMs: elapsedMs, tokensPerSecond: tps);
  }

  /// Bubble bicara di game + pesan chat; bubble dihapus setelah [hold].
  void _say(
    AgentRole role,
    String text, {
    required String? source,
    required Duration hold,
    ({int durationMs, double? tokensPerSecond})? timing,
  }) {
    chat.add(ChatMessage.agent(role, text, source: source, durationMs: timing?.durationMs, tokensPerSecond: timing?.tokensPerSecond));
    game.send(SetState(role, AgentState.talking));
    game.send(Speak(role, text));
    _speechTimers[role]?.cancel();
    _speechTimers[role] = Timer(hold, () {
      game.send(Speak(role, ''));
      if (agents[role]!.state == AgentState.talking) game.send(SetState(role, agents[role]!.state));
    });
    notifyListeners();
  }

  // ---------------------------------------------------------------- controls

  void select(AgentRole role) {
    selected = role;
    game.send(SelectAgent(role));
    notifyListeners();
  }

  void setPaused(bool value) {
    paused = value;
    game.send(SetPaused(value));
    for (final r in AgentRole.values) {
      if (value) {
        _set(r, state: AgentState.paused);
      }
    }
    if (!value) {
      _resume?.complete();
      _resume = null;
    } else {
      _resume ??= Completer<void>();
    }
    notifyListeners();
  }

  void setSpeed(int value) {
    speed = value.clamp(1, 2);
    game.send(SetSpeed(speed));
    _log('Kecepatan animasi x$speed (tidak memengaruhi model)');
    notifyListeners();
  }

  void resetCamera() => game.send(const ResetCamera());

  Future<void> cancelMission() async {
    if (!busy) return;
    _cancelled = true;
    _cancel?.cancel();
    for (final c in _arrivals.values) {
      if (!c.isCompleted) c.complete();
    }
    if (_seated case final s? when !s.isCompleted) s.complete();
    _resume?.complete();
    _resume = null;
  }

  // ---------------------------------------------------------------- missions

  /// Meeting demo tanpa data (seperti Fase 1): dialog template.
  Future<void> startDemoMeeting() async {
    if (busy) return;
    _begin(null);
    _log('Meeting demo dipanggil. Tidak memakai data pengguna atau model.');
    try {
      await _runMeeting([
        const MeetingLine(AgentRole.data, 'Pemeriksaan data siap. Ini dialog demo; belum ada file pengguna yang dianalisis.'),
        const MeetingLine(AgentRole.analyst, 'KPI akan dihitung oleh kode. Belum ada angka penjualan pada demo ini.'),
        const MeetingLine(AgentRole.strategist, 'Kita perlu memeriksa mapping kolom sebelum menyimpulkan hasil.'),
        const MeetingLine(AgentRole.reporter, 'Notulen demo selesai. Tahap berikutnya: impor CSV dan validasi hasil.'),
      ]);
      report = 'DEMO - bukan hasil analisis file / model.\n\n${transcript.map((l) => '${l.agent.title}: ${l.text}').join('\n\n')}';
      _finish();
    } catch (e) {
      _fail('$e');
    }
  }

  /// Misi penuh berdasarkan hasil analisis yang sudah dihitung.
  Future<void> startMission(AnalysisResult result) async {
    if (busy || !result.ok) return;
    _begin(result);
    _log('Misi dimulai untuk ${result.sourceName}.');
    try {
      // 1. Data
      phase = MissionPhase.dataPrep;
      await _dispatch(AgentRole.data, OfficeRoom.data, 'Memvalidasi skema dan baris');
      await _work(AgentRole.data, seconds: 2);
      final dataLine = _dataStatement(result);
      _set(AgentRole.data, state: AgentState.review, activity: 'Validasi selesai');
      _checkCancelled();

      // 2. Analyst
      phase = MissionPhase.analysis;
      notifyListeners();
      await _dispatch(AgentRole.analyst, OfficeRoom.analysis, 'Menghitung KPI secara deterministik');
      await _work(AgentRole.analyst, seconds: 2);
      final analystLine = _analystStatement(result);
      _set(AgentRole.analyst, state: AgentState.review, activity: 'KPI siap');
      _checkCancelled();

      // 3. Strategist (LLM, fallback template)
      phase = MissionPhase.strategy;
      notifyListeners();
      await _dispatch(AgentRole.strategist, OfficeRoom.analysis, 'Membaca hasil KPI');
      final strategist = await _askModel(
        AgentRole.strategist,
        system: 'Kamu Agent Strategist di kantor AI. Jawab dalam bahasa Indonesia, maksimal 4 kalimat, '
            'berdasarkan fakta agregat yang diberikan. Jangan mengarang angka, kolom, atau tren yang tidak ada. '
            'Sebutkan 1 risiko dan 1 rekomendasi yang spesifik. Jika data kurang, sebutkan apa yang kurang.',
        user: 'Fakta agregat (dihitung kode): ${jsonEncode(result.toFacts())}\nTugas: interpretasi dan rekomendasi.',
        fallback: () => DataAdvisor.suggestions(result),
        maxTokens: 220,
      );
      _set(AgentRole.strategist, state: AgentState.review, activity: 'Interpretasi siap');
      _checkCancelled();

      // 4. Meeting
      phase = MissionPhase.meeting;
      notifyListeners();
      await _runMeeting([
        MeetingLine(AgentRole.data, dataLine),
        MeetingLine(AgentRole.analyst, analystLine),
        MeetingLine(AgentRole.strategist, strategist.text, source: strategist.source),
        MeetingLine(AgentRole.reporter, 'Saya catat keputusan dan action items, lalu menyusun laporan di Ruang Laporan.'),
      ]);
      _checkCancelled();

      // 5. Reporter (LLM, fallback template)
      phase = MissionPhase.report;
      notifyListeners();
      await _dispatch(AgentRole.reporter, OfficeRoom.report, 'Menyusun notulen dan laporan');
      final reporter = await _askModel(
        AgentRole.reporter,
        system: 'Kamu Agent Reporter. Tulis notulen rapat singkat dalam bahasa Indonesia dengan format:\n'
            'RINGKASAN (2 kalimat)\nKEPUTUSAN (poin)\nACTION ITEMS (poin dengan penanggung jawab: Data/Analyst/Strategist)\n'
            'KETERBATASAN DATA (poin). Gunakan hanya angka dari fakta; tulis angka apa adanya tanpa mengubah nilainya.',
        user: 'Fakta agregat: ${jsonEncode(result.toFacts())}\n'
            'Transkrip rapat:\n${transcript.map((l) => '${l.agent.title}: ${l.text}').join('\n')}',
        fallback: () => _templateReport(result),
        maxTokens: 320,
      );
      report = '${reporter.text}\n\n— Sumber angka: ${result.sourceName}, ${result.rows} baris valid, '
          '${result.skipped} dilewati. Narasi: ${reporter.source ?? 'template lokal (tanpa model)'}.';
      _set(AgentRole.reporter, state: AgentState.done, activity: 'Laporan tersimpan', providerId: reporter.source);
      _finish();
    } catch (e) {
      _fail('$e');
    }
  }

  // ---------------------------------------------------------------- steps

  void _begin(AnalysisResult? result) {
    _cancelled = false;
    _cancel = CancelToken();
    data = result;
    missionId = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
    transcript.clear();
    report = '';
    streaming = '';
    streamingAgent = null;
    phase = MissionPhase.dataPrep;
    for (final r in AgentRole.values) {
      _set(r, state: AgentState.assigned, activity: 'Menerima penugasan misi');
    }
    notifyListeners();
  }

  Future<void> _dispatch(AgentRole role, OfficeRoom room, String activity) async {
    await _gate();
    _set(role, state: AgentState.walking, activity: 'Berjalan ke ${room.label}');
    game.send(SetState(role, AgentState.walking));
    game.send(WalkTo.room(role, room));
    await _awaitArrival(role);
    _set(role, state: AgentState.working, activity: activity, roomIndex: room.index);
    game.send(SetState(role, AgentState.working));
  }

  Future<void> _work(AgentRole role, {required int seconds}) async {
    _set(role, state: AgentState.waitingTool, activity: 'Menjalankan tool perhitungan');
    await _delay(Duration(seconds: seconds));
  }

  Future<void> _runMeeting(List<MeetingLine> lines) async {
    await _gate();
    for (final r in AgentRole.values) {
      _set(r, state: AgentState.walking, activity: 'Menuju kursi meeting');
      game.send(SetState(r, AgentState.walking));
    }
    _seated = Completer<void>();
    game.send(const SetMeeting(true));
    _log('Meeting dipanggil. Empat kursi dipesan.');
    await _seated!.future.timeout(const Duration(seconds: 20), onTimeout: () {});
    _checkCancelled();
    for (final r in AgentRole.values) {
      _set(r, state: AgentState.meeting, activity: 'Duduk dan menunggu giliran', roomIndex: OfficeRoom.meeting.index);
      game.send(SetState(r, AgentState.meeting));
    }
    for (final line in lines) {
      await _gate();
      _checkCancelled();
      _set(line.agent, state: AgentState.talking, activity: 'Menyampaikan pembaruan', providerId: line.source);
      game.send(SetState(line.agent, AgentState.talking));
      game.send(Speak(line.agent, line.text));
      transcript.add(line);
      chat.add(ChatMessage.agent(line.agent, line.text, source: line.source));
      notifyListeners();
      final words = line.text.split(RegExp(r'\s+')).length;
      await _delay(Duration(milliseconds: (2500 + words * 180).clamp(3000, 9000)));
      game.send(Speak(line.agent, ''));
      _set(line.agent, state: AgentState.meeting, activity: 'Mendengarkan rekan');
      game.send(SetState(line.agent, AgentState.meeting));
    }
    game.send(const SetMeeting(false));
    for (final r in AgentRole.values) {
      _set(r, state: AgentState.walking, activity: 'Kembali ke meja kerja');
      _arrivals[r] = Completer<void>();
    }
    await Future.wait(AgentRole.values.map(_awaitArrival));
    for (final r in AgentRole.values) {
      _set(r, state: AgentState.review, activity: 'Kembali di meja kerja', roomIndex: r.homeRoom.index);
      game.send(SetState(r, AgentState.review));
    }
    _log('Meeting selesai.');
  }

  Future<({String text, String? source})> _askModel(
    AgentRole role, {
    required String system,
    required String user,
    required String Function() fallback,
    required int maxTokens,
  }) async {
    await _gate();
    _set(role, state: AgentState.waitingLlm, activity: 'Menunggu jawaban model');
    game.send(SetState(role, AgentState.waitingLlm));
    _beginStreaming(role);
    final profile = profiles.of(role);
    final request = AiRequest(
      messages: [AiMessage.system('$system ${profile.styleInstruction}'), AiMessage.user(user)],
      maxTokens: maxTokens,
      temperature: profile.temperature,
    );
    String? source;
    final watch = Stopwatch()..start();
    try {
      source = ai.providerIdFor(role);
      final buffer = StringBuffer();
      await for (final chunk in ai.chat(
        role,
        request,
        missionId: missionId,
        cancel: _cancel,
        onFallback: (providerId, reason) {
          source = providerId;
          _log('${role.title}: beralih ke $providerId ($reason)');
        },
      )) {
        if (chunk.text.isNotEmpty) {
          buffer.write(chunk.text);
          streaming = buffer.toString();
          notifyListeners();
        }
      }
      final text = buffer.toString().trim();
      if (text.isEmpty) throw const AiProviderException('Jawaban model kosong');
      watch.stop();
      final timing = _timingFor(source, watch.elapsedMilliseconds);
      _set(
        role,
        state: AgentState.working,
        activity: 'Jawaban model diterima (${(timing.durationMs / 1000).toStringAsFixed(1)} s)',
        providerId: source,
        lastDurationMs: timing.durationMs,
        lastTokensPerSecond: timing.tokensPerSecond,
      );
      return (text: text, source: source);
    } catch (e) {
      if (_cancelled) rethrow;
      _log('${role.title}: model tidak tersedia (${_short('$e')}); memakai template lokal.');
      final text = fallback();
      _set(role, state: AgentState.working, activity: 'Memakai template lokal', providerId: null);
      return (text: text, source: null);
    } finally {
      _endStreaming();
      notifyListeners();
    }
  }

  // ---------------------------------------------------------------- templates

  String _dataStatement(AnalysisResult r) {
    final mapping = r.mapping.hasRevenue
        ? 'kolom omzet "${r.headers[r.mapping.revenue]}"'
        : 'qty "${r.headers[r.mapping.quantity]}" × harga "${r.headers[r.mapping.price]}"';
    final date = r.hasDate ? 'kolom tanggal "${r.headers[r.mapping.date]}"' : 'tanpa kolom tanggal';
    return 'File ${r.sourceName}: ${r.rows} baris valid, ${r.skipped} dilewati. Omzet dari $mapping, $date.'
        '${r.warnings.isNotEmpty ? ' Catatan: ${r.warnings.first}' : ''}';
  }

  String _analystStatement(AnalysisResult r) {
    final top = r.products.isNotEmpty ? '${r.products.first.name} (Rp ${DataAdvisor.formatRupiah(r.products.first.value)})' : '-';
    final months = r.sortedMonths;
    var trend = 'Tren bulanan belum bisa dihitung.';
    if (months.length >= 2) {
      final a = r.months[months[months.length - 2]]!;
      final b = r.months[months.last]!;
      final pct = a == 0 ? 0 : (b - a) / a.abs() * 100;
      trend = 'Omzet ${months.last} ${pct >= 0 ? 'naik' : 'turun'} ${pct.abs().toStringAsFixed(1)}% dibanding ${months[months.length - 2]}.';
    }
    return 'Total omzet Rp ${DataAdvisor.formatRupiah(r.total)}, rata-rata Rp ${DataAdvisor.formatRupiah(r.average)} per baris. '
        'Produk teratas: $top. $trend';
  }

  String _templateReport(AnalysisResult r) => 'RINGKASAN\n${_analystStatement(r)}\n\n'
      'KEPUTUSAN\n• Angka KPI di atas dipakai sebagai acuan; narasi model tidak tersedia pada misi ini.\n\n'
      'ACTION ITEMS\n• Data: tinjau ${r.skipped} baris yang dilewati.\n• Analyst: pantau tren bulanan berikutnya.\n'
      '• Strategist: ${DataAdvisor.suggestions(r).split('\n').first.replaceFirst('• ', '')}\n\n'
      'KETERBATASAN DATA\n${DataAdvisor.suggestions(r)}';

  // ---------------------------------------------------------------- plumbing

  void _onGameEvent(GameEvent event) {
    switch (event) {
      case AgentArrived(:final agent, :final roomIndex):
        agents[agent] = agents[agent]!.copyWith(roomIndex: roomIndex);
        _arrivals[agent]?.complete();
        _arrivals.remove(agent);
        notifyListeners();
      case MeetingSeated():
        if (_seated case final s? when !s.isCompleted) s.complete();
      case AgentTapped(:final agent):
        select(agent);
        onAgentTapped?.call(agent);
      case GameStats(:final fps, :final frameMs, :final gpu):
        perf?.updateUnity(fps: fps, frameMs: frameMs, gpu: gpu);
      case GameError(:final message):
        _log('Unity: $message');
        notifyListeners();
      case GameReady():
        _log('Tampilan kantor siap.');
        notifyListeners();
        if (!missionRunning) unawaited(greet());
      case RoomTapped():
        break;
    }
  }

  Future<void> _awaitArrival(AgentRole role) async {
    final completer = _arrivals.putIfAbsent(role, Completer<void>.new);
    await completer.future.timeout(const Duration(seconds: 15), onTimeout: () {
      _arrivals.remove(role);
    });
  }

  Future<void> _delay(Duration d) async {
    var remaining = d.inMilliseconds;
    while (remaining > 0) {
      await _gate();
      _checkCancelled();
      final step = remaining < 100 ? remaining : 100;
      await Future<void>.delayed(Duration(milliseconds: step));
      remaining -= step * speed;
    }
  }

  Future<void> _gate() async {
    while (paused && !_cancelled) {
      _resume ??= Completer<void>();
      await _resume!.future;
    }
  }

  void _checkCancelled() {
    if (_cancelled) throw const _MissionCancelled();
  }

  void _set(
    AgentRole role, {
    AgentState? state,
    String? activity,
    int? roomIndex,
    String? providerId,
    int? lastDurationMs,
    double? lastTokensPerSecond,
  }) {
    agents[role] = agents[role]!.copyWith(
      state: state,
      activity: activity,
      roomIndex: roomIndex,
      providerId: providerId,
      lastDurationMs: lastDurationMs,
      lastTokensPerSecond: lastTokensPerSecond,
    );
    if (state != null) game.send(SetState(role, state));
    notifyListeners();
  }

  void _finish() {
    phase = MissionPhase.done;
    for (final r in AgentRole.values) {
      _set(r, state: AgentState.done, activity: 'Misi selesai');
    }
    _log('Misi selesai. Laporan tersedia.');
    final record = MissionRecord(
      id: missionId ?? '-',
      startedAt: DateTime.now(),
      sourceName: data?.sourceName ?? 'demo',
      transcript: List.unmodifiable(transcript),
      report: report,
      facts: data?.toFacts() ?? const {},
    );
    onPersist?.call(record);
    notifyListeners();
  }

  void _fail(String reason) {
    phase = MissionPhase.failed;
    final message = _cancelled ? 'Misi dibatalkan.' : 'Misi gagal: ${_short(reason)}';
    _log(message);
    for (final r in AgentRole.values) {
      _set(r, state: _cancelled ? AgentState.idle : AgentState.failed, activity: message);
    }
    game.send(const SetMeeting(false));
    notifyListeners();
  }

  void _log(String message) {
    final now = DateTime.now();
    log.add('${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}  $message');
    if (log.length > 200) log.removeAt(0);
    chat.add(ChatMessage.system(message));
    if (chat.length > 400) chat.removeAt(0);
  }

  static String _short(String s) => s.length > 120 ? '${s.substring(0, 117)}…' : s;

  @override
  void dispose() {
    _sub.cancel();
    for (final t in _speechTimers.values) {
      t.cancel();
    }
    super.dispose();
  }
}

void unawaited(Future<void> f) {}

class _MissionCancelled implements Exception {
  const _MissionCancelled();
  @override
  String toString() => 'Misi dibatalkan';
}
