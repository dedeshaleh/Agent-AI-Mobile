/// Kontrak lapisan AI (PRD v1.1 §6.4).
///
/// Orchestrator dan UI hanya bicara lewat [AiProvider] dan `AiRouter`;
/// mereka tidak pernah memanggil HTTP atau FFI langsung.
library;

import 'dart:async';

enum AiProviderKind {
  local('Lokal (llama.cpp)'),
  openaiCompatible('OpenAI-compatible'),
  anthropic('Anthropic Claude'),
  gemini('Google Gemini'),
  custom('Custom / LAN');

  const AiProviderKind(this.label);
  final String label;
}

/// `offlineOnly` adalah default: tidak ada panggilan jaringan sama sekali.
enum AiMode {
  offlineOnly('Offline Only'),
  hybrid('Hybrid'),
  cloudPreferred('Cloud Preferred');

  const AiMode(this.label);
  final String label;
}

class AiMessage {
  const AiMessage(this.role, this.content);
  const AiMessage.system(String content) : this('system', content);
  const AiMessage.user(String content) : this('user', content);
  const AiMessage.assistant(String content) : this('assistant', content);

  /// `system`, `user`, atau `assistant`.
  final String role;
  final String content;

  Map<String, String> toJson() => {'role': role, 'content': content};
}

class AiRequest {
  const AiRequest({
    required this.messages,
    this.maxTokens = 256,
    this.temperature = 0.3,
    this.jsonSchema,
    this.stop = const [],
  });

  final List<AiMessage> messages;
  final int maxTokens;
  final double temperature;

  /// JSON Schema (sebagai map) bila jawaban harus berupa JSON terstruktur.
  /// Provider yang tidak mendukung schema boleh mengabaikannya; pemanggil
  /// tetap wajib memvalidasi hasilnya.
  final Map<String, Object?>? jsonSchema;
  final List<String> stop;
}

class AiUsage {
  const AiUsage({this.inputTokens = 0, this.outputTokens = 0});
  final int inputTokens;
  final int outputTokens;
}

class AiChunk {
  const AiChunk(this.text, {this.done = false, this.usage});
  const AiChunk.done({AiUsage? usage}) : this('', done: true, usage: usage);
  final String text;
  final bool done;

  /// Hanya diisi pada chunk terakhir bila provider melaporkannya.
  final AiUsage? usage;
}

class AiCapabilities {
  const AiCapabilities({
    this.streaming = true,
    this.jsonSchema = false,
    this.contextWindow = 2048,
  });
  final bool streaming;
  final bool jsonSchema;
  final int contextWindow;
}

class HealthResult {
  const HealthResult.ok([this.detail = 'Siap']) : healthy = true;
  const HealthResult.fail(this.detail) : healthy = false;
  final bool healthy;
  final String detail;
}

class CancelToken {
  bool _cancelled = false;
  final _controller = StreamController<void>.broadcast();
  bool get isCancelled => _cancelled;
  Stream<void> get onCancel => _controller.stream;
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _controller.add(null);
  }
}

/// Dilempar provider bila panggilan gagal; `retriable` memberi tahu router
/// apakah layak dicoba ulang sebelum fallback ke lokal.
class AiProviderException implements Exception {
  const AiProviderException(this.message, {this.statusCode, this.retriable = false});
  final String message;
  final int? statusCode;
  final bool retriable;
  @override
  String toString() => 'AiProviderException($statusCode): $message';
}

abstract class AiProvider {
  /// Sama dengan `ProviderConfig.id`; `local-llama` untuk provider lokal.
  String get id;
  String get displayName;
  bool get isLocal;
  AiCapabilities get caps;

  /// Stream token/teks. Chunk terakhir memiliki `done == true`.
  Stream<AiChunk> chat(AiRequest request, {CancelToken? cancel});

  Future<HealthResult> healthCheck();
}

/// Konfigurasi provider yang disimpan (tanpa API key — key ada di secure
/// storage dengan kunci `ProviderConfig.id`).
class ProviderConfig {
  const ProviderConfig({
    required this.id,
    required this.kind,
    required this.name,
    this.baseUrl = '',
    this.modelId = '',
    this.enabled = true,
    this.allowRawRows = false,
  });

  final String id;
  final AiProviderKind kind;
  final String name;

  /// Untuk `openaiCompatible`/`custom`: base URL tanpa path `/v1/...`.
  final String baseUrl;
  final String modelId;
  final bool enabled;

  /// Default `false`: hanya agregat yang boleh dikirim (§6.5).
  final bool allowRawRows;

  bool get needsApiKey => kind != AiProviderKind.local && kind != AiProviderKind.custom;

  ProviderConfig copyWith({
    String? name,
    String? baseUrl,
    String? modelId,
    bool? enabled,
    bool? allowRawRows,
  }) =>
      ProviderConfig(
        id: id,
        kind: kind,
        name: name ?? this.name,
        baseUrl: baseUrl ?? this.baseUrl,
        modelId: modelId ?? this.modelId,
        enabled: enabled ?? this.enabled,
        allowRawRows: allowRawRows ?? this.allowRawRows,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'kind': kind.name,
        'name': name,
        'base_url': baseUrl,
        'model_id': modelId,
        'enabled': enabled,
        'allow_raw_rows': allowRawRows,
      };

  factory ProviderConfig.fromJson(Map<String, Object?> json) => ProviderConfig(
        id: json['id'] as String,
        kind: AiProviderKind.values.byName(json['kind'] as String),
        name: json['name'] as String,
        baseUrl: (json['base_url'] as String?) ?? '',
        modelId: (json['model_id'] as String?) ?? '',
        enabled: (json['enabled'] as bool?) ?? true,
        allowRawRows: (json['allow_raw_rows'] as bool?) ?? false,
      );

  static const localId = 'local-llama';
  static const local = ProviderConfig(id: localId, kind: AiProviderKind.local, name: 'Model lokal');
}
