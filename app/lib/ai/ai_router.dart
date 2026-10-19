/// Router AI: memilih provider per agent sesuai mode (PRD §6.4), retry
/// terbatas, fallback ke lokal, dan pencatatan pemakaian.
library;

import 'dart:async';

import 'package:http/http.dart' as http;

import '../agents/agent_role.dart';
import 'ai_provider.dart';
import 'ai_settings.dart';
import 'api_key_store.dart';
import 'local/local_engine.dart';
import 'provider_factory.dart';
import 'providers/local_llama_provider.dart';
import 'usage_log.dart';

class AiRouter {
  AiRouter({
    required this.settingsStore,
    required this.keyStore,
    required this.localEngine,
    required this.httpClient,
    required this.usageLog,
    this.maxRetries = 2,
    this.retryBackoff = const Duration(milliseconds: 400),
    LocalLlamaProvider? localProvider,
  }) : localProvider = localProvider ?? LocalLlamaProvider(localEngine);

  final AiSettingsStore settingsStore;
  final ApiKeyStore keyStore;
  final LocalEngine localEngine;
  final http.Client httpClient;
  final UsageLog usageLog;
  final int maxRetries;
  final Duration retryBackoff;
  final LocalLlamaProvider localProvider;

  AiSettings get _settings => settingsStore.value;

  bool get _localReady => localEngine.state == LocalEngineState.ready;

  /// Id provider yang akan dipakai [role] pada mode saat ini.
  String providerIdFor(AgentRole role) {
    final s = _settings;
    switch (s.mode) {
      case AiMode.offlineOnly:
        return ProviderConfig.localId;
      case AiMode.hybrid:
        return s.assignedProviderId(role);
      case AiMode.cloudPreferred:
        final assigned = s.assignedProviderId(role);
        if (assigned != ProviderConfig.localId) return assigned;
        final firstRemote = s.providers.where((p) => p.enabled).firstOrNull;
        return firstRemote?.id ?? ProviderConfig.localId;
    }
  }

  Future<AiProvider> resolve(AgentRole role) => _build(providerIdFor(role));

  Future<AiProvider> _build(String providerId) async {
    if (providerId == ProviderConfig.localId) return localProvider;
    final cfg = _settings.providerById(providerId);
    if (cfg == null) throw AiProviderException('Provider "$providerId" tidak ditemukan');
    final key = cfg.needsApiKey || cfg.kind == AiProviderKind.custom ? await keyStore.read(cfg.id) : null;
    return buildProvider(
      cfg,
      apiKey: key,
      client: httpClient,
      localEngine: localEngine,
      allowInsecureLan: _settings.allowInsecureLan,
    );
  }

  /// Streaming jawaban. Error retriable dicoba ulang [maxRetries] kali, lalu
  /// jatuh ke provider lokal bila mesin lokal siap. [onFallback] dipanggil
  /// dengan id provider yang gagal dan alasannya (untuk toast).
  Stream<AiChunk> chat(
    AgentRole role,
    AiRequest req, {
    String? missionId,
    CancelToken? cancel,
    void Function(String providerId, String reason)? onFallback,
  }) async* {
    final providerId = providerIdFor(role);
    if (providerId == ProviderConfig.localId) {
      yield* _run(localProvider, req, missionId: missionId, role: role, cancel: cancel);
      return;
    }

    AiProvider remote;
    try {
      remote = await _build(providerId);
    } on AiProviderException catch (e) {
      // Konfigurasi salah (URL/key) tidak layak retry; langsung fallback.
      await _recordFailure(providerId, missionId, role, e.message);
      yield* _fallbackOrThrow(providerId, e, req, missionId, role, cancel, onFallback);
      return;
    }

    for (var attempt = 0; attempt <= maxRetries; attempt++) {
      if (cancel?.isCancelled ?? false) return;
      var emitted = false;
      try {
        await for (final c in _run(remote, req, missionId: missionId, role: role, cancel: cancel)) {
          if (c.text.isNotEmpty) emitted = true;
          yield c;
        }
        return;
      } on AiProviderException catch (e) {
        // Setelah teks sebagian sudah tampil, mengulang akan menduplikasi.
        if (emitted) rethrow;
        if (e.retriable && attempt < maxRetries) {
          await Future<void>.delayed(retryBackoff * (attempt + 1));
          continue;
        }
        yield* _fallbackOrThrow(providerId, e, req, missionId, role, cancel, onFallback);
        return;
      }
    }
  }

  Stream<AiChunk> _fallbackOrThrow(
    String providerId,
    AiProviderException e,
    AiRequest req,
    String? missionId,
    AgentRole role,
    CancelToken? cancel,
    void Function(String, String)? onFallback,
  ) async* {
    if (!_localReady) throw e;
    onFallback?.call(providerId, e.message);
    yield* _run(localProvider, req, missionId: missionId, role: role, cancel: cancel);
  }

  /// Menjalankan satu provider dan mencatat pemakaian saat selesai/gagal.
  Stream<AiChunk> _run(
    AiProvider provider,
    AiRequest req, {
    required String? missionId,
    required AgentRole role,
    CancelToken? cancel,
  }) async* {
    try {
      await for (final c in provider.chat(req, cancel: cancel)) {
        if (c.done) {
          await usageLog.record(UsageEntry(
            timestamp: DateTime.now(),
            providerId: provider.id,
            missionId: missionId,
            role: role,
            inputTokens: c.usage?.inputTokens ?? 0,
            outputTokens: c.usage?.outputTokens ?? 0,
          ));
        }
        yield c;
      }
    } on AiProviderException catch (e) {
      await _recordFailure(provider.id, missionId, role, e.message);
      rethrow;
    } on TimeoutException {
      await _recordFailure(provider.id, missionId, role, 'timeout');
      throw const AiProviderException('Waktu habis', retriable: true);
    }
  }

  Future<void> _recordFailure(String providerId, String? missionId, AgentRole role, String error) =>
      usageLog.record(UsageEntry(
        timestamp: DateTime.now(),
        providerId: providerId,
        missionId: missionId,
        role: role,
        ok: false,
        error: error,
      ));

  /// "Tes Koneksi" di layar pengaturan: membangun provider dari konfigurasi
  /// sementara (belum disimpan) dan menjalankan health check.
  Future<HealthResult> testProvider(ProviderConfig cfg, String? apiKey) async {
    try {
      final provider = buildProvider(
        cfg,
        apiKey: apiKey,
        client: httpClient,
        localEngine: localEngine,
        allowInsecureLan: _settings.allowInsecureLan,
      );
      return await provider.healthCheck();
    } on AiProviderException catch (e) {
      return HealthResult.fail(e.message);
    }
  }
}
