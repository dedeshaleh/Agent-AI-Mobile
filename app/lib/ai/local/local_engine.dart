/// Kontrak runtime LLM lokal yang tertanam di APK (PRD v1.1 §6.3).
///
/// Implementasi (`LlamaFfiEngine`) memanggil llama.cpp lewat `dart:ffi`
/// dari satu Isolate pekerja yang hidup lama. UI isolate tidak pernah
/// memblokir pada FFI.
library;

import 'package:flutter/foundation.dart';

enum LocalEngineState { unloaded, loading, ready, generating, error }

enum GenerationPhase { prompt, generating }

/// Kemajuan generate yang sedang berjalan, untuk indikator di UI.
class GenerationProgress {
  const GenerationProgress({required this.phase, required this.tokens, required this.elapsed});
  final GenerationPhase phase;

  /// Token yang sudah dihasilkan (0 selama prompt diproses).
  final int tokens;
  final Duration elapsed;

  double get tokensPerSecond => elapsed.inMilliseconds <= 0 ? 0 : tokens * 1000 / elapsed.inMilliseconds;

  String get elapsedLabel => '${(elapsed.inMilliseconds / 1000).toStringAsFixed(1).replaceAll('.', ',')} s';

  /// Mis. "Memproses prompt… ⏱ 2,1 s" atau "42 token · 7,3 tok/s · ⏱ 6,0 s".
  String get label => phase == GenerationPhase.prompt
      ? 'Memproses prompt… ⏱ $elapsedLabel'
      : '$tokens token · ${tokensPerSecond.toStringAsFixed(1).replaceAll('.', ',')} tok/s · ⏱ $elapsedLabel';
}

/// Backend inferensi lokal. Nilai [nativeCode] = `enum agenthq_backend` di
/// `agenthq_llama.h` (0 = CPU, 1 = Vulkan, 2 = OpenCL).
enum LocalGpuBackend {
  cpu(0, 'CPU'),
  vulkan(1, 'Vulkan'),
  opencl(2, 'OpenCL');

  const LocalGpuBackend(this.nativeCode, this.label);
  final int nativeCode;

  /// Nama untuk UI ("Vulkan", "OpenCL", "CPU").
  final String label;

  bool get isGpu => this != LocalGpuBackend.cpu;

  /// Nama JSON (`backend` di `agenthq_gpu_info`) → enum; tidak dikenal → cpu.
  static LocalGpuBackend fromName(String? name) =>
      LocalGpuBackend.values.where((b) => b.name == name).firstOrNull ?? LocalGpuBackend.cpu;

  static LocalGpuBackend fromNativeCode(int? code) =>
      LocalGpuBackend.values.where((b) => b.nativeCode == code).firstOrNull ?? LocalGpuBackend.cpu;
}

class LocalModelInfo {
  const LocalModelInfo({
    required this.path,
    required this.contextLength,
    required this.threads,
    this.gpuLayers = 0,
    this.backend = LocalGpuBackend.cpu,
    this.layerCount = 0,
    this.description = '',
  });
  final String path;
  final int contextLength;
  final int threads;

  /// Jumlah layer yang benar-benar di-offload ke GPU (0 = CPU saja).
  final int gpuLayers;

  /// Backend yang memegang [gpuLayers]; [LocalGpuBackend.cpu] bila 0.
  final LocalGpuBackend backend;

  /// Jumlah layer transformer model (`n_layer`), 0 bila tidak diketahui.
  final int layerCount;
  final String description;

  bool get usesGpu => gpuLayers > 0 && backend.isGpu;

  /// Layer yang tetap di CPU (hybrid). llama meng-offload maks n_layer + 1
  /// (layer output), jadi hasilnya dijepit ke >= 0.
  int get cpuLayers => layerCount <= 0 ? 0 : (layerCount - gpuLayers).clamp(0, layerCount);

  /// "CPU 4 thread", "OpenCL 37 layer" atau "OpenCL 18/36 layer + CPU 4 thread".
  String get backendLabel {
    if (!usesGpu) return 'CPU $threads thread';
    if (layerCount <= 0) return '${backend.label} $gpuLayers layer';
    if (gpuLayers >= layerCount) return '${backend.label} $gpuLayers layer';
    return '${backend.label} $gpuLayers/$layerCount layer + CPU $threads thread';
  }
}

/// Hasil deteksi satu backend GPU dari registry ggml (tanpa perlu memuat model).
class LocalEngineGpuInfo {
  const LocalEngineGpuInfo({
    this.available = false,
    this.backend = 'vulkan',
    this.device = '',
    this.vramMb = 0,
    this.integrated = false,
    this.apiVersion = '',
    this.reason = '',
  });

  /// Versi API yang dilaporkan driver: Vulkan "1.1", OpenCL "OpenCL 3.0"; kosong bila tak ada.
  final String apiVersion;

  /// Alasan GPU tidak tersedia (bahasa Indonesia), kosong bila tersedia.
  final String reason;

