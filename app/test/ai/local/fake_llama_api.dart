/// API palsu untuk menguji [LlamaFfiEngine] tanpa kode native.
///
/// Dibuat di dalam isolate pekerja lewat [createFakeApi], sehingga tidak
/// dapat dikonfigurasi dari isolate uji. Skenario dikirim lewat *prompt*
/// sebagai JSON ([FakeScript]) dan hasil observasi dibaca lewat `stats()`.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:agent_hq/ai/local/llama_bindings.dart';

/// Path model yang membuat `load` gagal.
const failingModelPath = '/models/fail.gguf';

/// Path model yang gagal dengan `AGENTHQ_ERR_GPU_UNAVAILABLE` (-11) bila
/// `nGpuLayers > 0`, tetapi berhasil di CPU (meniru HP tanpa driver Vulkan).
const gpuUnavailableModelPath = '/models/no-gpu.gguf';

/// Jumlah layer palsu; `gpuLayers` dilaporkan sebagai min(diminta, 29).
const fakeModelLayers = 28;

class FakeScript {
  const FakeScript({
    this.pieces = const [],
    this.repeat = 1,
    this.startError,
    this.nextErrorAfter,
    this.maxTokens,
  });

  /// Potongan byte per token (UTF-8, boleh terpotong).
  final List<List<int>> pieces;
  final int repeat;
  final String? startError;
  final int? nextErrorAfter;
  final int? maxTokens;

  String encode() => jsonEncode({
        'pieces': pieces,
        'repeat': repeat,
        'startError': startError,
        'nextErrorAfter': nextErrorAfter,
        'maxTokens': maxTokens,
      });

  static FakeScript decode(String json) {
    final m = jsonDecode(json) as Map<String, Object?>;
    return FakeScript(
      pieces: (m['pieces'] as List).map((p) => (p as List).cast<int>()).toList(),
      repeat: m['repeat'] as int,
      startError: m['startError'] as String?,
      nextErrorAfter: m['nextErrorAfter'] as int?,
      maxTokens: m['maxTokens'] as int?,
    );
  }

  static FakeScript text(String s) => FakeScript(pieces: [utf8.encode(s)]);
}

LlamaNativeApi createFakeApi() => FakeLlamaApi();

class FakeLlamaApi implements LlamaNativeApi {
  bool _loaded = false;
  String _lastError = '';
  int _stopCalls = 0;
  int _startCalls = 0;
  int _unloadCalls = 0;
  bool _stopped = false;
  final _queue = <Uint8List>[];
  int _emitted = 0;
  int? _errorAfter;

  int _gpuLayers = 0;
  int _lastRequestedGpuLayers = 0;
  int _gpuInfoCalls = 0;

  @override
  void load(String modelPath, {required int nCtx, required int nThreads, required int nBatch, int nGpuLayers = 0}) {
    _lastRequestedGpuLayers = nGpuLayers;
    if (modelPath == failingModelPath) {
      _lastError = 'llama_model_load_from_file failed';
      throw LlamaNativeException(-2, _lastError);
    }
    if (modelPath == gpuUnavailableModelPath && nGpuLayers > 0) {
      _lastError = 'no Vulkan GPU device (driver missing or Vulkan < 1.2)';
      throw LlamaNativeException(-11, _lastError);
    }
    _loaded = true;
    // Seperti shim C: >= 99 berarti semua layer; llama memakai min(n, n_layer + 1).
    final wanted = nGpuLayers >= 99 || nGpuLayers < 0 ? 999 : nGpuLayers;
    _gpuLayers = wanted > fakeModelLayers + 1 ? fakeModelLayers + 1 : wanted;
  }

  @override
  void unload() {
    _loaded = false;
    _gpuLayers = 0;
    _unloadCalls++;
  }

  @override
  bool get isLoaded => _loaded;

  @override
  int get gpuLayers => _loaded ? _gpuLayers : 0;

  @override
  Map<String, Object?> gpuInfo() {
    _gpuInfoCalls++;
    return {
      'available': true,
      'backend': 'vulkan',
      'device': 'Fake GPU "G1"',
      'vram_mb': 4096,
      'integrated': true,
    };
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
    if (!_loaded) throw const LlamaNativeException(-4, 'no model loaded');
    final script = FakeScript.decode(prompt);
    if (script.startError != null) throw LlamaNativeException(-6, script.startError!);
    _startCalls++;
    _stopped = false;
    _emitted = 0;
    _errorAfter = script.nextErrorAfter;
    _queue.clear();
    final limit = script.maxTokens ?? maxTokens;
    for (var r = 0; r < script.repeat && _queue.length < limit; r++) {
      for (final p in script.pieces) {
        if (_queue.length >= limit) break;
        _queue.add(Uint8List.fromList(p));
      }
    }
  }

  @override
  Uint8List? next() {
    if (_stopped || _queue.isEmpty) return null;
    if (_errorAfter != null && _emitted >= _errorAfter!) {
      _lastError = 'llama_decode(token) returned -1';
      throw LlamaNativeException(-7, _lastError);
    }
    _emitted++;
    return _queue.removeAt(0);
  }

  @override
  void stop() {
    _stopped = true;
    _stopCalls++;
  }

  @override
  String lastError() => _lastError;

  @override
  Map<String, Object?> stats() => {
        'load_ms': 12.5,
        'gen_tokens': _emitted,
        'stop_calls': _stopCalls,
        'start_calls': _startCalls,
        'unload_calls': _unloadCalls,
        'requested_gpu_layers': _lastRequestedGpuLayers,
        'gpu_info_calls': _gpuInfoCalls,
      };
}
