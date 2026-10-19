import 'dart:convert';

import 'package:agent_hq/ai/ai_provider.dart';
import 'package:agent_hq/ai/local/local_engine.dart';
import 'package:agent_hq/ai/providers/anthropic_provider.dart';
import 'package:agent_hq/ai/providers/gemini_provider.dart';
import 'package:agent_hq/ai/providers/local_llama_provider.dart';
import 'package:agent_hq/ai/providers/openai_compatible_provider.dart';
import 'package:agent_hq/ai/providers/sse.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'fakes.dart';

const _req = AiRequest(messages: [AiMessage.system('Kamu asisten'), AiMessage.user('Halo')]);

Future<(String, AiUsage?)> _collect(Stream<AiChunk> s) async {
  final b = StringBuffer();
  AiUsage? usage;
  await for (final c in s) {
    b.write(c.text);
    if (c.done) usage = c.usage;
  }
  return (b.toString(), usage);
}

void main() {
  group('parseSse', () {
    test('menggabungkan data multi-baris dan mengabaikan komentar', () async {
      final input = ': ping\nevent: x\ndata: a\ndata: b\n\ndata: c\r\n\r\n';
      final events = await parseSse(Stream.value(utf8.encode(input))).toList();
      expect(events.length, 2);
      expect(events[0].event, 'x');
      expect(events[0].data, 'a\nb');
      expect(events[1].data, 'c');
    });
  });

  group('OpenAiCompatibleProvider', () {
    final cfg = const ProviderConfig(
      id: 'oai',
      kind: AiProviderKind.openaiCompatible,
      name: 'OpenAI',
      baseUrl: 'https://api.example.com/v1/',
      modelId: 'gpt-x',
    );

    test('normalizeBaseUrl', () {
      expect(OpenAiCompatibleProvider.normalizeBaseUrl('https://a.b/v1/'), 'https://a.b');
      expect(OpenAiCompatibleProvider.normalizeBaseUrl('http://192.168.1.2:11434'), 'http://192.168.1.2:11434');
    });

    test('stream chunk, [DONE], usage dan header', () async {
      final client = CountingClient((req) async {
        expect(req.url.toString(), 'https://api.example.com/v1/chat/completions');
        expect(req.headers['authorization'], 'Bearer sk-test');
        final body = jsonDecode(req.body) as Map;
        expect(body['stream'], true);
        expect(body['stream_options'], {'include_usage': true});
        expect((body['response_format'] as Map)['type'], 'json_schema');
        return sse([
          (null, {'choices': [{'delta': {'role': 'assistant', 'content': ''}}]}),
          (null, {'choices': [{'delta': {'content': 'Hal'}}]}),
          (null, {'choices': [{'delta': {'content': 'o!'}}]}),
          (null, {'choices': [], 'usage': {'prompt_tokens': 7, 'completion_tokens': 3}}),
          (null, '[DONE]'),
        ]);
      });
      final p = OpenAiCompatibleProvider(config: cfg, client: client, apiKey: 'sk-test');
      final (text, usage) = await _collect(p.chat(const AiRequest(messages: [AiMessage.user('hi')], jsonSchema: {'type': 'object'})));
      expect(text, 'Halo!');
      expect(usage?.inputTokens, 7);
      expect(usage?.outputTokens, 3);
    });

    test('tanpa key: tidak ada header Authorization (Ollama)', () async {
      final client = CountingClient((req) async {
        expect(req.headers.containsKey('authorization'), isFalse);
        return sse([(null, {'choices': [{'delta': {'content': 'ok'}}]}), (null, '[DONE]')]);
      });
      final p = OpenAiCompatibleProvider(config: cfg.copyWith(baseUrl: 'http://10.0.0.5:11434'), client: client);
      expect((await _collect(p.chat(_req))).$1, 'ok');
    });

    test('429 menjadi AiProviderException retriable', () async {
      final client = CountingClient((_) async => http.Response('{"error":{"message":"slow down"}}', 429));
      final p = OpenAiCompatibleProvider(config: cfg, client: client, apiKey: 'k');
      expect(
        () => _collect(p.chat(_req)),
        throwsA(isA<AiProviderException>().having((e) => e.retriable, 'retriable', true).having((e) => e.statusCode, 'status', 429)),
      );
    });

    test('healthCheck memakai /v1/models lalu fallback chat', () async {
      final client = CountingClient((req) async {
        if (req.url.path.endsWith('/v1/models')) return http.Response('nope', 404);
        return http.Response('{"choices":[]}', 200);
      });
      final p = OpenAiCompatibleProvider(config: cfg, client: client, apiKey: 'k');
      final h = await p.healthCheck();
      expect(h.healthy, isTrue);
      expect(client.requests.length, 2);
    });
  });

  group('AnthropicProvider', () {
    const cfg = ProviderConfig(id: 'ant', kind: AiProviderKind.anthropic, name: 'Claude', modelId: 'claude-opus-5-5');

    test('parse event stream + usage, header, system field', () async {
      final client = CountingClient((req) async {
        expect(req.url.toString(), 'https://api.anthropic.com/v1/messages');
        expect(req.headers['x-api-key'], 'sk-ant');
        expect(req.headers['anthropic-version'], AnthropicProvider.apiVersion);
        final body = jsonDecode(req.body) as Map;
        expect(body['system'], 'Kamu asisten');
        expect(body['max_tokens'], 256);
        expect(body.containsKey('temperature'), isFalse);
        expect((body['messages'] as List).single, {'role': 'user', 'content': 'Halo'});
        return sse([
          ('message_start', {'type': 'message_start', 'message': {'usage': {'input_tokens': 12, 'output_tokens': 1}}}),
          ('content_block_start', {'type': 'content_block_start', 'index': 0, 'content_block': {'type': 'text', 'text': ''}}),
          ('content_block_delta', {'type': 'content_block_delta', 'index': 0, 'delta': {'type': 'text_delta', 'text': 'Hai '}}),
          ('content_block_delta', {'type': 'content_block_delta', 'index': 0, 'delta': {'type': 'text_delta', 'text': 'juga'}}),
          ('content_block_stop', {'type': 'content_block_stop', 'index': 0}),
          ('message_delta', {'type': 'message_delta', 'delta': {'stop_reason': 'end_turn'}, 'usage': {'output_tokens': 4}}),
          ('message_stop', {'type': 'message_stop'}),
        ]);
      });
      final p = AnthropicProvider(config: cfg, client: client, apiKey: 'sk-ant');
      final (text, usage) = await _collect(p.chat(_req));
      expect(text, 'Hai juga');
      expect(usage?.inputTokens, 12);
      expect(usage?.outputTokens, 4);
    });

    test('event error dilempar', () async {
      final client = CountingClient((_) async => sse([
            ('error', {'type': 'error', 'error': {'type': 'overloaded_error', 'message': 'Overloaded'}}),
          ]));
      final p = AnthropicProvider(config: cfg, client: client, apiKey: 'k');
      expect(() => _collect(p.chat(_req)), throwsA(isA<AiProviderException>().having((e) => e.retriable, 'retriable', true)));
    });
  });

  group('GeminiProvider', () {
    const cfg = ProviderConfig(id: 'gem', kind: AiProviderKind.gemini, name: 'Gemini', modelId: 'gemini-2.5-flash');

    test('parse SSE, mapping role dan systemInstruction', () async {
      final client = CountingClient((req) async {
        expect(req.url.toString(), 'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:streamGenerateContent?alt=sse');
        expect(req.headers['x-goog-api-key'], 'g-key');
        final body = jsonDecode(req.body) as Map;
        expect(((body['systemInstruction'] as Map)['parts'] as List).first, {'text': 'Kamu asisten'});
        final contents = body['contents'] as List;
        expect((contents[0] as Map)['role'], 'user');
        expect((contents[1] as Map)['role'], 'model');
        final gen = body['generationConfig'] as Map;
        expect(gen['responseMimeType'], 'application/json');
        expect((gen['responseSchema'] as Map).containsKey('additionalProperties'), isFalse);
        return sse([
          (null, {'candidates': [{'content': {'parts': [{'text': 'Sela'}], 'role': 'model'}}]}),
          (null, {
            'candidates': [{'content': {'parts': [{'text': 'mat'}], 'role': 'model'}, 'finishReason': 'STOP'}],
            'usageMetadata': {'promptTokenCount': 9, 'candidatesTokenCount': 2, 'totalTokenCount': 11},
          }),
        ]);
      });
      final p = GeminiProvider(config: cfg, client: client, apiKey: 'g-key');
      final (text, usage) = await _collect(p.chat(const AiRequest(
        messages: [AiMessage.system('Kamu asisten'), AiMessage.user('Halo'), AiMessage.assistant('Hai'), AiMessage.user('Lagi')],
        jsonSchema: {'type': 'object', 'additionalProperties': false, 'properties': {'a': {'type': 'string'}}},
      )));
      expect(text, 'Selamat');
      expect(usage?.inputTokens, 9);
      expect(usage?.outputTokens, 2);
    });
  });

  group('LocalLlamaProvider', () {
    test('format ChatML, buang <think>, usage dari stats', () async {
      final engine = FakeLocalEngine(chunks: ['<thi', 'nk>rahasia</th', 'ink>\nHasil ', 'akhir']);
      final p = LocalLlamaProvider(engine);
      final (text, usage) = await _collect(p.chat(_req));
      expect(text.trim(), 'Hasil akhir');
      expect(engine.prompts.single, contains('<|im_start|>system\nKamu asisten /no_think<|im_end|>'));
      expect(engine.prompts.single, endsWith('<|im_start|>assistant\n'));
      expect(usage?.inputTokens, 10);
      expect(p.caps.jsonSchema, isFalse);
    });

    test('cancel memanggil engine.cancel dan health mengikuti state', () async {
      final engine = FakeLocalEngine(chunks: ['a', 'b']);
      final p = LocalLlamaProvider(engine);
      final cancel = CancelToken();
      final sub = p.chat(_req, cancel: cancel).listen((_) => cancel.cancel());
      await sub.asFuture<void>();
      expect(engine.cancelCalls, 1);
      expect((await p.healthCheck()).healthy, isTrue);
      engine.state = LocalEngineState.unloaded;
      expect((await p.healthCheck()).healthy, isFalse);
    });
  });
}
