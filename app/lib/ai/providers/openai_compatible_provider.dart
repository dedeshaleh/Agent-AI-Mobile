/// Provider untuk endpoint `/v1/chat/completions` (OpenAI, OpenRouter, Groq,
/// DeepSeek, Ollama, LM Studio, dsb.).
library;

// ignore_for_file: prefer_initializing_formals

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../ai_provider.dart';
import 'remote_base.dart';
import 'sse.dart';

class OpenAiCompatibleProvider implements AiProvider {
  OpenAiCompatibleProvider({
    required this.config,
    required http.Client client,
    String? apiKey,
    this.timeout = kDefaultRequestTimeout,
  })  : _client = client,
        _apiKey = apiKey ?? '',
        baseUrl = normalizeBaseUrl(config.baseUrl);

  final ProviderConfig config;
  final http.Client _client;
  final String _apiKey;
  final Duration timeout;

  /// Base URL tanpa trailing `/` dan tanpa `/v1`.
  final String baseUrl;

  /// `https://host/v1/` dan `https://host` sama-sama menjadi `https://host`.
  static String normalizeBaseUrl(String raw) {
    var url = raw.trim();
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    if (url.toLowerCase().endsWith('/v1')) url = url.substring(0, url.length - 3);
    return url;
  }

  @override
  String get id => config.id;
  @override
  String get displayName => config.name;
  @override
  bool get isLocal => false;
  @override
  AiCapabilities get caps => const AiCapabilities(streaming: true, jsonSchema: true, contextWindow: 32768);

  Map<String, String> get _headers => {
        'content-type': 'application/json',
        'accept': 'text/event-stream',
        if (_apiKey.isNotEmpty) 'authorization': 'Bearer $_apiKey',
      };

  Map<String, Object?> _body(AiRequest req, {bool stream = true}) => {
        'model': config.modelId,
        'messages': [for (final m in req.messages) m.toJson()],
        'max_tokens': req.maxTokens,
        'temperature': req.temperature,
        'stream': stream,
        if (stream) 'stream_options': {'include_usage': true},
        if (req.stop.isNotEmpty) 'stop': req.stop,
        if (req.jsonSchema != null)
          'response_format': {
            'type': 'json_schema',
            'json_schema': {'name': 'response', 'schema': req.jsonSchema, 'strict': false},
          },
      };

  @override
  Stream<AiChunk> chat(AiRequest request, {CancelToken? cancel}) async* {
    final req = http.Request('POST', Uri.parse('$baseUrl/v1/chat/completions'))
      ..headers.addAll(_headers)
      ..body = jsonEncode(_body(request));
    final bytes = await sendStreaming(_client, req, cancel: cancel, timeout: timeout);
    AiUsage? usage;
    var finished = false;
    await for (final ev in parseSse(bytes)) {
      if (ev.data == '[DONE]') {
        finished = true;
        break;
      }
      final Object? json;
      try {
        json = jsonDecode(ev.data);
      } catch (_) {
        continue; // keep-alive atau baris tidak valid
      }
      if (json is! Map) continue;
      if (json['error'] != null) {
        final err = json['error'];
        throw AiProviderException(err is Map ? '${err['message']}' : '$err');
      }
      final u = json['usage'];
      if (u is Map) {
        usage = AiUsage(inputTokens: asInt(u['prompt_tokens']), outputTokens: asInt(u['completion_tokens']));
      }
      final choices = json['choices'];
      if (choices is List && choices.isNotEmpty) {
        final delta = (choices.first as Map)['delta'];
        final text = delta is Map ? delta['content'] : null;
        if (text is String && text.isNotEmpty) yield AiChunk(text);
      }
    }
    if (!finished && (cancel?.isCancelled ?? false)) return;
    yield AiChunk.done(usage: usage);
  }

  @override
  Future<HealthResult> healthCheck() async {
    try {
      final res = await sendJson(_client, 'GET', Uri.parse('$baseUrl/v1/models'), headers: _headers);
      if (res.statusCode >= 200 && res.statusCode < 300) {
        return HealthResult.ok(_describeModels(res.body));
      }
      if (res.statusCode == 401 || res.statusCode == 403) {
        throw exceptionForStatus(res.statusCode, res.body);
      }
      // Beberapa server tidak punya /v1/models; coba chat 1 token.
      final chat = await sendJson(
        _client,
        'POST',
        Uri.parse('$baseUrl/v1/chat/completions'),
        headers: _headers,
        body: _body(const AiRequest(messages: [AiMessage.user('ping')], maxTokens: 1), stream: false),
      );
      if (chat.statusCode >= 200 && chat.statusCode < 300) return const HealthResult.ok();
      throw exceptionForStatus(chat.statusCode, chat.body);
    } catch (e) {
      return healthFailure(e);
    }
  }

  String _describeModels(String body) {
    try {
      final data = (jsonDecode(body) as Map)['data'];
      if (data is List) {
        final ids = data.map((m) => (m as Map)['id']).whereType<String>().toList();
        if (config.modelId.isNotEmpty && ids.isNotEmpty && !ids.contains(config.modelId)) {
          return 'Terhubung, tetapi model "${config.modelId}" tidak ada di daftar (${ids.length} model)';
        }
        return 'Terhubung (${ids.length} model tersedia)';
      }
    } catch (_) {}
    return 'Terhubung';
  }
}
