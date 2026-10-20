/// `dart:ffi` binding ke shim C `libagenthq_llama.so`
/// (`android/app/src/main/cpp/agenthq_llama.h`).
///
/// Semua fungsi bersifat blocking dan hanya boleh dipanggil dari Isolate
/// pekerja (`LlamaFfiEngine`), bukan dari UI isolate.
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// Kesalahan dari lapisan native; [message] diambil dari `agenthq_last_error`.
class LlamaNativeException implements Exception {
  const LlamaNativeException(this.code, this.message);
  final int code;
  final String message;
  @override
  String toString() => 'LlamaNativeException($code): $message';
}

/// Antarmuka polling ke runtime llama.cpp. Diabstraksikan supaya engine dapat
/// diuji dengan implementasi palsu tanpa kode native.
abstract class LlamaNativeApi {
  /// Memuat model; melempar [LlamaNativeException] bila gagal.
  /// [nGpuLayers] 0 = CPU saja; >= 99 = semua layer ke GPU. [backend] =
  /// `enum agenthq_backend` (0 cpu, 1 vulkan, 2 opencl); diabaikan bila
  /// [nGpuLayers] 0. Kode `-11` (`AGENTHQ_ERR_GPU_UNAVAILABLE`) berarti GPU
  /// backend itu tidak tersedia.
  void load(
    String modelPath, {
    required int nCtx,
    required int nThreads,
    required int nBatch,
    int nGpuLayers = 0,
    int backend = 0,
  });

  void unload();

  bool get isLoaded;

  /// Layer yang benar-benar di-offload ke GPU oleh model yang dimuat (0 = CPU).
  int get gpuLayers;

  /// `agenthq_backend` yang dipakai model yang dimuat (0 bila CPU/tidak ada).
  int get gpuBackend;

  /// `n_layer` model yang dimuat (0 bila tidak ada).
  int get modelLayers;

  /// Direktori cache binary kernel OpenCL; panggil sebelum load pertama.
  void setCacheDir(String? dir);

  /// JSON `agenthq_gpu_info(backend)` yang sudah di-decode: `available`,
  /// `backend`, `device`, `vram_mb`, `integrated`, `api_version`, `reason`.
  /// [backend] 1 = Vulkan, 2 = OpenCL. Tidak perlu model dimuat.
  Map<String, Object?> gpuInfo(int backend);

  /// Menyiapkan satu sesi generate (reset KV, decode prompt, siapkan sampler).
  void start(
    String prompt, {
    required int maxTokens,
    required double temperature,
    required double topP,
    required double minP,
    String? grammar,
  });

  /// Byte UTF-8 dari satu token berikutnya (bisa berupa potongan UTF-8 yang
  /// belum lengkap). `null` bila generate selesai.
  Uint8List? next();

  /// Menghentikan loop [next] pada panggilan berikutnya.
  void stop();

  String lastError();

  /// Kunci: `load_ms`, `prompt_tokens_per_s`, `gen_tokens_per_s`,
  /// `prompt_tokens`, `gen_tokens`, `gpu_layers`, `gpu_backend`, `model_layers`.
  Map<String, Object?> stats();
}

typedef _LoadC = Int32 Function(Pointer<Utf8>, Int32, Int32, Int32, Int32, Int32);
typedef _LoadD = int Function(Pointer<Utf8>, int, int, int, int, int);
typedef _GpuInfoC = Int32 Function(Int32, Pointer<Utf8>, Int32);
typedef _GpuInfoD = int Function(int, Pointer<Utf8>, int);
typedef _SetStrC = Void Function(Pointer<Utf8>);
typedef _SetStrD = void Function(Pointer<Utf8>);
typedef _VoidC = Void Function();
typedef _VoidD = void Function();
typedef _IntC = Int32 Function();
typedef _IntD = int Function();
typedef _StartC = Int32 Function(Pointer<Utf8>, Int32, Float, Float, Float, Pointer<Utf8>);
typedef _StartD = int Function(Pointer<Utf8>, int, double, double, double, Pointer<Utf8>);
typedef _NextC = Int32 Function(Pointer<Uint8>, Int32);
typedef _NextD = int Function(Pointer<Uint8>, int);
typedef _LastErrorC = Pointer<Utf8> Function();
typedef _LastErrorD = Pointer<Utf8> Function();
typedef _StatsC = Int32 Function(
    Pointer<Double>, Pointer<Double>, Pointer<Double>, Pointer<Int32>, Pointer<Int32>);
typedef _StatsD = int Function(
    Pointer<Double>, Pointer<Double>, Pointer<Double>, Pointer<Int32>, Pointer<Int32>);

