import 'dart:convert';
import 'dart:io';

import 'package:agent_hq/agents/agent_role.dart';
import 'package:agent_hq/ai/ai_provider.dart';
import 'package:agent_hq/ai/ai_settings.dart';
import 'package:agent_hq/ai/api_key_store.dart';
import 'package:agent_hq/ai/usage_log.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ApiKeyStore', () {
    test('masked', () {
      expect(ApiKeyStore.masked('sk-proj-1234567890abcd'), 'sk-…abcd');
      expect(ApiKeyStore.masked('short'), '•••••');
      expect(ApiKeyStore.masked(''), '');
    });

    test('in-memory read/write/delete dengan namespace', () async {
      final s = InMemoryApiKeyStore();
      expect(await s.has('p1'), isFalse);
      await s.write('p1', 'abc');
      expect(await s.read('p1'), 'abc');
      expect(ApiKeyStore.storageKey('p1'), 'agenthq.apikey.p1');
      await s.delete('p1');
      expect(await s.read('p1'), isNull);
    });
  });

  group('AiSettings', () {
    test('default: offlineOnly dan semua role lokal', () {
      const s = AiSettings();
      expect(s.mode, AiMode.offlineOnly);
      for (final r in AgentRole.values) {
        expect(s.assignedProviderId(r), ProviderConfig.localId);
      }
    });

    test('JSON round-trip', () {
      final s = AiSettings.defaults
          .copyWith(mode: AiMode.hybrid, allowInsecureLan: true, contextLength: 4096, threads: 6, maxTokens: 512)
          .upsertProvider(const ProviderConfig(id: 'a', kind: AiProviderKind.anthropic, name: 'Claude', modelId: 'claude-opus-5-5'))
          .assign(AgentRole.strategist, 'a');
      final back = AiSettings.fromJson((jsonDecode(jsonEncode(s.toJson())) as Map).cast<String, Object?>());
      expect(back, s);
      expect(back.assignment[AgentRole.strategist], 'a');
      expect(back.providers.single.kind, AiProviderKind.anthropic);
      expect(jsonEncode(s.toJson()), isNot(contains('apikey')));
    });

    test('removeProvider melepas penugasan', () {
      final s = AiSettings.defaults
          .upsertProvider(const ProviderConfig(id: 'a', kind: AiProviderKind.gemini, name: 'G'))
          .assign(AgentRole.data, 'a')
          .removeProvider('a');
      expect(s.providers, isEmpty);
      expect(s.assignment, isEmpty);
    });

    test('store persist ke SharedPreferences dan notify', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = AiSettingsStore(prefs);
      var notified = 0;
      store.addListener(() => notified++);
      await store.update((s) => s.copyWith(mode: AiMode.cloudPreferred));
      expect(notified, 1);
      expect(AiSettingsStore(prefs).value.mode, AiMode.cloudPreferred);
      await store.reset();
      expect(AiSettingsStore(prefs).value, AiSettings.defaults);
    });
  });

  group('UsageLog', () {
    late Directory tmp;
    setUp(() async => tmp = await Directory.systemTemp.createTemp('agenthq_usage'));
    tearDown(() => tmp.delete(recursive: true));

    test('totals per provider/misi dan persistensi', () async {
      final log = UsageLog(directoryPath: tmp.path);
      final now = DateTime.now();
      await log.record(UsageEntry(timestamp: now, providerId: 'a', missionId: 'm1', inputTokens: 10, outputTokens: 5));
      await log.record(UsageEntry(timestamp: now, providerId: 'a', missionId: 'm2', inputTokens: 1, outputTokens: 1));
      await log.record(UsageEntry(timestamp: now, providerId: 'b', missionId: 'm1', ok: false, error: 'x', role: AgentRole.data));
      final a = log.totalsPerProvider['a']!;
      expect(a.calls, 2);
      expect(a.inputTokens, 11);
      expect(a.outputTokens, 6);
      expect(log.totalsPerProvider['b']!.failures, 1);
      expect(log.totalsPerMission['m1']!.calls, 2);
      expect(log.totalsFor(providerId: 'a', missionId: 'm1').totalTokens, 15);

      final reloaded = UsageLog(directoryPath: tmp.path);
      await reloaded.load();
      expect(reloaded.entries.length, 3);
      expect(reloaded.entries.last.role, AgentRole.data);

      await reloaded.clear();
      expect(reloaded.entries, isEmpty);
      expect(await reloaded.file.exists(), isFalse);
      expect(UsageLog.file('${tmp.path}/x/u.json').directoryPath, endsWith('x'));
    });
  });
}
