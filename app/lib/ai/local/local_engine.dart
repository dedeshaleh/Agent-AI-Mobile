/// Kontrak runtime LLM lokal yang tertanam di APK (PRD v1.1 §6.3).
///
/// Implementasi (`LlamaFfiEngine`) memanggil llama.cpp lewat `dart:ffi`
/// dari satu Isolate pekerja yang hidup lama. UI isolate tidak pernah
/// memblokir pada FFI.
library;

enum LocalEngineState { unloaded, loading, ready, generating, error }

class LocalModelInfo {
  const LocalModelInfo({
    required this.path,
    required this.contextLength,
    required this.threads,
    this.description = '',
  });
  final String path;
  final int contextLength;
  final int threads;
  final String description;
}

class LocalGenerateOptions {
  const LocalGenerateOptions({
    this.maxTokens = 256,
    this.temperature = 0.3,
    this.topP = 0.9,
    this.minP = 0.05,
    this.grammar,
    this.stop = const [],
  });
  final int maxTokens;
  final double temperature;
  final double topP;
  final double minP;

  /// GBNF grammar (opsional) untuk output terstruktur.
  final String? grammar;
  final List<String> stop;
}

class LocalEngineException implements Exception {
  const LocalEngineException(this.message);
  final String message;
  @override
  String toString() => 'LocalEngineException: $message';
}

abstract class LocalEngine {
  LocalEngineState get state;
  Stream<LocalEngineState> get stateChanges;
  LocalModelInfo? get loadedModel;

  /// Memuat satu model. Model yang sedang dimuat akan di-unload dulu.
  Future<void> load(String modelPath, {int contextLength = 2048, int threads = 4});

  Future<void> unload();

  /// Prompt sudah dalam format template model (mis. ChatML). Stream berisi
  /// potongan teks yang sudah di-batch (tiap 50–100 ms), bukan per token.
  /// Hanya satu generate aktif pada satu waktu; pemanggil kedua mendapat
  /// [LocalEngineException].
  Stream<String> generate(String prompt, LocalGenerateOptions options);

  /// Menghentikan generate yang sedang berjalan (jika ada).
  Future<void> cancel();

  /// Ringkasan benchmark terakhir: tokens/s, waktu load, dll. Boleh kosong.
  Map<String, Object?> get lastStats;
}

/// Format prompt ChatML yang dipakai Qwen3. `/no_think` mematikan mode
/// thinking untuk jawaban pendek.
String formatChatMl(Iterable<({String role, String content})> messages, {bool noThink = true}) {
  final buffer = StringBuffer();
  var first = true;
  for (final m in messages) {
    var content = m.content;
    if (noThink && first && m.role == 'system') content = '$content /no_think';
    first = false;
    buffer.write('<|im_start|>${m.role}\n$content<|im_end|>\n');
  }
  buffer.write('<|im_start|>assistant\n');
  return buffer.toString();
}

/// Membuang blok `<think>...</think>` dari jawaban model.
String stripThinking(String text) {
  final end = text.lastIndexOf('</think>');
  if (end < 0) return text.trim();
  return text.substring(end + '</think>'.length).trim();
}
