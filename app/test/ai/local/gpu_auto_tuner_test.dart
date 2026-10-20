import 'package:agent_hq/ai/ai_settings.dart';
import 'package:agent_hq/ai/local/gpu_auto_tuner.dart';
import 'package:agent_hq/ai/local/local_engine.dart';
import 'package:flutter_test/flutter_test.dart';

import '../fakes.dart';

void main() {
  late FakeLocalEngine engine;
  late List<(int, LocalGpuBackend)> loads;

  GpuAutoTuner tuner({String? Function(int layers, LocalGpuBackend b)? loadError}) => GpuAutoTuner(
        engine: engine,
        load: (layers, b) async {
          loads.add((layers, b));
          final err = loadError?.call(layers, b);
          if (err != null) return err;
          try {
            await engine.load('/m.gguf', gpuLayers: layers, backend: b);
            return null;
          } on LocalEngineException catch (e) {
            return e.message;
          }
        },
        benchmark: () async {
          await engine.generate('bench', const LocalGenerateOptions()).drain<void>();
          return engine.lastStats;
        },
      );

  setUp(() {
    engine = FakeLocalEngine()..layerCount = 36;
    loads = [];
  });

  test('presets: GPU backend tests CPU/seimbang/penuh, CPU backend only CPU', () {
    expect(GpuAutoTuner.presetsFor(LocalGpuBackend.opencl), GpuSplitPreset.values);
    expect(GpuAutoTuner.presetsFor(LocalGpuBackend.vulkan), GpuSplitPreset.values);
    expect(GpuAutoTuner.presetsFor(LocalGpuBackend.cpu), [GpuSplitPreset.cpu]);
  });

  test('picks the fastest preset; balanced uses half of the model layer count learned from the CPU load', () async {
    // 0 layer -> 6 tok/s, 18 -> 11 tok/s, 37 (semua) -> 9 tok/s: hybrid menang.
    engine.tokensPerSecondFor = (l) => l == 0 ? 6 : (l <= 18 ? 11 : 9);
    final seen = <AutoTuneAttempt>[];
    final result = await tuner().run(LocalGpuBackend.opencl, onAttempt: seen.add);

    expect(result.cancelled, isFalse);
    expect(result.backend, LocalGpuBackend.opencl);
    expect(result.attempts.map((a) => a.preset), GpuSplitPreset.values);
    expect(seen.length, 3);
    expect(loads, [(0, LocalGpuBackend.cpu), (18, LocalGpuBackend.opencl), (99, LocalGpuBackend.opencl)]);
    expect(result.attempts.every((a) => a.succeeded), isTrue);
    expect(result.attempts[0].backend, LocalGpuBackend.cpu);
    expect(result.attempts[1].gpuLayers, 18);
    expect(result.attempts[2].gpuLayers, 37, reason: 'llama meng-offload n_layer + 1');
    expect(result.best?.preset, GpuSplitPreset.balanced);
    expect(result.best?.tokensPerSecond, 11);
    expect(result.bestGpuLayers(layerCount: 36), 18);
    expect(result.bestGpuLayers(layerCount: 28), 14, reason: 'preset dipetakan ulang ke layerCount yang diberikan');
  });

  test('GPU full wins -> gpuLayers 99', () async {
    engine.tokensPerSecondFor = (l) => l >= 37 ? 20 : 5;
    final result = await tuner().run(LocalGpuBackend.vulkan);
    expect(result.best?.preset, GpuSplitPreset.full);
    expect(result.best?.backend, LocalGpuBackend.vulkan);
    expect(result.bestGpuLayers(layerCount: 36), 99);
  });

  test('GPU unavailable (-11) attempts are recorded as failed and the run continues; CPU wins', () async {
    engine.unavailableBackends = {LocalGpuBackend.opencl};
    engine.tokensPerSecondFor = (_) => 7;
    final result = await tuner().run(LocalGpuBackend.opencl);
    expect(result.attempts.length, 3);
    expect(result.attempts[0].succeeded, isTrue);
    expect(result.attempts[1].succeeded, isFalse);
    expect(result.attempts[1].error, contains('Driver tidak ditemukan'));
    expect(result.attempts[2].succeeded, isFalse);
    expect(result.best?.preset, GpuSplitPreset.cpu);
    expect(result.best?.backend, LocalGpuBackend.cpu);
    expect(result.bestGpuLayers(layerCount: 36), 0);
  });

  test('all attempts failing -> best null', () async {
    final result = await tuner(loadError: (_, _) => 'model rusak').run(LocalGpuBackend.opencl);
    expect(result.attempts.length, 3);
    expect(result.best, isNull);
    expect(result.bestGpuLayers(), isNull);
  });

  test('tie goes to fewer GPU layers (first attempt)', () async {
    engine.tokensPerSecondFor = (_) => 8;
    final result = await tuner().run(LocalGpuBackend.opencl);
    expect(result.best?.preset, GpuSplitPreset.cpu);
  });

  test('without GPU only the CPU preset runs', () async {
    engine.tokensPerSecondFor = (_) => 8;
    final result = await tuner().run(LocalGpuBackend.cpu);
    expect(result.attempts.map((a) => a.preset), [GpuSplitPreset.cpu]);
    expect(loads, [(0, LocalGpuBackend.cpu)]);
  });

  test('cancel stops after the current attempt', () async {
    engine.tokensPerSecondFor = (_) => 8;
    late GpuAutoTuner t;
    t = tuner();
    final result = await t.run(LocalGpuBackend.opencl, onAttempt: (_) => t.cancel());
    expect(result.cancelled, isTrue);
    expect(result.attempts.length, 1);
    expect(engine.cancelCalls, 1);
  });

  test('missing gen_tokens_per_s counts as 0 tok/s', () async {
    engine.tokensPerSecondFor = null;
    final result = await tuner().run(LocalGpuBackend.opencl);
    expect(result.attempts.every((a) => a.succeeded && a.tokensPerSecond == 0), isTrue);
    expect(result.best?.preset, GpuSplitPreset.cpu);
  });
}
