/// [LocalEngine] di atas `libagenthq_llama.so` lewat satu Isolate pekerja.
///
/// Isolate pekerja memiliki handle native dan melakukan semua panggilan FFI
/// (blocking). UI isolate hanya mengirim perintah dan menerima batch teks.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'llama_bindings.dart';
import 'local_engine.dart';

/// Pabrik API yang dijalankan *di dalam* isolate pekerja. Harus berupa fungsi
/// top-level/static agar bisa dikirim lewat `SendPort`.
typedef LlamaApiFactory = LlamaNativeApi Function();

LlamaNativeApi _openNative() => LlamaNative.open();

class LlamaFfiEngine implements LocalEngine {
  /// [createApi] memungkinkan pengujian dengan API palsu; default membuka
  /// pustaka native.
  /// [cacheDir]: direktori privat aplikasi untuk cache binary kernel OpenCL
  /// (`GGML_OPENCL_KERNEL_CACHE_DIR`); null = tanpa cache.
  LlamaFfiEngine({
    LlamaApiFactory createApi = _openNative,
    this.batchSize = 512,
    Duration flushInterval = const Duration(milliseconds: 60),
    this._flushBytes = 32,
    void Function()? directStop,
    this.cacheDir,
  })  : _createApi = createApi, // ignore: prefer_initializing_formals
        _flushIntervalMs = flushInterval.inMilliseconds,
        // The worker isolate cannot read _CancelCmd while it is blocked inside a native
        // call (prompt decode under memory pressure takes minutes), so cancel also raises
        // the native stop flag from the calling isolate; agenthq_stop is an atomic store.
        _directStop = directStop ?? (identical(createApi, _openNative) ? _nativeStop : null);

  static void _nativeStop() => LlamaNative.open().stop();

  final LlamaApiFactory _createApi;
  final void Function()? _directStop;
  final int batchSize;
  final String? cacheDir;
  final int _flushIntervalMs;
  final int _flushBytes;

  @override
  final ValueNotifier<GenerationProgress?> progress = ValueNotifier<GenerationProgress?>(null);
  final _genClock = Stopwatch();
  Timer? _progressTicker;

  void _clearProgress() {
    _progressTicker?.cancel();
    _progressTicker = null;
    progress.value = null;
  }

  LocalEngineState _state = LocalEngineState.unloaded;
  // sync: listeners observe transitions in order, before the generate stream closes.
  final _stateController = StreamController<LocalEngineState>.broadcast(sync: true);
  LocalModelInfo? _loadedModel;
  Map<String, Object?> _lastStats = const {};

  Isolate? _isolate;
  SendPort? _worker;
  Future<SendPort>? _starting;
  final _ports = <ReceivePort>[];

  int _nextId = 1;
  final _pending = <int, Completer<_Reply>>{};
  _ActiveGeneration? _active;
  bool _disposed = false;

  @override
  LocalEngineState get state => _state;

  @override
  Stream<LocalEngineState> get stateChanges => _stateController.stream;

  @override
  LocalModelInfo? get loadedModel => _loadedModel;

  @override
  Map<String, Object?> get lastStats => _lastStats;

  @override
  Future<void> load(
    String modelPath, {
    int contextLength = 2048,
    int threads = 4,
    int gpuLayers = 0,
    LocalGpuBackend backend = LocalGpuBackend.cpu,
  }) async {
    if (_active != null) throw const LocalEngineException('Tidak bisa load saat generate berjalan');
    _setState(LocalEngineState.loading);
    final wantGpu = gpuLayers > 0 && backend.isGpu;
    try {
      final reply = await _send(_LoadCmd(modelPath, contextLength, threads, batchSize, wantGpu ? gpuLayers : 0,
          wantGpu ? backend.nativeCode : 0, cacheDir));
      _lastStats = reply.stats ?? const {};
      final used = _lastStats['gpu_layers'];
      final usedBackend = _lastStats['gpu_backend'];
      final layers = _lastStats['model_layers'];
      final usedLayers = used is num ? used.toInt() : (wantGpu ? gpuLayers : 0);
      _loadedModel = LocalModelInfo(
        path: modelPath,
        contextLength: contextLength,
        threads: threads,
        gpuLayers: usedLayers,
        backend: usedBackend is num
            ? LocalGpuBackend.fromNativeCode(usedBackend.toInt())
            : (usedLayers > 0 ? backend : LocalGpuBackend.cpu),
        layerCount: layers is num ? layers.toInt() : 0,
      );
      _setState(LocalEngineState.ready);
    } catch (e) {
      _loadedModel = null;
      _setState(LocalEngineState.error);
      throw _wrap(e);
    }
  }

