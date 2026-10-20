/// Pengaturan perilaku per agent yang bisa diubah pengguna (disimpan lokal).
///
/// Aturan yang TIDAK bisa dimatikan tetap ada di prompt orchestrator:
/// tidak mengarang angka, KPI hanya dari hasil perhitungan kode.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'agent_role.dart';

enum AgentTone {
  formal('Formal', 'Gunakan bahasa Indonesia baku yang sopan dan lugas.'),
  santai('Santai', 'Gunakan bahasa Indonesia santai dan ramah (boleh "aku/kamu"), tetap profesional.'),
  teknis('Teknis', 'Gunakan istilah teknis analisis data secara presisi; sebutkan metode perhitungan bila relevan.');

  const AgentTone(this.label, this.instruction);
  final String label;
  final String instruction;
}

enum AgentVerbosity {
  ringkas('Ringkas', 'Maksimal 2 kalimat.', 160),
  detail('Detail', 'Maksimal 5 kalimat, boleh memakai poin singkat.', 320);

  const AgentVerbosity(this.label, this.instruction, this.defaultMaxTokens);
  final String label;
  final String instruction;
  final int defaultMaxTokens;
}

class AgentProfile {
  const AgentProfile({
    required this.role,
    this.nickname = '',
    this.tone = AgentTone.formal,
    this.verbosity = AgentVerbosity.ringkas,
    this.instructions = '',
    this.canDelegate = true,
    this.acceptsDelegation = true,
    this.greets = true,
    this.joinsTeam = true,
    this.temperature = 0.3,
    this.maxTokensOverride,
  });

  final AgentRole role;
  final String nickname;
  final AgentTone tone;
  final AgentVerbosity verbosity;

  /// Instruksi khusus pengguna, ditambahkan ke system prompt.
  final String instructions;
  final bool canDelegate;
  final bool acceptsDelegation;
  final bool greets;

  /// Ikut menjawab saat perintah ditujukan ke "Tim".
  final bool joinsTeam;
  final double temperature;

  /// Null = ikuti bawaan [verbosity].
  final int? maxTokensOverride;

  int get maxTokens => maxTokensOverride ?? verbosity.defaultMaxTokens;
  String get displayName => nickname.trim().isEmpty ? role.title : nickname.trim();
  bool get isDefault => this == AgentProfile(role: role);

  /// Potongan system prompt yang menggambarkan gaya agent ini.
  String get styleInstruction =>
      '${tone.instruction} ${verbosity.instruction}${instructions.trim().isEmpty ? '' : ' Instruksi tambahan dari pengguna: ${instructions.trim()}'}';

  AgentProfile copyWith({
    String? nickname,
    AgentTone? tone,
    AgentVerbosity? verbosity,
    String? instructions,
    bool? canDelegate,
    bool? acceptsDelegation,
    bool? greets,
    bool? joinsTeam,
    double? temperature,
    int? maxTokens,
    bool resetMaxTokens = false,
  }) =>
      AgentProfile(
        role: role,
        nickname: nickname ?? this.nickname,
        tone: tone ?? this.tone,
        verbosity: verbosity ?? this.verbosity,
        instructions: instructions ?? this.instructions,
        canDelegate: canDelegate ?? this.canDelegate,
        acceptsDelegation: acceptsDelegation ?? this.acceptsDelegation,
        greets: greets ?? this.greets,
        joinsTeam: joinsTeam ?? this.joinsTeam,
        temperature: temperature ?? this.temperature,
        maxTokensOverride: resetMaxTokens ? null : (maxTokens ?? maxTokensOverride),
      );

  Map<String, Object?> toJson() => {
        'role': role.name,
        'nickname': nickname,
        'tone': tone.name,
        'verbosity': verbosity.name,
        'instructions': instructions,
        'can_delegate': canDelegate,
        'accepts_delegation': acceptsDelegation,
        'greets': greets,
        'joins_team': joinsTeam,
        'temperature': temperature,
        'max_tokens': maxTokensOverride,
      };

  factory AgentProfile.fromJson(Map<String, Object?> j) => AgentProfile(
        role: AgentRole.values.byName(j['role'] as String),
        nickname: (j['nickname'] as String?) ?? '',
        tone: AgentTone.values.byName((j['tone'] as String?) ?? 'formal'),
        verbosity: AgentVerbosity.values.byName((j['verbosity'] as String?) ?? 'ringkas'),
        instructions: (j['instructions'] as String?) ?? '',
        canDelegate: (j['can_delegate'] as bool?) ?? true,
        acceptsDelegation: (j['accepts_delegation'] as bool?) ?? true,
        greets: (j['greets'] as bool?) ?? true,
        joinsTeam: (j['joins_team'] as bool?) ?? true,
        temperature: ((j['temperature'] as num?) ?? 0.3).toDouble(),
        maxTokensOverride: j['max_tokens'] as int?,
      );

  @override
  bool operator ==(Object other) => other is AgentProfile && jsonEncode(other.toJson()) == jsonEncode(toJson());
  @override
  int get hashCode => jsonEncode(toJson()).hashCode;
}

class AgentProfileStore extends ChangeNotifier {
  AgentProfileStore(this._prefs) {
    _load();
  }

  static const prefsKey = 'agenthq.agent_profiles';
  final SharedPreferences _prefs;
  final Map<AgentRole, AgentProfile> _profiles = {for (final r in AgentRole.values) r: AgentProfile(role: r)};

  AgentProfile of(AgentRole role) => _profiles[role]!;
  Iterable<AgentProfile> get all => AgentRole.values.map(of);

  Future<void> save(AgentProfile profile) async {
    _profiles[profile.role] = profile;
    await _prefs.setString(prefsKey, jsonEncode(_profiles.values.map((p) => p.toJson()).toList()));
    notifyListeners();
  }

  Future<void> reset(AgentRole role) => save(AgentProfile(role: role));

  Future<void> resetAll() async {
    for (final r in AgentRole.values) {
      _profiles[r] = AgentProfile(role: r);
    }
    await _prefs.remove(prefsKey);
    notifyListeners();
  }

  void _load() {
    final raw = _prefs.getString(prefsKey);
    if (raw == null) return;
    try {
      for (final item in (jsonDecode(raw) as List).cast<Map<String, Object?>>()) {
        final p = AgentProfile.fromJson(item);
        _profiles[p.role] = p;
      }
    } catch (_) {
      // Data rusak: pakai bawaan.
    }
  }
}
