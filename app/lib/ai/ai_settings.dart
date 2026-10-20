/// Pengaturan AI (mode, provider, penugasan per agent) + persistensi.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../agents/agent_role.dart';
import 'ai_provider.dart';
import 'local/local_engine.dart';

export 'local/local_engine.dart' show LocalGpuBackend;

/// Preset pembagian beban GPU/CPU; dipetakan ke/dari [AiSettings.gpuLayers]
/// (satu sumber kebenaran), lihat [AiSettings.presetFor] / [AiSettings.layersForPreset].
enum GpuSplitPreset {
  cpu('CPU'),
  balanced('Seimbang (GPU+CPU)'),
  full('GPU penuh');

  const GpuSplitPreset(this.label);
  final String label;
}

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
    this.gpuBackend = LocalGpuBackend.cpu,
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

  /// Backend inferensi lokal: CPU (default aman), Vulkan atau OpenCL
  /// (eksperimental, per perangkat; keputusan berdasarkan benchmark).
  final LocalGpuBackend gpuBackend;

  /// true bila backend GPU dipilih (kompatibilitas dengan kode lama).
  bool get useGpu => gpuBackend.isGpu;

  /// Layer yang di-offload ke GPU bila [gpuBackend] GPU; 0 = CPU walau backend
  /// GPU dipilih, 99 = semua layer, di antaranya = hybrid GPU+CPU.
  final int gpuLayers;

  /// Nilai [gpuLayers] yang berarti "semua layer".
  static const allGpuLayers = 99;

  /// Layer GPU untuk preset seimbang bila jumlah layer model belum diketahui.
  static const defaultBalancedLayers = 18;

  /// Layer GPU efektif yang dikirim ke engine (0 bila CPU).
  int get effectiveGpuLayers => useGpu ? gpuLayers : 0;

  /// Preset untuk [gpuLayers]: 0 → CPU, >= 99 → GPU penuh, lainnya → seimbang.
  static GpuSplitPreset presetFor(int gpuLayers) {
    if (gpuLayers <= 0) return GpuSplitPreset.cpu;
    if (gpuLayers >= allGpuLayers) return GpuSplitPreset.full;
    return GpuSplitPreset.balanced;
  }

  /// [gpuLayers] untuk [preset]; seimbang = setengah `n_layer` model
  /// ([layerCount], dibulatkan ke atas, min 1) atau [defaultBalancedLayers]
  /// bila belum diketahui.
  static int layersForPreset(GpuSplitPreset preset, {int? layerCount}) => switch (preset) {
        GpuSplitPreset.cpu => 0,
        GpuSplitPreset.full => allGpuLayers,
        GpuSplitPreset.balanced =>
          layerCount == null || layerCount <= 0 ? defaultBalancedLayers : ((layerCount + 1) ~/ 2).clamp(1, allGpuLayers - 1),
      };

  GpuSplitPreset get gpuPreset => presetFor(gpuLayers);

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
    LocalGpuBackend? gpuBackend,
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
        gpuBackend: gpuBackend ?? this.gpuBackend,
        gpuLayers: gpuLayers ?? this.gpuLayers,
      );

  /// Menerapkan preset pembagian beban (mengubah hanya [gpuLayers]).
  AiSettings withGpuPreset(GpuSplitPreset preset, {int? layerCount}) =>
      copyWith(gpuLayers: layersForPreset(preset, layerCount: layerCount));

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
        'use_gpu': useGpu, // kompatibilitas mundur
        'gpu_backend': gpuBackend.name,
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
    // Migrasi: prefs lama hanya punya `use_gpu` (true = Vulkan).
    final rawBackend = json['gpu_backend'];
    final gpuBackend = rawBackend is String
        ? LocalGpuBackend.fromName(rawBackend)
        : ((json['use_gpu'] as bool?) ?? false ? LocalGpuBackend.vulkan : LocalGpuBackend.cpu);
    return AiSettings(
      mode: mode,
      providers: providers,
      assignment: assignment,
      allowInsecureLan: (json['allow_insecure_lan'] as bool?) ?? false,
      contextLength: (json['context_length'] as int?) ?? 2048,
      threads: (json['threads'] as int?) ?? 4,
      maxTokens: (json['max_tokens'] as int?) ?? 256,
      gpuBackend: gpuBackend,
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
