/// Pengaturan AI (mode, provider, penugasan per agent) + persistensi.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../agents/agent_role.dart';
import 'ai_provider.dart';

@immutable
class AiSettings {
  const AiSettings({
    this.mode = AiMode.offlineOnly,
    this.providers = const [],
    this.assignment = const {},
    this.allowInsecureLan = false,
    this.contextLength = 2048,
    this.threads = 4,
    this.maxTokens = 256,
    this.useGpu = false,
    this.gpuLayers = 99,
  });

  final AiMode mode;

  /// Provider remote yang ditambahkan pengguna (tanpa provider lokal).
  final List<ProviderConfig> providers;

  /// Role → providerId. Role yang tidak ada dianggap lokal.
  final Map<AgentRole, String> assignment;
  final bool allowInsecureLan;
  final int contextLength;
  final int threads;
  final int maxTokens;

  /// Backend inferensi lokal: false = CPU (default aman), true = GPU Vulkan
  /// (eksperimental, per perangkat; keputusan berdasarkan benchmark).
  final bool useGpu;

  /// Layer yang di-offload ke GPU bila [useGpu]; 99 = semua layer.
  final int gpuLayers;

  /// Nilai [gpuLayers] yang berarti "semua layer".
  static const allGpuLayers = 99;

  /// Layer GPU efektif yang dikirim ke engine (0 bila CPU).
  int get effectiveGpuLayers => useGpu ? gpuLayers : 0;

  static const defaults = AiSettings();

  /// Semua provider termasuk lokal (selalu pertama).
  List<ProviderConfig> get allProviders => [ProviderConfig.local, ...providers];

  ProviderConfig? providerById(String id) {
    if (id == ProviderConfig.localId) return ProviderConfig.local;
    for (final p in providers) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// Id yang ditugaskan untuk [role]; jatuh ke lokal bila tidak ada/nonaktif.
  String assignedProviderId(AgentRole role) {
    final id = assignment[role] ?? ProviderConfig.localId;
    final cfg = providerById(id);
    if (cfg == null || !cfg.enabled) return ProviderConfig.localId;
    return id;
  }

  AiSettings copyWith({
    AiMode? mode,
    List<ProviderConfig>? providers,
    Map<AgentRole, String>? assignment,
    bool? allowInsecureLan,
    int? contextLength,
    int? threads,
    int? maxTokens,
    bool? useGpu,
    int? gpuLayers,
  }) =>
      AiSettings(
        mode: mode ?? this.mode,
        providers: providers ?? this.providers,
        assignment: assignment ?? this.assignment,
        allowInsecureLan: allowInsecureLan ?? this.allowInsecureLan,
        contextLength: contextLength ?? this.contextLength,
        threads: threads ?? this.threads,
        maxTokens: maxTokens ?? this.maxTokens,
        useGpu: useGpu ?? this.useGpu,
        gpuLayers: gpuLayers ?? this.gpuLayers,
      );

  AiSettings upsertProvider(ProviderConfig cfg) {
    final list = [...providers];
    final i = list.indexWhere((p) => p.id == cfg.id);
    if (i < 0) {
      list.add(cfg);
    } else {
      list[i] = cfg;
    }
    return copyWith(providers: list);
  }

  /// Menghapus provider dan melepas penugasan yang mengarah padanya.
  AiSettings removeProvider(String id) => copyWith(
        providers: providers.where((p) => p.id != id).toList(),
        assignment: {
          for (final e in assignment.entries)
            if (e.value != id) e.key: e.value,
        },
      );

  AiSettings assign(AgentRole role, String providerId) => copyWith(assignment: {...assignment, role: providerId});

  Map<String, Object?> toJson() => {
        'mode': mode.name,
        'providers': [for (final p in providers) p.toJson()],
        'assignment': {for (final e in assignment.entries) e.key.name: e.value},
        'allow_insecure_lan': allowInsecureLan,
        'context_length': contextLength,
        'threads': threads,
        'max_tokens': maxTokens,
        'use_gpu': useGpu,
        'gpu_layers': gpuLayers,
      };

  factory AiSettings.fromJson(Map<String, Object?> json) {
    final providers = <ProviderConfig>[];
    for (final p in (json['providers'] as List?) ?? const []) {
      if (p is Map) {
        final cfg = ProviderConfig.fromJson(p.cast<String, Object?>());
        if (cfg.id != ProviderConfig.localId) providers.add(cfg);
      }
    }
    final assignment = <AgentRole, String>{};
    final rawAssign = json['assignment'];
    if (rawAssign is Map) {
      rawAssign.forEach((k, v) {
        final role = AgentRole.values.where((r) => r.name == k).firstOrNull;
        if (role != null && v is String) assignment[role] = v;
      });
    }
    AiMode mode;
    try {
      mode = AiMode.values.byName(json['mode'] as String);
    } catch (_) {
      mode = AiMode.offlineOnly;
    }
    return AiSettings(
      mode: mode,
      providers: providers,
      assignment: assignment,
      allowInsecureLan: (json['allow_insecure_lan'] as bool?) ?? false,
      contextLength: (json['context_length'] as int?) ?? 2048,
      threads: (json['threads'] as int?) ?? 4,
      maxTokens: (json['max_tokens'] as int?) ?? 256,
      useGpu: (json['use_gpu'] as bool?) ?? false,
      gpuLayers: (json['gpu_layers'] as int?) ?? allGpuLayers,
    );
  }

  @override
  bool operator ==(Object other) => other is AiSettings && jsonEncode(other.toJson()) == jsonEncode(toJson());

  @override
  int get hashCode => jsonEncode(toJson()).hashCode;
}

/// Menyimpan [AiSettings] di SharedPreferences (satu kunci JSON). UI dapat
/// mendengarkan perubahan lewat [ValueNotifier].
class AiSettingsStore extends ValueNotifier<AiSettings> {
  AiSettingsStore(this._prefs, {this.prefsKey = defaultPrefsKey}) : super(_load(_prefs, defaultPrefsKey));

  static const defaultPrefsKey = 'agenthq.ai_settings';
  final SharedPreferences _prefs;
  final String prefsKey;

  AiSettings get settings => value;

  static AiSettings _load(SharedPreferences prefs, String key) {
    final raw = prefs.getString(key);
    if (raw == null || raw.isEmpty) return AiSettings.defaults;
    try {
      return AiSettings.fromJson((jsonDecode(raw) as Map).cast<String, Object?>());
    } catch (_) {
      return AiSettings.defaults;
    }
  }

  /// Memuat ulang dari disk (mis. setelah restore).
  void reload() => value = _load(_prefs, prefsKey);

  /// Konstruktor sudah memuat secara sinkron; disediakan untuk simetri API.
  Future<void> load() async => reload();

  Future<void> save(AiSettings settings) async {
    value = settings;
    await _prefs.setString(prefsKey, jsonEncode(settings.toJson()));
  }

  Future<void> update(AiSettings Function(AiSettings current) fn) => save(fn(value));

  Future<void> reset() async {
    value = AiSettings.defaults;
    await _prefs.remove(prefsKey);
  }
}