  @override
  Future<LocalGpuReport> gpuInfo() async {
    final reply = await _send(_GpuInfoCmd());
    final stats = reply.stats ?? const {};
    LocalEngineGpuInfo parse(String key, LocalEngineGpuInfo fallback) {
      final raw = stats[key];
      return raw is Map ? LocalEngineGpuInfo.fromJson(raw.cast<String, Object?>()) : fallback;
    }

    return LocalGpuReport(
      vulkan: parse('vulkan', LocalEngineGpuInfo.none),
      opencl: parse('opencl', LocalEngineGpuInfo.noneOpenCl),
    );
  }

  @override
  Future<void> unload() async {
    if (_worker == null && _starting == null) {
      _loadedModel = null;
      _setState(LocalEngineState.unloaded);
      return;
    }
    await cancel();
    try {
      await _send(_UnloadCmd());
    } finally {
      _loadedModel = null;
      _setState(LocalEngineState.unloaded);
    }
  }

  @override
  Stream<String> generate(String prompt, LocalGenerateOptions options) {
    if (_active != null) throw const LocalEngineException('Generate lain masih berjalan');
    if (_state != LocalEngineState.ready || _loadedModel == null) {
      throw LocalEngineException('Model belum siap (state: ${_state.name})');
    }
    final id = _nextId++;
    final controller = StreamController<String>();
    final active = _ActiveGeneration(id, controller);
    _active = active;
    _genClock
      ..reset()
      ..start();
    progress.value = GenerationProgress(phase: GenerationPhase.prompt, tokens: 0, elapsed: Duration.zero);
    // The worker only reports on new tokens; keep the elapsed time ticking while
    // the prompt is being decoded (or the model is slow).
    _progressTicker?.cancel();
    _progressTicker = Timer.periodic(const Duration(milliseconds: 250), (_) {
      final p = progress.value;
      if (p != null) progress.value = GenerationProgress(phase: p.phase, tokens: p.tokens, elapsed: _genClock.elapsed);
    });
    _setState(LocalEngineState.generating);

    controller.onCancel = () {
      if (_active == active) unawaited(cancel());
    };

    _send(_GenerateCmd(
      id: id,
      prompt: prompt,
      maxTokens: options.maxTokens,
      temperature: options.temperature,
      topP: options.topP,
      minP: options.minP,
      grammar: options.grammar,
      stop: options.stop,
      flushIntervalMs: _flushIntervalMs,
      flushBytes: _flushBytes,
    )).then((reply) {
      _lastStats = reply.stats ?? _lastStats;
      _clearProgress();
      _finishGeneration(active, null);
    }, onError: (Object e) {
      _clearProgress();
      _finishGeneration(active, _wrap(e));
    });

    return controller.stream;
  }

  @override
  Future<void> cancel() async {
    final active = _active;
    if (active == null) return;
    try {
      _directStop?.call();
    } catch (_) {
      // Pustaka belum terbuka di isolate ini; worker tetap menerima _CancelCmd.
    }
    _worker?.send(_CancelCmd(active.id));
    await active.controller.done.catchError((_) {});
  }

