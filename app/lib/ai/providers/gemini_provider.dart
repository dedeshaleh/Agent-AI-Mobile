/// Provider Google Gemini (`generativelanguage.googleapis.com`, SSE).
library;

// ignore_for_file: prefer_initializing_formals

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../ai_provider.dart';
import 'remote_base.dart';
import 'sse.dart';

class GeminiProvider implements AiProvider {
  GeminiProvider({
    required this.config,
    required http.Client client,
    required String apiKey,
    this.timeout = kDefaultRequestTimeout,
  })  : _client = client,
        _apiKey = apiKey,
        baseUrl = config.baseUrl.trim().isEmpty ? defaultBaseUrl : _trim(config.baseUrl);

  static const defaultBaseUrl = 'https://generativelanguage.googleapis.com';

  /// Saran model untuk UI (belum diverifikasi terhadap katalog terbaru).
  static const suggestedModelId = 'gemini-2.5-flash';
  static const suggestedModelIds = ['gemini-2.5-flash', 'gemini-2.5-pro', 'gemini-2.5-flash-lite'];

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
  AiCapabilities get caps => const AiCapabilities(streaming: true, jsonSchema: true, contextWindow: 1000000);

  Map<String, String> get _headers => {
        'content-type': 'application/json',
        'x-goog-api-key': _apiKey,
      };

  String get _model => Uri.encodeComponent(config.modelId);

  Map<String, Object?> _body(AiRequest req) {
    final system = req.messages.where((m) => m.role == 'system').map((m) => m.content).join('\n\n');
    final contents = <Map<String, Object?>>[];
    for (final m in req.messages) {
      if (m.role == 'system') continue;
      final role = m.role == 'assistant' ? 'model' : 'user';
      if (contents.isNotEmpty && contents.last['role'] == role) {
        (contents.last['parts'] as List).add({'text': m.content});
      } else {
        contents.add({
          'role': role,
          'parts': [
            {'text': m.content}
          ],
        });
      }
    }
    return {
      if (system.isNotEmpty)
        'systemInstruction': {
          'parts': [
            {'text': system}
          ],
        },
      'contents': contents,
      'generationConfig': {
        'maxOutputTokens': req.maxTokens,
        'temperature': req.temperature,
        if (req.stop.isNotEmpty) 'stopSequences': req.stop,
        if (req.jsonSchema != null) 'responseMimeType': 'application/json',
        if (req.jsonSchema != null) 'responseSchema': sanitizeSchema(req.jsonSchema!),
      },
    };
  }

  /// Gemini memakai subset OpenAPI; kunci JSON Schema yang tidak dikenal
  /// membuat request ditolak, jadi dibuang secara rekursif.
  static Map<String, Object?> sanitizeSchema(Map<String, Object?> schema) {
    const drop = {'additionalProperties', r'$schema', r'$id', 'title', 'default', 'examples', 'const'};
    final out = <String, Object?>{};
    schema.forEach((k, v) {
      if (drop.contains(k)) return;
      if (v is Map<String, Object?>) {
        out[k] = k == 'properties'
            ? v.map((pk, pv) => MapEntry(pk, pv is Map<String, Object?> ? sanitizeSchema(pv) : pv))
            : sanitizeSchema(v);
      } else if (v is Map) {
        out[k] = sanitizeSchema(v.cast<String, Object?>());
      } else if (v is List && k != 'required' && k != 'enum') {
        out[k] = [for (final e in v) e is Map ? sanitizeSchema(e.cast<String, Object?>()) : e];
      } else {
        out[k] = v;
      }
    });
    return out;
  }

  @override
  Stream<AiChunk> chat(AiRequest request, {CancelToken? cancel}) async* {
    final uri = Uri.parse('$baseUrl/v1beta/models/$_model:streamGenerateContent?alt=sse');
    final req = http.Request('POST', uri)
      ..headers.addAll(_headers)
      ..body = jsonEncode(_body(request));
    final bytes = await sendStreaming(_client, req, cancel: cancel, timeout: timeout);
    AiUsage? usage;
    await for (final ev in parseSse(bytes)) {
      final Object? json;
      try {
        json = jsonDecode(ev.data);
      } catch (_) {
        continue;
      }
      if (json is! Map) continue;
      if (json['error'] != null) {
        final err = json['error'];
        throw AiProviderException(err is Map ? '${err['message']}' : '$err');
      }
      final meta = json['usageMetadata'];
      if (meta is Map) {
        usage = AiUsage(
          inputTokens: asInt(meta['promptTokenCount']),
          outputTokens: asInt(meta['candidatesTokenCount']),
        );
      }
      final candidates = json['candidates'];
      if (candidates is List && candidates.isNotEmpty) {
        final first = candidates.first as Map;
        final parts = (first['content'] as Map?)?['parts'];
        if (parts is List) {
          for (final p in parts) {
            final text = (p as Map)['text'];
            if (text is String && text.isNotEmpty) yield AiChunk(text);
          }
        }
        if (first['finishReason'] == 'SAFETY') {
          throw const AiProviderException('Jawaban diblokir filter keamanan Gemini');
        }
      }
    }
    if (cancel?.isCancelled ?? false) return;
    yield AiChunk.done(usage: usage);
  }

  @override
  Future<HealthResult> healthCheck() async {
    try {
      final res = await sendJson(_client, 'GET', Uri.parse('$baseUrl/v1beta/models/$_model'), headers: _headers);
      if (res.statusCode >= 200 && res.statusCode < 300) {
        String name = config.modelId;
        try {
          name = ((jsonDecode(res.body) as Map)['displayName'] as String?) ?? name;
        } catch (_) {}
        return HealthResult.ok('Terhubung ($name)');
      }
      throw exceptionForStatus(res.statusCode, res.body);
    } catch (e) {
      return healthFailure(e);
    }
  }
}
