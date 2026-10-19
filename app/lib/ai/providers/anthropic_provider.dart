/// Provider Anthropic Messages API (streaming SSE).
library;

// ignore_for_file: prefer_initializing_formals

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../ai_provider.dart';
import 'remote_base.dart';
import 'sse.dart';

class AnthropicProvider implements AiProvider {
  AnthropicProvider({
    required this.config,
    required http.Client client,
    required String apiKey,
    this.timeout = kDefaultRequestTimeout,
  })  : _client = client,
        _apiKey = apiKey,
        baseUrl = config.baseUrl.trim().isEmpty ? defaultBaseUrl : _trim(config.baseUrl);

  static const defaultBaseUrl = 'https://api.anthropic.com';
  static const apiVersion = '2023-06-01';

  /// Saran model untuk UI; model id tetap dari [ProviderConfig.modelId].
  static const suggestedModelId = 'claude-opus-5-5';
  static const suggestedModelIds = ['claude-opus-5-5', 'claude-sonnet-5-5', 'claude-haiku-5-5'];

  final ProviderConfig config;
  final http.Client _client;
  final String _apiKey;
  final Duration timeout;
  final String baseUrl;

  static String _trim(String s) {
    var u = s.trim();
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    return u;
  }

  @override
  String get id => config.id;
  @override
  String get displayName => config.name;
  @override
  bool get isLocal => false;
  @override
  AiCapabilities get caps => const AiCapabilities(streaming: true, jsonSchema: true, contextWindow: 200000);

  Map<String, String> get _headers => {
        'content-type': 'application/json',
        'accept': 'text/event-stream',
        'x-api-key': _apiKey,
        'anthropic-version': apiVersion,
      };

  Map<String, Object?> _body(AiRequest req, {bool stream = true}) {
    final system = req.messages.where((m) => m.role == 'system').map((m) => m.content).join('\n\n');
    // Model Claude generasi 4.6+ menolak `temperature`; thinking dibiarkan
    // default (adaptif) sehingga tidak ada parameter sampling yang dikirim.
    return {
      'model': config.modelId,
      'max_tokens': req.maxTokens,
      'stream': stream,
      if (system.isNotEmpty) 'system': system,
      'messages': _mergeTurns(req.messages),
      if (req.stop.isNotEmpty) 'stop_sequences': req.stop,
      if (req.jsonSchema != null)
        'output_config': {
          'format': {'type': 'json_schema', 'schema': req.jsonSchema},
        },
    };
  }

  /// Messages API menuntut giliran user/assistant bergantian dan diawali user.
  static List<Map<String, String>> _mergeTurns(List<AiMessage> messages) {
    final out = <Map<String, String>>[];
    for (final m in messages) {
      if (m.role == 'system') continue;
      final role = m.role == 'assistant' ? 'assistant' : 'user';
      if (out.isNotEmpty && out.last['role'] == role) {
        out.last['content'] = '${out.last['content']}\n\n${m.content}';
      } else {
        out.add({'role': role, 'content': m.content});
      }
    }
    if (out.isEmpty || out.first['role'] != 'user') {
      out.insert(0, {'role': 'user', 'content': '(lanjutkan)'});
    }
    return out;
  }

  @override
  Stream<AiChunk> chat(AiRequest request, {CancelToken? cancel}) async* {
    final req = http.Request('POST', Uri.parse('$baseUrl/v1/messages'))
      ..headers.addAll(_headers)
      ..body = jsonEncode(_body(request));
    final bytes = await sendStreaming(_client, req, cancel: cancel, timeout: timeout);
    var input = 0;
    var output = 0;
    var finished = false;
    await for (final ev in parseSse(bytes)) {
      final Object? json;
      try {
        json = jsonDecode(ev.data);
      } catch (_) {
        continue;
      }
      if (json is! Map) continue;
      final type = (json['type'] ?? ev.event) as String?;
      switch (type) {
        case 'message_start':
          final usage = (json['message'] as Map?)?['usage'];
          if (usage is Map) input = asInt(usage['input_tokens']);
        case 'content_block_delta':
          final delta = json['delta'];
          if (delta is Map && delta['type'] == 'text_delta') {
            final text = delta['text'];
            if (text is String && text.isNotEmpty) yield AiChunk(text);
          }
        case 'message_delta':
          final usage = json['usage'];
          if (usage is Map) {
            output = asInt(usage['output_tokens']);
            if (usage['input_tokens'] != null) input = asInt(usage['input_tokens']);
          }
        case 'message_stop':
          finished = true;
        case 'error':
          final err = json['error'];
          final msg = err is Map ? '${err['message']}' : '$err';
          final overloaded = err is Map && err['type'] == 'overloaded_error';
          throw AiProviderException(msg, retriable: overloaded);
      }
      if (finished) break;
    }
    if (!finished && (cancel?.isCancelled ?? false)) return;
    yield AiChunk.done(usage: AiUsage(inputTokens: input, outputTokens: output));
  }

  @override
  Future<HealthResult> healthCheck() async {
    try {
      final uri = Uri.parse('$baseUrl/v1/models/${Uri.encodeComponent(config.modelId)}');
      final res = await sendJson(_client, 'GET', uri, headers: {
        'x-api-key': _apiKey,
        'anthropic-version': apiVersion,
      });
      if (res.statusCode >= 200 && res.statusCode < 300) {
        String name = config.modelId;
        try {
          name = ((jsonDecode(res.body) as Map)['display_name'] as String?) ?? name;
        } catch (_) {}
        return HealthResult.ok('Terhubung ($name)');
      }
      throw exceptionForStatus(res.statusCode, res.body);
    } catch (e) {
      return healthFailure(e);
    }
  }
}