  /// Mematikan isolate pekerja. Engine tidak dapat dipakai lagi setelah ini.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _clearProgress();
    final active = _active;
    if (active != null) _finishGeneration(active, const LocalEngineException('Engine ditutup'));
    _failPending(const LocalEngineException('Engine ditutup'));
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _worker = null;
    for (final p in _ports) {
      p.close();
    }
    _ports.clear();
    _loadedModel = null;
    _setState(LocalEngineState.unloaded);
    await _stateController.close();
  }

  // --- isolate plumbing -----------------------------------------------------

  Future<SendPort> _ensureWorker() {
    if (_disposed) throw const LocalEngineException('Engine sudah ditutup');
    final existing = _worker;
    if (existing != null) return Future.value(existing);
    return _starting ??= _spawn();
  }

  Future<SendPort> _spawn() async {
    final ready = Completer<SendPort>();
    final replies = ReceivePort();
    final errors = ReceivePort();
    final exit = ReceivePort();
    _ports.addAll([replies, errors, exit]);

    replies.listen((Object? msg) {
      if (msg is SendPort) {
        ready.complete(msg);
      } else if (msg is _Chunk) {
        final active = _active;
        if (active != null && active.id == msg.id && !active.controller.isClosed) {
          active.controller.add(msg.text);
        }
      } else if (msg is _Progress) {
        final active = _active;
        if (active != null && active.id == msg.id) {
          if (msg.prompt) _genClock.reset();
          progress.value = GenerationProgress(
            phase: msg.prompt ? GenerationPhase.prompt : GenerationPhase.generating,
            tokens: msg.tokens,
            elapsed: _genClock.elapsed,
          );
        }
      } else if (msg is _Reply) {
        _pending.remove(msg.id)?.complete(msg);
      }
    });
    errors.listen((Object? msg) => _onIsolateFailure('Isolate error: ${(msg as List?)?.first}'));
    exit.listen((_) {
      if (!_disposed) _onIsolateFailure('Isolate pekerja berhenti');
    });

    try {
      _isolate = await Isolate.spawn<_WorkerInit>(
        _workerMain,
        _WorkerInit(replies.sendPort, _createApi),
        onError: errors.sendPort,
        onExit: exit.sendPort,
        debugName: 'agenthq-llama',
      );
    } catch (e) {
      _starting = null;
      throw LocalEngineException('Gagal membuat isolate: $e');
    }
    final port = await ready.future;
    _worker = port;
    _starting = null;
    return port;
  }

  Future<_Reply> _send(_Cmd cmd) async {
    final port = await _ensureWorker();
    final completer = Completer<_Reply>();
    _pending[cmd.id] = completer;
    port.send(cmd);
    final reply = await completer.future;
    if (reply.error != null) throw LocalEngineException(reply.error!, code: reply.errorCode);
    return reply;
  }

  void _onIsolateFailure(String message) {
    _isolate = null;
    _worker = null;
    _starting = null;
    _loadedModel = null;
    final err = LocalEngineException(message);
    _failPending(err);
    final active = _active;
    if (active != null) _finishGeneration(active, err);
    _setState(LocalEngineState.error);
  }

  void _failPending(LocalEngineException err) {
    for (final c in _pending.values) {
      if (!c.isCompleted) c.complete(_Reply(-1, error: err.message));
    }
    _pending.clear();
  }

  void _finishGeneration(_ActiveGeneration active, LocalEngineException? error) {
    if (_active != active) return;
    _active = null;
    if (error != null) {
      _setState(LocalEngineState.error);
    } else if (_state == LocalEngineState.generating) {
      _setState(_loadedModel == null ? LocalEngineState.unloaded : LocalEngineState.ready);
    }
    if (!active.controller.isClosed) {
      if (error != null) active.controller.addError(error);
      unawaited(active.controller.close());
    }
  }

  void _setState(LocalEngineState s) {
    if (_state == s) return;
    _state = s;
    if (!_stateController.isClosed) _stateController.add(s);
  }

  LocalEngineException _wrap(Object e) =>
      e is LocalEngineException ? e : LocalEngineException(e.toString());
}

class _ActiveGeneration {
  _ActiveGeneration(this.id, this.controller);
  final int id;
  final StreamController<String> controller;
}

// --- messages ---------------------------------------------------------------

int _cmdSeq = 0;

sealed class _Cmd {
  _Cmd() : id = ++_cmdSeq;
  final int id;
}

class _LoadCmd extends _Cmd {
  _LoadCmd(this.path, this.nCtx, this.nThreads, this.nBatch, this.nGpuLayers, this.backend, this.cacheDir);
  final String path;
  final int nCtx;
  final int nThreads;
  final int nBatch;
  final int nGpuLayers;

