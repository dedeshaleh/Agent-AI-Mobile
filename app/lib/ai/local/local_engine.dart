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
    this.gpuLayers = 0,
    this.description = '',
  });
  final String path;
  final int contextLength;
  final int threads;

  /// Jumlah layer yang benar-benar di-offload ke GPU (0 = CPU saja).
  final int gpuLayers;
  final String description;

  bool get usesGpu => gpuLayers > 0;
}

/// Hasil deteksi GPU dari registry backend ggml (tanpa perlu memuat model).
class LocalEngineGpuInfo {
  const LocalEngineGpuInfo({
    this.available = false,
    this.backend = 'vulkan',
    this.device = '',
    this.vramMb = 0,
    this.integrated = false,
  });

  /// Tidak ada GPU Vulkan yang bisa dipakai (default aman).
  static const none = LocalEngineGpuInfo();

  final bool available;
  final String backend;
  final String device;

  /// Total memori perangkat GPU dalam MB; untuk GPU terintegrasi (Mali/Adreno)
  /// ini memori bersama dengan sistem.
  final int vramMb;
  final bool integrated;

  factory LocalEngineGpuInfo.fromJson(Map<String, Object?> json) => LocalEngineGpuInfo(
        available: json['available'] == true,
        backend: (json['backend'] as String?) ?? 'vulkan',
        device: (json['device'] as String?) ?? '',
        vramMb: (json['vram_mb'] as num?)?.toInt() ?? 0,
        integrated: json['integrated'] == true,
      );

  Map<String, Object?> toJson() => {
        'available': available,
        'backend': backend,
        'device': device,
        'vram_mb': vramMb,
        'integrated': integrated,
      };

  /// Teks UI, mis. "Terdeteksi: Mali-G610 MC6, VRAM bersama" atau
  /// "Tidak ada GPU Vulkan".
  String get label {
    if (!available) return 'Tidak ada GPU Vulkan';
    final mem = integrated ? 'VRAM bersama' : 'VRAM $vramMb MB';
    return 'Terdeteksi: ${device.isEmpty ? 'GPU Vulkan' : device}, $mem';
  }
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
  const LocalEngineException(this.message, {this.code = 0});
  final String message;

  /// Kode `agenthq_error` dari lapisan native (0 bila bukan dari native).
  final int code;

  /// `AGENTHQ_ERR_GPU_UNAVAILABLE`: offload GPU diminta tetapi tidak ada
  /// perangkat Vulkan yang bisa dipakai; pemanggil harus mengulang dengan CPU.
  static const gpuUnavailableCode = -11;

  bool get isGpuUnavailable => code == gpuUnavailableCode;

  @override
  String toString() => 'LocalEngineException: $message';
}

abstract class LocalEngine {
  LocalEngineState get state;
  Stream<LocalEngineState> get stateChanges;
  LocalModelInfo? get loadedModel;

  /// Memuat satu model. Model yang sedang dimuat akan di-unload dulu.
  /// [gpuLayers]: 0 = CPU saja (default), N = N layer ke GPU (Vulkan),
  /// >= 99 = semua layer. Melempar [LocalEngineException] dengan
  /// [LocalEngineException.isGpuUnavailable] bila GPU diminta tetapi tidak ada.
  Future<void> load(String modelPath, {int contextLength = 2048, int threads = 4, int gpuLayers = 0});

  Future<void> unload();

  /// Deteksi GPU (Vulkan) lewat registry backend; tidak perlu model dimuat.
  /// Implementasi tanpa dukungan GPU mengembalikan [LocalEngineGpuInfo.none].
  Future<LocalEngineGpuInfo> gpuInfo() async => LocalEngineGpuInfo.none;

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
