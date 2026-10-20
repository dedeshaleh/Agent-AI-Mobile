import 'dart:async';
import 'dart:convert';

import 'package:agent_hq/ai/local/local_engine.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// LocalEngine palsu: mengeluarkan [chunks] untuk setiap generate.
class FakeLocalEngine implements LocalEngine {
  FakeLocalEngine({this.chunks = const ['jawaban lokal'], LocalEngineState initial = LocalEngineState.ready})
      : _state = initial;

  List<String> chunks;
  LocalEngineState _state;
  final _changes = StreamController<LocalEngineState>.broadcast();
  final prompts = <String>[];
  int cancelCalls = 0;
  bool loaded = false;

  @override
  LocalEngineState get state => _state;
  set state(LocalEngineState s) {
    _state = s;
    _changes.add(s);
  }

  @override
  Stream<LocalEngineState> get stateChanges => _changes.stream;

  @override
  final ValueNotifier<GenerationProgress?> progress = ValueNotifier<GenerationProgress?>(null);

  int lastGpuLayers = 0;
  LocalGpuBackend lastBackend = LocalGpuBackend.cpu;
  final loads = <(int gpuLayers, LocalGpuBackend backend)>[];

  /// Jumlah layer model palsu (`n_layer`), dilaporkan lewat [loadedModel].
  int layerCount = 0;

  /// Backend GPU yang "tidak tersedia": load dengan gpuLayers > 0 pada backend
  /// ini melempar [LocalEngineException] -11 seperti engine asli.
  Set<LocalGpuBackend> unavailableBackends = const {};

  /// tok/s yang dilaporkan di [lastStats] per gpuLayers (untuk uji auto-tune);
  /// null → nilai tetap.
  double Function(int gpuLayers)? tokensPerSecondFor;

  LocalGpuReport gpuReport = LocalGpuReport.none;

  @override
  LocalModelInfo? get loadedModel => _state == LocalEngineState.unloaded
      ? null
      : LocalModelInfo(
          path: '/m.gguf',
          contextLength: 2048,
          threads: 4,
          gpuLayers: lastGpuLayers,
          backend: lastGpuLayers > 0 ? lastBackend : LocalGpuBackend.cpu,
          layerCount: layerCount,
        );

  @override
  Future<void> load(
    String modelPath, {
    int contextLength = 2048,
    int threads = 4,
    int gpuLayers = 0,
    LocalGpuBackend backend = LocalGpuBackend.cpu,
  }) async {
    loads.add((gpuLayers, backend));
    if (gpuLayers > 0 && unavailableBackends.contains(backend)) {
      state = LocalEngineState.error;
      throw LocalEngineException('${backend.name}: Driver tidak ditemukan', code: LocalEngineException.gpuUnavailableCode);
    }
    loaded = true;
    lastGpuLayers = gpuLayers > 0 && backend.isGpu ? (layerCount > 0 ? gpuLayers.clamp(0, layerCount + 1) : gpuLayers) : 0;
    lastBackend = backend;
    state = LocalEngineState.ready;
  }

  @override
  Future<LocalGpuReport> gpuInfo() async => gpuReport;

  @override
  Future<GpuSelfTestReport> gpuSelfTest(LocalGpuBackend backend) async => const GpuSelfTestReport(reason: 'palsu');

  @override
  Future<void> unload() async => state = LocalEngineState.unloaded;

  @override
  Stream<String> generate(String prompt, LocalGenerateOptions options) async* {
    prompts.add(prompt);
    for (final c in chunks) {
      yield c;
    }
  }

  @override
  Future<void> cancel() async => cancelCalls++;

  @override
  Map<String, Object?> get lastStats => {
        'prompt_tokens': 10,
        'output_tokens': 5,
        if (tokensPerSecondFor != null) 'gen_tokens_per_s': tokensPerSecondFor!(lastGpuLayers),
        'gpu_layers': lastGpuLayers,
      };
}

/// Membuat body SSE dari daftar event (event opsional, data JSON/teks).
String sseBody(List<(String?, Object)> events) {
  final b = StringBuffer();
  for (final (event, data) in events) {
    if (event != null) b.write('event: $event\n');
    b.write('data: ${data is String ? data : jsonEncode(data)}\n\n');
  }
  return b.toString();
}

/// MockClient yang menghitung panggilan dan menjawab lewat [handler].
class CountingClient extends http.BaseClient {
  CountingClient(this.handler);
  final Future<http.Response> Function(http.Request) handler;
  final requests = <http.Request>[];
  late final _inner = MockClient(handler);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    requests.add(request as http.Request);
    return _inner.send(request);
  }
}

http.Response sse(List<(String?, Object)> events) =>
    http.Response(sseBody(events), 200, headers: {'content-type': 'text/event-stream'});