  /// Tidak ada GPU Vulkan yang bisa dipakai (default aman).
  static const none = LocalEngineGpuInfo();

  /// Tidak ada GPU OpenCL yang bisa dipakai (default aman).
  static const noneOpenCl = LocalEngineGpuInfo(backend: 'opencl');

  final bool available;

  /// "vulkan" / "opencl" (nama JSON dari native).
  final String backend;
  LocalGpuBackend get backendKind => LocalGpuBackend.fromName(backend);
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
        apiVersion: (json['api_version'] as String?) ?? '',
        reason: (json['reason'] as String?) ?? '',
      );

  Map<String, Object?> toJson() => {
        'available': available,
        'backend': backend,
        'device': device,
        'vram_mb': vramMb,
        'integrated': integrated,
        'api_version': apiVersion,
        'reason': reason,
      };

  /// Teks UI, mis. "Terdeteksi: Mali-G610 MC6, VRAM bersama" atau
  /// "GPU tidak bisa dipakai: Vulkan 1.1 (ggml butuh 1.2)".
  String get label {
    final name = backendKind == LocalGpuBackend.cpu ? 'Vulkan' : backendKind.label;
    if (!available) return reason.isEmpty ? 'Tidak ada GPU $name' : 'GPU tidak bisa dipakai: $reason';
    final mem = integrated ? 'VRAM bersama' : 'VRAM $vramMb MB';
    final api = apiVersion.isEmpty || backendKind != LocalGpuBackend.opencl ? '' : ', $apiVersion';
    return 'Terdeteksi: ${device.isEmpty ? 'GPU $name' : device}$api, $mem';
  }

  /// [label] dengan awalan nama backend: "OpenCL: Terdeteksi Mali-G610 MC6, OpenCL 3.0".
  String get labeledWithBackend {
    final name = backendKind == LocalGpuBackend.cpu ? 'Vulkan' : backendKind.label;
    return '$name: $label';
  }
}

/// Deteksi semua backend GPU sekaligus (satu panggilan `gpuInfo()`).
class LocalGpuReport {
  const LocalGpuReport({this.vulkan = LocalEngineGpuInfo.none, this.opencl = LocalEngineGpuInfo.noneOpenCl});
  final LocalEngineGpuInfo vulkan;
  final LocalEngineGpuInfo opencl;

  static const none = LocalGpuReport();

  LocalEngineGpuInfo? of(LocalGpuBackend b) => switch (b) {
        LocalGpuBackend.vulkan => vulkan,
        LocalGpuBackend.opencl => opencl,
        LocalGpuBackend.cpu => null,
      };

  List<LocalEngineGpuInfo> get all => [vulkan, opencl];

  /// Backend GPU pertama yang tersedia (Vulkan lalu OpenCL), null bila tidak ada.
  LocalGpuBackend? get firstAvailable =>
      vulkan.available ? LocalGpuBackend.vulkan : (opencl.available ? LocalGpuBackend.opencl : null);
}

/// Hasil satu op pada uji kernel GPU (`agenthq_gpu_selftest`).
class GpuKernelCheck {
  const GpuKernelCheck({
    required this.op,
    required this.ok,
    this.supported = true,
    this.nmse,
    this.tolerance = 0,
    this.gpuMs = 0,
    this.cpuMs = 0,
    this.error = '',
  });
  final String op;

  /// Hasil GPU sama dengan CPU dalam toleransi.
  final bool ok;

  /// false = backend GPU tidak mendukung op ini (ggml menjalankannya di CPU).
  final bool supported;

  /// Normalised mean squared error vs CPU; null bila tidak bisa dihitung.
  final double? nmse;
  final double tolerance;
  final double gpuMs;
  final double cpuMs;
  final String error;

  factory GpuKernelCheck.fromJson(Map<String, Object?> j) => GpuKernelCheck(
        op: (j['op'] as String?) ?? '?',
        ok: j['ok'] == true,
        supported: j['supported'] != false,
        nmse: (j['nmse'] as num?)?.toDouble(),
        tolerance: (j['tol'] as num?)?.toDouble() ?? 0,
        gpuMs: (j['gpu_ms'] as num?)?.toDouble() ?? 0,
        cpuMs: (j['cpu_ms'] as num?)?.toDouble() ?? 0,
        error: (j['error'] as String?) ?? '',
      );

  /// "OK", "SALAH" (hasil beda), "gagal" (error) atau "CPU" (tidak didukung GPU).
  String get status => !supported ? 'CPU' : (error.isNotEmpty ? 'gagal' : (ok ? 'OK' : 'SALAH'));

  /// Mis. "nmse 1,2e-5" atau "–".
  String get nmseLabel => nmse == null ? '–' : 'nmse ${nmse!.toStringAsExponential(1).replaceAll('.', ',')}';
}

