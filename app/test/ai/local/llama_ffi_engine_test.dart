import 'dart:convert';
import 'dart:typed_data';

import 'package:agent_hq/ai/local/llama_ffi_engine.dart';
import 'package:agent_hq/ai/local/local_engine.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_llama_api.dart';

void main() {
  late LlamaFfiEngine engine;

  setUp(() => engine = LlamaFfiEngine(createApi: createFakeApi));
  tearDown(() => engine.dispose());

  Future<String> collect(FakeScript script, {LocalGenerateOptions options = const LocalGenerateOptions()}) =>
      engine.generate(script.encode(), options).join();

  group('completeUtf8Length', () {
    test('keeps an incomplete trailing code point', () {
      expect(completeUtf8Length(Uint8List.fromList([0x61, 0xC3])), 1);
      expect(completeUtf8Length(Uint8List.fromList([0xE6, 0x97])), 0);
      expect(completeUtf8Length(Uint8List.fromList([0x61, 0xE6, 0x97, 0xA5])), 4);
      expect(completeUtf8Length(Uint8List.fromList([0xF0, 0x9F, 0x98])), 0);
      expect(completeUtf8Length(Uint8List.fromList(utf8.encode('abc'))), 3);
      expect(completeUtf8Length(Uint8List(0)), 0);
    });
  });

  group('load', () {
    test('transitions unloaded -> loading -> ready and fills stats', () async {
      final states = <LocalEngineState>[];
      engine.stateChanges.listen(states.add);
      expect(engine.state, LocalEngineState.unloaded);

      await engine.load('/models/qwen.gguf', contextLength: 1024, threads: 2);

      expect(engine.state, LocalEngineState.ready);
      expect(states, [LocalEngineState.loading, LocalEngineState.ready]);
      expect(engine.loadedModel?.path, '/models/qwen.gguf');
      expect(engine.loadedModel?.contextLength, 1024);
      expect(engine.lastStats['load_ms'], 12.5);
    });

    test('failure -> error state with LocalEngineException', () async {
      await expectLater(engine.load(failingModelPath), throwsA(isA<LocalEngineException>()));
      expect(engine.state, LocalEngineState.error);
      expect(engine.loadedModel, isNull);
    });

    test('default load is CPU only (gpuLayers 0)', () async {
      await engine.load('/models/qwen.gguf');
      expect(engine.lastStats['requested_gpu_layers'], 0);
      expect(engine.lastStats['gpu_layers'], 0);
      expect(engine.loadedModel?.gpuLayers, 0);
      expect(engine.loadedModel?.usesGpu, isFalse);
    });

    test('gpuLayers is passed to the native API and the used count is reported', () async {
      await engine.load('/models/qwen.gguf', gpuLayers: 12);
      expect(engine.lastStats['requested_gpu_layers'], 12);
      expect(engine.lastStats['gpu_layers'], 12);
      expect(engine.loadedModel?.gpuLayers, 12);
      expect(engine.loadedModel?.usesGpu, isTrue);

      // 99 = all layers -> clamped to n_layer + 1 like llama.cpp does.
      await engine.load('/models/qwen.gguf', gpuLayers: 99);
      expect(engine.lastStats['requested_gpu_layers'], 99);
      expect(engine.loadedModel?.gpuLayers, fakeModelLayers + 1);
    });

    test('GPU unavailable -> LocalEngineException with isGpuUnavailable; CPU retry works', () async {
      await expectLater(
        engine.load(gpuUnavailableModelPath, gpuLayers: 99),
        throwsA(isA<LocalEngineException>()
            .having((e) => e.isGpuUnavailable, 'isGpuUnavailable', isTrue)
            .having((e) => e.code, 'code', LocalEngineException.gpuUnavailableCode)
            .having((e) => e.message, 'message', contains('Vulkan'))),
      );
      expect(engine.state, LocalEngineState.error);

      await engine.load(gpuUnavailableModelPath, gpuLayers: 0);
      expect(engine.state, LocalEngineState.ready);
      expect(engine.loadedModel?.gpuLayers, 0);
    });

    test('other native errors are not flagged as GPU unavailable', () async {
      await expectLater(
        engine.load(failingModelPath, gpuLayers: 99),
        throwsA(isA<LocalEngineException>().having((e) => e.isGpuUnavailable, 'isGpuUnavailable', isFalse)),
      );
    });

    test('unload returns to unloaded and generate is then rejected', () async {
      await engine.load('/models/qwen.gguf');
      await engine.unload();
      expect(engine.state, LocalEngineState.unloaded);
      expect(engine.loadedModel, isNull);
      expect(() => engine.generate('x', const LocalGenerateOptions()), throwsA(isA<LocalEngineException>()));
    });
  });

  group('gpuInfo', () {
    test('works through the isolate before any model is loaded', () async {
      final info = await engine.gpuInfo();
      expect(info.available, isTrue);
      expect(info.backend, 'vulkan');
      expect(info.device, 'Fake GPU "G1"');
      expect(info.vramMb, 4096);
      expect(info.integrated, isTrue);
      expect(info.label, 'Terdeteksi: Fake GPU "G1", VRAM bersama');
      expect(engine.state, LocalEngineState.unloaded);

      await engine.load('/models/qwen.gguf');
      expect(engine.lastStats['gpu_info_calls'], 1);
    });

    test('LocalEngineGpuInfo JSON round-trip and labels', () {
      const none = LocalEngineGpuInfo.none;
      expect(none.available, isFalse);
      expect(none.label, 'Tidak ada GPU Vulkan');
      final discrete = LocalEngineGpuInfo.fromJson({'available': true, 'device': 'Adreno 740', 'vram_mb': 2048});
      expect(discrete.label, 'Terdeteksi: Adreno 740, VRAM 2048 MB');
      expect(LocalEngineGpuInfo.fromJson(discrete.toJson()).toJson(), discrete.toJson());
      expect(LocalEngineGpuInfo.fromJson(const {}).available, isFalse);
    });
  });

  group('generate', () {
    setUp(() => engine.load('/models/qwen.gguf'));

    test('rejected before load', () async {
      final fresh = LlamaFfiEngine(createApi: createFakeApi);
      addTearDown(fresh.dispose);
      expect(() => fresh.generate('x', const LocalGenerateOptions()), throwsA(isA<LocalEngineException>()));
    });

    test('streams pieces in order and returns to ready', () async {
      final states = <LocalEngineState>[];
      engine.stateChanges.listen(states.add);
      final script = FakeScript(pieces: ['Halo', ' ', 'dunia', '!'].map(utf8.encode).toList());

      final text = await collect(script);

      expect(text, 'Halo dunia!');
      expect(engine.state, LocalEngineState.ready);
      expect(states, [LocalEngineState.generating, LocalEngineState.ready]);
      expect(engine.lastStats['gen_tokens'], 4);
    });

    test('reassembles a multibyte char split across pieces', () async {
      // "café 日本" with é (C3 A9) and 日 (E6 97 A5) split mid-sequence.
      final script = FakeScript(pieces: [
        [0x63, 0x61, 0x66, 0xC3],
        [0xA9, 0x20, 0xE6],
        [0x97, 0xA5],
        utf8.encode('本'),
      ]);
      expect(await collect(script), 'café 日本');
    });

    test('truncates at a stop string, including one split across pieces', () async {
      final script = FakeScript(pieces: ['Jawab: ', '42', '<|im', '_end|>', 'sampah'].map(utf8.encode).toList());
      final text = await collect(
        script,
        options: const LocalGenerateOptions(stop: ['<|im_end|>']),
      );
      expect(text, 'Jawab: 42');
      expect(engine.lastStats['stop_calls'], 1);
      expect(engine.state, LocalEngineState.ready);
    });

    test('stops at the earliest of several stop strings', () async {
      final script = FakeScript(pieces: ['a', 'b', 'STOP2', 'c', 'STOP1'].map(utf8.encode).toList());
      final text = await collect(script, options: const LocalGenerateOptions(stop: ['STOP1', 'STOP2']));
      expect(text, 'ab');
    });

    test('honours maxTokens', () async {
      final script = FakeScript(pieces: [utf8.encode('x')], repeat: 100);
      final text = await collect(script, options: const LocalGenerateOptions(maxTokens: 5));
      expect(text, 'xxxxx');
    });

    test('cancel ends the stream and the worker calls stop', () async {
      final script = FakeScript(pieces: [utf8.encode('tok ')], repeat: 100000, maxTokens: 100000);
      final chunks = <String>[];
      final done = engine.generate(script.encode(), const LocalGenerateOptions(maxTokens: 100000)).listen(chunks.add).asFuture<void>();

      // Wait for the first batch before cancelling.
      while (chunks.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      await engine.cancel();
      await done;

      expect(chunks.join().length, lessThan(100000 * 4));
      expect(engine.state, LocalEngineState.ready);
      expect(engine.lastStats['stop_calls'], 1);
    });

    test('cancel without a running generate is a no-op', () async {
      await engine.cancel();
      expect(engine.state, LocalEngineState.ready);
    });

    test('second concurrent generate is rejected', () async {
      final script = FakeScript(pieces: [utf8.encode('a')], repeat: 50);
      final first = engine.generate(script.encode(), const LocalGenerateOptions(maxTokens: 50));
      expect(() => engine.generate(script.encode(), const LocalGenerateOptions()), throwsA(isA<LocalEngineException>()));
      expect(await first.join(), 'a' * 50);
      expect(engine.state, LocalEngineState.ready);
      // A new generate works once the first is done.
      expect(await collect(FakeScript.text('ok')), 'ok');
    });

    test('start failure (e.g. prompt too long) -> stream error and error state', () async {
      final script = FakeScript(startError: 'prompt too long: 3000 tokens, n_ctx=2048, max_tokens=256 (limit 1792)');
      await expectLater(
        collect(script),
        throwsA(isA<LocalEngineException>().having((e) => e.message, 'message', contains('prompt too long'))),
      );
      expect(engine.state, LocalEngineState.error);
    });

    test('native error mid-generation -> stream error after partial text', () async {
      final script = FakeScript(pieces: ['ab', 'cd', 'ef'].map(utf8.encode).toList(), nextErrorAfter: 2);
      final received = <String>[];
      Object? error;
      await engine
          .generate(script.encode(), const LocalGenerateOptions())
          .listen(received.add)
          .asFuture<void>()
          .catchError((Object e) => error = e);
      expect(received.join(), 'abcd');
      expect(error, isA<LocalEngineException>());
      expect(engine.state, LocalEngineState.error);
    });

    test('load again after a generate works', () async {
      expect(await collect(FakeScript.text('one')), 'one');
      await engine.load('/models/other.gguf');
      expect(engine.loadedModel?.path, '/models/other.gguf');
      expect(await collect(FakeScript.text('two')), 'two');
    });
  });
}
