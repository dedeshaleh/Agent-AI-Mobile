/// Uji otomatis pembagian beban GPU/CPU: memuat model per preset
/// (CPU / seimbang / GPU penuh), mengukur tok/s dan memilih yang tercepat.
///
/// Logika ini dipisah dari `AppController` supaya dapat diuji dengan
/// `LocalEngine` palsu; controller hanya menyambungkan load/benchmark dan
/// menyimpan hasilnya ke `AiSettings`.
library;

import '../ai_settings.dart';
import 'local_engine.dart';

/// Satu percobaan uji otomatis.
class AutoTuneAttempt {
  const AutoTuneAttempt({
    required this.preset,
    required this.gpuLayers,
    required this.backend,
    required this.elapsed,
    this.tokensPerSecond = 0,
    this.error,
  });
  final GpuSplitPreset preset;

  /// Layer GPU yang diminta (atau yang benar-benar di-offload bila sukses).
  final int gpuLayers;
  final LocalGpuBackend backend;

  /// Waktu load + benchmark.
  final Duration elapsed;
  final double tokensPerSecond;

  /// Pesan kegagalan (load -11, decode, dsb.); null bila sukses.
  final String? error;

  bool get succeeded => error == null;
}

class AutoTuneResult {
  const AutoTuneResult({required this.attempts, required this.backend, this.best, this.cancelled = false});
  final List<AutoTuneAttempt> attempts;

  /// Backend GPU yang diuji (cpu bila tidak ada GPU terdeteksi: hanya 1 percobaan).
  final LocalGpuBackend backend;
  final AutoTuneAttempt? best;
  final bool cancelled;

  /// Layer GPU dari percobaan terbaik untuk disimpan ke `AiSettings.gpuLayers`
  /// (preset dipetakan ulang dengan [layerCount] supaya "seimbang" tetap
  /// konsisten dengan `AiSettings.layersForPreset`).
  int? bestGpuLayers({int? layerCount}) {
    final b = best;
    if (b == null) return null;
    return AiSettings.layersForPreset(b.preset, layerCount: layerCount);
  }
}

/// Memuat model dengan [gpuLayers]/[backend]; mengembalikan pesan error atau null.
typedef AutoTuneLoad = Future<String?> Function(int gpuLayers, LocalGpuBackend backend);

/// Benchmark singkat pada model yang dimuat; harus mengembalikan `gen_tokens_per_s`.
typedef AutoTuneBenchmark = Future<Map<String, Object?>> Function();

class GpuAutoTuner {
  GpuAutoTuner({required this.engine, required this.load, required this.benchmark});

  final LocalEngine engine;
  final AutoTuneLoad load;
  final AutoTuneBenchmark benchmark;

  bool _cancelled = false;
  bool get cancelled => _cancelled;

  /// Membatalkan: percobaan berikutnya tidak dijalankan dan generate yang
  /// sedang berjalan dihentikan.
  void cancel() {
    _cancelled = true;
    engine.cancel();
  }

  /// Memilih urutan preset: CPU dulu (hasilnya memberi `layerCount` untuk
  /// preset seimbang), lalu seimbang, lalu GPU penuh. Tanpa backend GPU hanya
  /// CPU yang diuji.
  static List<GpuSplitPreset> presetsFor(LocalGpuBackend backend) =>
      backend.isGpu ? GpuSplitPreset.values : const [GpuSplitPreset.cpu];

  /// Memilih percobaan sukses dengan tok/s tertinggi (seri → yang pertama,
  /// yaitu lebih sedikit layer GPU).
  static AutoTuneAttempt? pickBest(Iterable<AutoTuneAttempt> attempts) {
    AutoTuneAttempt? best;
    for (final a in attempts) {
      if (!a.succeeded) continue;
      if (best == null || a.tokensPerSecond > best.tokensPerSecond) best = a;
    }
    return best;
  }

  Future<AutoTuneResult> run(LocalGpuBackend backend, {void Function(AutoTuneAttempt attempt)? onAttempt}) async {
    _cancelled = false;
    final attempts = <AutoTuneAttempt>[];
    int? layerCount;
    for (final preset in presetsFor(backend)) {
      if (_cancelled) break;
      final layers = AiSettings.layersForPreset(preset, layerCount: layerCount);
      final usedBackend = layers > 0 ? backend : LocalGpuBackend.cpu;
      final sw = Stopwatch()..start();
      AutoTuneAttempt attempt;
      try {
        final err = await load(layers, usedBackend);
        if (err != null) throw LocalEngineException(err);
        final info = engine.loadedModel;
        if (info != null && info.layerCount > 0) layerCount ??= info.layerCount;
        final stats = await benchmark();
        if (_cancelled) break;
        final tps = stats['gen_tokens_per_s'];
        attempt = AutoTuneAttempt(
          preset: preset,
          gpuLayers: info?.gpuLayers ?? layers,
          backend: usedBackend,
          tokensPerSecond: tps is num ? tps.toDouble() : 0,
          elapsed: sw.elapsed,
        );
      } catch (e) {
        attempt = AutoTuneAttempt(
          preset: preset,
          gpuLayers: layers,
          backend: usedBackend,
          elapsed: sw.elapsed,
          error: e is LocalEngineException ? e.message : '$e',
        );
      }
      attempts.add(attempt);
      onAttempt?.call(attempt);
    }
    return AutoTuneResult(attempts: attempts, backend: backend, best: pickBest(attempts), cancelled: _cancelled);
  }
}