/// Laporan uji kernel GPU: op mana yang hasilnya benar di GPU, plus ukuran
/// subgroup yang benar-benar dipakai driver OpenCL.
class GpuSelfTestReport {
  const GpuSelfTestReport({
    this.available = false,
    this.backend = 'opencl',
    this.device = '',
    this.reason = '',
    this.subgroup = const {},
    this.checks = const [],
  });
  final bool available;
  final String backend;
  final String device;
  final String reason;

  /// `{"max_wg":1024,"kernel_wg":1024,"ndrange":{"16":16,...},"runtime":{"64":16,...},"error":""}`.
  final Map<String, Object?> subgroup;
  final List<GpuKernelCheck> checks;

  factory GpuSelfTestReport.fromJson(Map<String, Object?> j) => GpuSelfTestReport(
        available: j['available'] == true,
        backend: (j['backend'] as String?) ?? 'opencl',
        device: (j['device'] as String?) ?? '',
        reason: (j['reason'] as String?) ?? '',
        subgroup: (j['subgroup'] is Map) ? (j['subgroup'] as Map).cast<String, Object?>() : const {},
        checks: [
          for (final t in (j['tests'] as List?) ?? const [])
            if (t is Map) GpuKernelCheck.fromJson(t.cast<String, Object?>()),
        ],
      );

  int get okCount => checks.where((c) => c.ok).length;
  int get wrongCount => checks.where((c) => c.supported && c.error.isEmpty && !c.ok).length;
  int get failedCount => checks.where((c) => c.supported && c.error.isNotEmpty).length;
  int get cpuCount => checks.where((c) => !c.supported).length;
  bool get allOk => available && checks.isNotEmpty && checks.every((c) => c.ok || !c.supported);

  /// Ukuran subgroup yang dibaca dari kernel yang berjalan, mis. {64: 16, 256: 16}.
  Map<int, int?> get runtimeSubgroups {
    final raw = subgroup['runtime'];
    if (raw is! Map) return const {};
    return {for (final e in raw.entries) int.tryParse('${e.key}') ?? 0: (e.value as num?)?.toInt()};
  }

  /// Mis. "16/19 OK · 2 salah · 1 di CPU · subgroup 16".
  String get summary {
    if (!available) return reason.isEmpty ? 'GPU tidak tersedia' : reason;
    final parts = ['$okCount/${checks.length} OK'];
    if (wrongCount > 0) parts.add('$wrongCount salah');
    if (failedCount > 0) parts.add('$failedCount gagal');
    if (cpuCount > 0) parts.add('$cpuCount di CPU');
    final sg = runtimeSubgroups.values.whereType<int>().toSet();
    if (sg.isNotEmpty) parts.add('subgroup ${(sg.toList()..sort()).join('/')}');
    return parts.join(' · ');
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

  /// `AGENTHQ_ERR_GPU_UNAVAILABLE`: offload GPU diminta tetapi backend yang
  /// dipilih (Vulkan/OpenCL) tidak punya perangkat yang bisa dipakai;
  /// pemanggil harus mengulang dengan CPU.
  static const gpuUnavailableCode = -11;

  bool get isGpuUnavailable => code == gpuUnavailableCode;

  @override
  String toString() => 'LocalEngineException: $message';
}

abstract class LocalEngine {
  LocalEngineState get state;
  Stream<LocalEngineState> get stateChanges;
  LocalModelInfo? get loadedModel;

  /// Kemajuan generate yang sedang berjalan; null saat idle. Implementasi tanpa
  /// pelaporan kemajuan memakai nilai bawaan (selalu null).
  ValueListenable<GenerationProgress?> get progress => _noProgress;
  static final _noProgress = ValueNotifier<GenerationProgress?>(null);

  /// Memuat satu model. Model yang sedang dimuat akan di-unload dulu.
  /// [gpuLayers]: 0 = CPU saja (default), N = N layer ke GPU [backend],
  /// sisanya tetap di CPU dengan [threads] thread (hybrid), >= 99 = semua
  /// layer. Melempar [LocalEngineException] dengan
  /// [LocalEngineException.isGpuUnavailable] bila GPU diminta tetapi tidak ada.
  Future<void> load(
    String modelPath, {
    int contextLength = 2048,
    int threads = 4,
    int gpuLayers = 0,
    LocalGpuBackend backend = LocalGpuBackend.cpu,
  });

  Future<void> unload();

  /// Deteksi GPU (Vulkan dan OpenCL) lewat registry backend; tidak perlu model
  /// dimuat. Implementasi tanpa dukungan GPU mengembalikan [LocalGpuReport.none].
  Future<LocalGpuReport> gpuInfo() async => LocalGpuReport.none;

  /// Uji kernel GPU [backend]: setiap op ggml dijalankan di CPU dan GPU dengan
  /// input sama lalu dibandingkan. Beberapa detik; tidak memerlukan model.
  /// Implementasi tanpa dukungan GPU mengembalikan laporan tidak tersedia.
  Future<GpuSelfTestReport> gpuSelfTest(LocalGpuBackend backend) async =>
      const GpuSelfTestReport(reason: 'Backend GPU tidak didukung runtime ini');

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