  /// `agenthq_backend` (0 cpu, 1 vulkan, 2 opencl).
  final int backend;
  final String? cacheDir;
}

class _UnloadCmd extends _Cmd {}

class _GpuInfoCmd extends _Cmd {}

class _GenerateCmd extends _Cmd {
  _GenerateCmd({
    required int id,
    required this.prompt,
    required this.maxTokens,
    required this.temperature,
    required this.topP,
    required this.minP,
    required this.grammar,
    required this.stop,
    required this.flushIntervalMs,
    required this.flushBytes,
  }) : generationId = id;
  final int generationId;
  final String prompt;
  final int maxTokens;
  final double temperature;
  final double topP;
  final double minP;
  final String? grammar;
  final List<String> stop;
  final int flushIntervalMs;
  final int flushBytes;
}

class _CancelCmd extends _Cmd {
  _CancelCmd(this.generationId);
  final int generationId;
}

class _Reply {
  const _Reply(this.id, {this.error, this.errorCode = 0, this.stats});
  final int id;
  final String? error;

  /// Kode `agenthq_error` bila [error] berasal dari [LlamaNativeException].
  final int errorCode;
  final Map<String, Object?>? stats;
}

/// Kemajuan generate dari worker: jumlah piece (≈ token) yang sudah dibaca;
/// `prompt == true` dikirim tepat sebelum prompt diproses.
class _Progress {
  const _Progress(this.id, this.tokens, {this.prompt = false});
  final int id;
  final int tokens;
  final bool prompt;
}

class _Chunk {
  const _Chunk(this.id, this.text);
  final int id;
  final String text;
}

class _WorkerInit {
  const _WorkerInit(this.replyPort, this.createApi);
  final SendPort replyPort;
  final LlamaApiFactory createApi;
}

// --- worker isolate ---------------------------------------------------------

void _workerMain(_WorkerInit init) {
  final worker = _Worker(init.replyPort, init.createApi());
  final commands = ReceivePort();
  init.replyPort.send(commands.sendPort);
  commands.listen(worker.handle);
}

class _Worker {
  _Worker(this.out, this.api);
  final SendPort out;
  final LlamaNativeApi api;

  int? _generating;
  bool _cancelRequested = false;
  bool _cacheDirSet = false;

  Future<void> handle(Object? msg) async {
    switch (msg) {
      case _LoadCmd c:
        _reply(c.id, () {
          if (!_cacheDirSet) {
            _cacheDirSet = true;
            api.setCacheDir(c.cacheDir);
          }
          api.load(c.path,
              nCtx: c.nCtx, nThreads: c.nThreads, nBatch: c.nBatch, nGpuLayers: c.nGpuLayers, backend: c.backend);
          return {
            ...api.stats(),
            'gpu_layers': api.gpuLayers,
            'gpu_backend': api.gpuBackend,
            'model_layers': api.modelLayers,
          };
        });
      case _UnloadCmd c:
        _reply(c.id, () {
          api.unload();
          return null;
        });
      case _GpuInfoCmd c:
        _reply(c.id, () {
          // Each backend is queried separately so one failing probe does not
          // hide the other; a throwing probe counts as "not available".
          Map<String, Object?> probe(LocalGpuBackend b) {
            try {
              return api.gpuInfo(b.nativeCode);
            } catch (e) {
              return {'available': false, 'backend': b.name, 'reason': 'Deteksi gagal: $e'};
            }
          }

          return {'vulkan': probe(LocalGpuBackend.vulkan), 'opencl': probe(LocalGpuBackend.opencl)};
        });
      case _CancelCmd c:
        if (_generating == c.generationId) {
          _cancelRequested = true;
          api.stop();
        }
      case _GenerateCmd c:
        await _generate(c);
      default:
        break;
    }
  }

  void _reply(int id, Map<String, Object?>? Function() body) {
    try {
      out.send(_Reply(id, stats: body()));
    } catch (e) {
      out.send(_Reply(id, error: e.toString(), errorCode: e is LlamaNativeException ? e.code : 0));
    }
  }

