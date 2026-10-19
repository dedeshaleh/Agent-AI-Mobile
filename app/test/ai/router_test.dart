import 'dart:io';

import 'package:agent_hq/agents/agent_role.dart';
import 'package:agent_hq/ai/ai_provider.dart';
import 'package:agent_hq/ai/ai_router.dart';
import 'package:agent_hq/ai/ai_settings.dart';
import 'package:agent_hq/ai/api_key_store.dart';
import 'package:agent_hq/ai/local/local_engine.dart';
import 'package:agent_hq/ai/provider_factory.dart';
import 'package:agent_hq/ai/usage_log.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';

const _remote = ProviderConfig(
  id: 'oai',
  kind: AiProviderKind.openaiCompatible,
  name: 'OpenAI',
  baseUrl: 'https://api.example.com',
  modelId: 'gpt-x',
);
const _req = AiRequest(messages: [AiMessage.user('Halo')]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;
  late AiSettingsStore store;
  late InMemoryApiKeyStore keys;
  late UsageLog usage;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('agenthq_router');
    store = AiSettingsStore(await SharedPreferences.getInstance());
    keys = InMemoryApiKeyStore();
    await keys.write('oai', 'sk-test');
    usage = UsageLog(directoryPath: tmp.path);
  });

  tearDown(() => tmp.delete(recursive: true));

  AiRouter router(CountingClient client, FakeLocalEngine engine) => AiRouter(
        settingsStore: store,
        keyStore: keys,
        localEngine: engine,
        httpClient: client,
        usageLog: usage,
        retryBackoff: const Duration(milliseconds: 1),
      );

  Future<String> run(AiRouter r, AgentRole role, {void Function(String, String)? onFallback}) async {
    final b = StringBuffer();
    await for (final c in r.chat(role, _req, missionId: 'm1', onFallback: onFallback)) {
      b.write(c.text);
    }
    return b.toString();
  }

  test('offlineOnly: tidak pernah menyentuh jaringan walau ada penugasan remote', () async {
    await store.save(AiSettings.defaults.upsertProvider(_remote).assign(AgentRole.strategist, 'oai'));
    final client = CountingClient((_) async => fail('tidak boleh ada HTTP'));
    final r = router(client, FakeLocalEngine(chunks: ['lokal']));
    expect(r.providerIdFor(AgentRole.strategist), ProviderConfig.localId);
    expect((await r.resolve(AgentRole.strategist)).isLocal, isTrue);
    expect(await run(r, AgentRole.strategist), 'lokal');
    expect(client.requests, isEmpty);
    expect(usage.totalsPerProvider[ProviderConfig.localId]?.calls, 1);
  });

  test('hybrid: remote untuk yang ditugaskan, lokal untuk lainnya', () async {
    await store.save(AiSettings.defaults
        .copyWith(mode: AiMode.hybrid)
        .upsertProvider(_remote)
        .assign(AgentRole.strategist, 'oai'));
    final client = CountingClient((_) async => sse([
          (null, {'choices': [{'delta': {'content': 'cloud'}}], 'usage': {'prompt_tokens': 3, 'completion_tokens': 1}}),
          (null, '[DONE]'),
        ]));
    final r = router(client, FakeLocalEngine(chunks: ['lokal']));
    expect(r.providerIdFor(AgentRole.strategist), 'oai');
    expect(r.providerIdFor(AgentRole.data), ProviderConfig.localId);
    expect(await run(r, AgentRole.strategist), 'cloud');
    expect(await run(r, AgentRole.data), 'lokal');
    expect(client.requests.length, 1);
    expect(usage.totalsPerProvider['oai']?.inputTokens, 3);
    expect(usage.totalsPerMission['m1']?.calls, 2);
  });

  test('hybrid: 429 dicoba ulang 2x lalu fallback ke lokal dengan onFallback', () async {
    await store.save(AiSettings.defaults.copyWith(mode: AiMode.hybrid).upsertProvider(_remote).assign(AgentRole.reporter, 'oai'));
    final client = CountingClient((_) async => http.Response('{"error":{"message":"rate"}}', 429));
    final r = router(client, FakeLocalEngine(chunks: ['lokal']));
    String? fallbackId;
    final text = await run(r, AgentRole.reporter, onFallback: (id, reason) => fallbackId = id);
    expect(text, 'lokal');
    expect(client.requests.length, 3);
    expect(fallbackId, 'oai');
    final t = usage.totalsPerProvider['oai']!;
    expect(t.calls, 3);
    expect(t.failures, 3);
  });

  test('401 tidak di-retry, langsung fallback; tanpa lokal siap -> error', () async {
    await store.save(AiSettings.defaults.copyWith(mode: AiMode.hybrid).upsertProvider(_remote).assign(AgentRole.reporter, 'oai'));
    final client = CountingClient((_) async => http.Response('', 401));
    final r = router(client, FakeLocalEngine(chunks: ['lokal']));
    expect(await run(r, AgentRole.reporter), 'lokal');
    expect(client.requests.length, 1);

    final r2 = router(CountingClient((_) async => http.Response('', 401)), FakeLocalEngine(initial: LocalEngineState.unloaded));
    expect(() => run(r2, AgentRole.reporter), throwsA(isA<AiProviderException>().having((e) => e.statusCode, 'status', 401)));
  });

  test('cloudPreferred: remote pertama yang aktif untuk semua role', () async {
    await store.save(AiSettings.defaults.copyWith(mode: AiMode.cloudPreferred).upsertProvider(_remote));
    final client = CountingClient((_) async => sse([(null, {'choices': [{'delta': {'content': 'cloud'}}]}), (null, '[DONE]')]));
    final r = router(client, FakeLocalEngine(chunks: ['lokal']));
    expect(r.providerIdFor(AgentRole.data), 'oai');
    expect(await run(r, AgentRole.data), 'cloud');

    await store.update((s) => s.upsertProvider(_remote.copyWith(enabled: false)));
    expect(r.providerIdFor(AgentRole.data), ProviderConfig.localId);
  });

  test('testProvider menolak HTTP non-LAN dan LAN tanpa izin', () async {
    final client = CountingClient((_) async => http.Response('{"data":[]}', 200));
    final r = router(client, FakeLocalEngine());
    final bad = await r.testProvider(_remote.copyWith(baseUrl: 'http://api.example.com'), 'k');
    expect(bad.healthy, isFalse);
    final lan = await r.testProvider(_remote.copyWith(baseUrl: 'http://192.168.1.10:11434'), 'k');
    expect(lan.healthy, isFalse);
    expect(client.requests, isEmpty);

    await store.update((s) => s.copyWith(allowInsecureLan: true));
    final ok = await r.testProvider(_remote.copyWith(baseUrl: 'http://192.168.1.10:11434'), 'k');
    expect(ok.healthy, isTrue);
  });

  test('isPrivateHost', () {
    expect(isPrivateHost('localhost'), isTrue);
    expect(isPrivateHost('172.20.0.1'), isTrue);
    expect(isPrivateHost('172.32.0.1'), isFalse);
    expect(isPrivateHost('8.8.8.8'), isFalse);
  });
}