/// Implementasi nyata di atas `libagenthq_llama.so`.
class LlamaNative implements LlamaNativeApi {
  LlamaNative._(DynamicLibrary lib)
      : _load = lib.lookupFunction<_LoadC, _LoadD>('agenthq_load'),
        _unload = lib.lookupFunction<_VoidC, _VoidD>('agenthq_unload'),
        _isLoaded = lib.lookupFunction<_IntC, _IntD>('agenthq_is_loaded'),
        _gpuLayers = lib.lookupFunction<_IntC, _IntD>('agenthq_gpu_layers'),
        _gpuBackend = lib.lookupFunction<_IntC, _IntD>('agenthq_gpu_backend'),
        _modelLayers = lib.lookupFunction<_IntC, _IntD>('agenthq_model_layers'),
        _setCacheDir = lib.lookupFunction<_SetStrC, _SetStrD>('agenthq_set_cache_dir'),
        _gpuInfo = lib.lookupFunction<_GpuInfoC, _GpuInfoD>('agenthq_gpu_info'),
        _start = lib.lookupFunction<_StartC, _StartD>('agenthq_start'),
        _next = lib.lookupFunction<_NextC, _NextD>('agenthq_next'),
        _stop = lib.lookupFunction<_VoidC, _VoidD>('agenthq_stop'),
        _lastError = lib.lookupFunction<_LastErrorC, _LastErrorD>('agenthq_last_error'),
        _stats = lib.lookupFunction<_StatsC, _StatsD>('agenthq_stats'),
        _pieceBuf = calloc<Uint8>(_pieceCap);

  factory LlamaNative.open() => LlamaNative._(openLibrary());

  static const libraryName = 'libagenthq_llama.so';

  /// Potongan satu token jauh lebih kecil dari ini; shim C mengembalikan
  /// error (bukan memotong) bila tidak muat.
  static const _pieceCap = 1024;

  static DynamicLibrary openLibrary() {
    if (Platform.isAndroid || Platform.isLinux) return DynamicLibrary.open(libraryName);
    throw UnsupportedError('libagenthq_llama hanya tersedia di Android');
  }

  final _LoadD _load;
  final _VoidD _unload;
  final _IntD _isLoaded;
  final _IntD _gpuLayers;
  final _IntD _gpuBackend;
  final _IntD _modelLayers;
  final _SetStrD _setCacheDir;
  final _GpuInfoD _gpuInfo;
  final _StartD _start;
  final _NextD _next;
  final _VoidD _stop;
  final _LastErrorD _lastError;
  final _StatsD _stats;
  final Pointer<Uint8> _pieceBuf;

  @override
  void load(
    String modelPath, {
    required int nCtx,
    required int nThreads,
    required int nBatch,
    int nGpuLayers = 0,
    int backend = 0,
  }) {
    final path = modelPath.toNativeUtf8();
    try {
      _check(_load(path, nCtx, nThreads, nBatch, nGpuLayers, backend));
    } finally {
      calloc.free(path);
    }
  }

  @override
  void unload() => _unload();

  @override
  bool get isLoaded => _isLoaded() != 0;

  @override
  int get gpuLayers => _gpuLayers();

  @override
  int get gpuBackend => _gpuBackend();

  @override
  int get modelLayers => _modelLayers();

  @override
  void setCacheDir(String? dir) {
    final p = (dir ?? '').toNativeUtf8();
    try {
      _setCacheDir(p);
    } finally {
      calloc.free(p);
    }
  }

  @override
  Map<String, Object?> gpuInfo(int backend) {
    const cap = 512;
    final buf = calloc<Uint8>(cap);
    try {
      final n = _gpuInfo(backend, buf.cast<Utf8>(), cap);
      if (n < 0) throw LlamaNativeException(n, lastError());
      final decoded = jsonDecode(utf8.decode(buf.asTypedList(n)));
      return decoded is Map ? decoded.cast<String, Object?>() : const {};
    } finally {
      calloc.free(buf);
    }
  }

  @override
  void start(
    String prompt, {
    required int maxTokens,
    required double temperature,
    required double topP,
    required double minP,
    String? grammar,
  }) {
    final p = prompt.toNativeUtf8();
    final g = grammar == null ? nullptr : grammar.toNativeUtf8();
    try {
      _check(_start(p, maxTokens, temperature, topP, minP, g));
    } finally {
      calloc.free(p);
      if (g != nullptr) calloc.free(g);
    }
  }

  @override
  Uint8List? next() {
    final n = _next(_pieceBuf, _pieceCap);
    if (n == 0) return null;
    if (n < 0) throw LlamaNativeException(n, lastError());
    return Uint8List.fromList(_pieceBuf.asTypedList(n));
  }

  @override
  void stop() => _stop();

  @override
  String lastError() {
    final p = _lastError();
    return p == nullptr ? '' : p.toDartString();
  }

  @override
  Map<String, Object?> stats() {
    final d = calloc<Double>(3);
    final i = calloc<Int32>(2);
    try {
      final rc = _stats(d, d + 1, d + 2, i, i + 1);
      if (rc != 0) return const {};
      return {
        'load_ms': d[0],
        'prompt_tokens_per_s': d[1],
        'gen_tokens_per_s': d[2],
        'prompt_tokens': i[0],
        'gen_tokens': i[1],
        'gpu_layers': _gpuLayers(),
        'gpu_backend': _gpuBackend(),
        'model_layers': _modelLayers(),
      };
    } finally {
      calloc.free(d);
      calloc.free(i);
    }
  }

  void _check(int rc) {
    if (rc != 0) throw LlamaNativeException(rc, lastError());
  }
}