  Future<void> _generate(_GenerateCmd c) async {
    final id = c.generationId;
    if (_generating != null) {
      out.send(_Reply(c.id, error: 'Generate lain masih berjalan'));
      return;
    }
    _generating = id;
    _cancelRequested = false;
    try {
      out.send(_Progress(id, 0, prompt: true));
      api.start(
        c.prompt,
        maxTokens: c.maxTokens,
        temperature: c.temperature,
        topP: c.topP,
        minP: c.minP,
        grammar: c.grammar,
      );
      await _stream(c);
      out.send(_Reply(c.id, stats: api.stats()));
    } catch (e) {
      out.send(_Reply(c.id, error: e.toString(), errorCode: e is LlamaNativeException ? e.code : 0));
    } finally {
      _generating = null;
    }
  }

  Future<void> _stream(_GenerateCmd c) async {
    final id = c.generationId;
    final bytes = BytesBuilder(copy: false);
    final text = StringBuffer();
    final stop = c.stop.where((s) => s.isNotEmpty).toList();
    final holdBack = stop.isEmpty ? 0 : stop.map((s) => s.length).reduce((a, b) => a > b ? a : b) - 1;
    final clock = Stopwatch()..start();
    var lastFlush = 0;
    var lastProgress = -1000;
    var tokens = 0;
    var emitted = 0; // chars of [text] already sent

    void flush({required bool force}) {
      final limit = force ? text.length : text.length - holdBack;
      if (limit <= emitted) return;
      final pending = limit - emitted;
      if (!force && pending < c.flushBytes && clock.elapsedMilliseconds - lastFlush < c.flushIntervalMs) {
        return;
      }
      out.send(_Chunk(id, text.toString().substring(emitted, limit)));
      emitted = limit;
      lastFlush = clock.elapsedMilliseconds;
    }

    try {
      while (!_cancelRequested) {
        final piece = api.next();
        if (piece == null) break;
        tokens++;
        // Progress at most every 250 ms (and on the very first token so the UI
        // switches from "memproses prompt" to "menghasilkan" immediately).
        if (tokens == 1 || clock.elapsedMilliseconds - lastProgress >= 250) {
          out.send(_Progress(id, tokens));
          lastProgress = clock.elapsedMilliseconds;
        }
        bytes.add(piece);
        final buffered = bytes.toBytes();
        final complete = completeUtf8Length(buffered);
        if (complete > 0) {
          text.write(utf8.decode(buffered.sublist(0, complete), allowMalformed: true));
          bytes.clear();
          if (complete < buffered.length) bytes.add(buffered.sublist(complete));
        }
        final cut = _findStop(text.toString(), stop, emitted);
        if (cut >= 0) {
          final kept = text.toString().substring(0, cut);
          text
            ..clear()
            ..write(kept);
          api.stop();
          break;
        }
        flush(force: false);
        // Yield so a cancel command can be processed between tokens.
        await Future<void>.delayed(Duration.zero);
      }
    } finally {
      // Deliver whatever was produced, also on cancel or native error.
      if (bytes.isNotEmpty) text.write(utf8.decode(bytes.takeBytes(), allowMalformed: true));
      flush(force: true);
    }
  }

  static int _findStop(String text, List<String> stop, int from) {
    var best = -1;
    for (final s in stop) {
      final i = text.indexOf(s, from > 0 ? from - s.length + 1 : 0);
      if (i >= 0 && (best < 0 || i < best)) best = i;
    }
    return best;
  }
}

/// Panjang awalan [bytes] yang merupakan rangkaian UTF-8 lengkap. Sisa byte
/// (maks. 3) milik satu code point yang belum selesai ditahan untuk piece
/// berikutnya.
int completeUtf8Length(Uint8List bytes) {
  final n = bytes.length;
  var i = n - 1;
  // Find the start of the last code point (max 3 continuation bytes back).
  while (i >= 0 && i >= n - 4 && (bytes[i] & 0xC0) == 0x80) {
    i--;
  }
  if (i < 0) return n;
  final lead = bytes[i];
  final expected = lead < 0x80
      ? 1
      : (lead & 0xE0) == 0xC0
          ? 2
          : (lead & 0xF0) == 0xE0
              ? 3
              : (lead & 0xF8) == 0xF0
                  ? 4
                  : 1; // invalid lead byte: let the decoder replace it
  return (n - i) >= expected ? n : i;
}
