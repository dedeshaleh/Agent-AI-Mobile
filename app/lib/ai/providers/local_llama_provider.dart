/// Provider lokal: membungkus [LocalEngine] (llama.cpp) sebagai [AiProvider].
library;

import 'dart:async';

import '../ai_provider.dart';
import '../local/local_engine.dart';

class LocalLlamaProvider implements AiProvider {
  LocalLlamaProvider(this.engine, {this.defaultMaxTokens = 256});

  final LocalEngine engine;
  final int defaultMaxTokens;

  @override
  String get id => ProviderConfig.localId;
  @override
  String get displayName => ProviderConfig.local.name;
  @override
  bool get isLocal => true;
  @override
  AiCapabilities get caps => AiCapabilities(
        streaming: true,
        jsonSchema: false,
        contextWindow: engine.loadedModel?.contextLength ?? 2048,
      );

  @override
  Stream<AiChunk> chat(AiRequest request, {CancelToken? cancel}) async* {
    if (engine.state != LocalEngineState.ready) {
      throw const AiProviderException('Model lokal belum siap');
    }
    final messages = <({String role, String content})>[];
    for (final m in request.messages) {
      messages.add((role: m.role, content: m.content));
    }
    if (request.jsonSchema != null) {
      // Tidak ada grammar; cukup instruksi agar jawaban berupa JSON.
      messages.add((role: 'system', content: 'Jawab hanya dengan JSON valid sesuai skema, tanpa teks lain.'));
    }
    final prompt = formatChatMl(messages);
    final options = LocalGenerateOptions(
      maxTokens: request.maxTokens > 0 ? request.maxTokens : defaultMaxTokens,
      temperature: request.temperature,
      stop: ['<|im_end|>', ...request.stop],
    );

    StreamSubscription<void>? cancelSub;
    if (cancel != null) {
      if (cancel.isCancelled) return;
      cancelSub = cancel.onCancel.listen((_) => engine.cancel());
    }
    final filter = _ThinkFilter();
    try {
      await for (final raw in engine.generate(prompt, options)) {
        final visible = filter.push(raw);
        if (visible.isNotEmpty) yield AiChunk(visible);
      }
      final tail = filter.flush();
      if (tail.isNotEmpty) yield AiChunk(tail);
    } on LocalEngineException catch (e) {
      throw AiProviderException(e.message);
    } finally {
      await cancelSub?.cancel();
    }
    if (cancel?.isCancelled ?? false) return;
    yield AiChunk.done(usage: _usageFromStats());
  }

  AiUsage? _usageFromStats() {
    final stats = engine.lastStats;
    final input = stats['prompt_tokens'] ?? stats['input_tokens'];
    final output = stats['output_tokens'] ?? stats['generated_tokens'];
    if (input is! num && output is! num) return null;
    return AiUsage(
      inputTokens: input is num ? input.toInt() : 0,
      outputTokens: output is num ? output.toInt() : 0,
    );
  }

  @override
  Future<HealthResult> healthCheck() async {
    switch (engine.state) {
      case LocalEngineState.ready:
      case LocalEngineState.generating:
        final m = engine.loadedModel;
        return HealthResult.ok(m == null ? 'Siap' : 'Siap (${m.description.isEmpty ? m.path : m.description})');
      case LocalEngineState.loading:
        return const HealthResult.fail('Model sedang dimuat');
      case LocalEngineState.unloaded:
        return const HealthResult.fail('Belum ada model yang dimuat');
      case LocalEngineState.error:
        return const HealthResult.fail('Mesin lokal error');
    }
  }
}

/// Menyaring blok `<think>…</think>` secara streaming. Teks di luar blok
/// diteruskan; tag yang terpotong di batas chunk ditahan dulu.
class _ThinkFilter {
  static const _open = '<think>';
  static const _close = '</think>';
  final _buf = StringBuffer();
  var _inThink = false;

  String push(String chunk) {
    _buf.write(chunk);
    final out = StringBuffer();
    var s = _buf.toString();
    while (true) {
      if (_inThink) {
        final end = s.indexOf(_close);
        if (end < 0) {
          // Simpan hanya ekor yang mungkin awal dari `</think>`.
          s = _partialTail(s, _close);
          break;
        }
        s = s.substring(end + _close.length);
        _inThink = false;
      } else {
        final start = s.indexOf(_open);
        if (start < 0) {
          final hold = _partialTail(s, _open);
          out.write(s.substring(0, s.length - hold.length));
          s = hold;
          break;
        }
        out.write(s.substring(0, start));
        s = s.substring(start + _open.length);
        _inThink = true;
      }
    }
    _buf
      ..clear()
      ..write(s);
    // Buang spasi awal setelah blok think agar jawaban tidak diawali newline.
    return out.toString();
  }

  String flush() {
    final rest = _inThink ? '' : _buf.toString();
    _buf.clear();
    return rest;
  }

  /// Ekor `s` yang merupakan prefix dari `tag` (misal `</thi`).
  static String _partialTail(String s, String tag) {
    final max = tag.length - 1;
    for (var n = max < s.length ? max : s.length; n > 0; n--) {
      if (tag.startsWith(s.substring(s.length - n))) return s.substring(s.length - n);
    }
    return '';
  }
}
