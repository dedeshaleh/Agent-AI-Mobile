/// Log pemakaian token per provider dan per misi (PRD §6.4), disimpan
/// sebagai file JSON di direktori yang disuntikkan.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../agents/agent_role.dart';

@immutable
class UsageEntry {
  const UsageEntry({
    required this.timestamp,
    required this.providerId,
    this.missionId,
    this.role,
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.ok = true,
    this.error,
  });

  final DateTime timestamp;
  final String providerId;
  final String? missionId;
  final AgentRole? role;
  final int inputTokens;
  final int outputTokens;
  final bool ok;
  final String? error;

  Map<String, Object?> toJson() => {
        'ts': timestamp.toUtc().toIso8601String(),
        'provider': providerId,
        if (missionId != null) 'mission': missionId,
        if (role != null) 'role': role!.name,
        'in': inputTokens,
        'out': outputTokens,
        'ok': ok,
        if (error != null) 'error': error,
      };

  factory UsageEntry.fromJson(Map<String, Object?> j) => UsageEntry(
        timestamp: DateTime.tryParse(j['ts'] as String? ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0),
        providerId: j['provider'] as String? ?? '',
        missionId: j['mission'] as String?,
        role: AgentRole.values.where((r) => r.name == j['role']).firstOrNull,
        inputTokens: (j['in'] as num?)?.toInt() ?? 0,
        outputTokens: (j['out'] as num?)?.toInt() ?? 0,
        ok: (j['ok'] as bool?) ?? true,
        error: j['error'] as String?,
      );
}

@immutable
class UsageTotals {
  const UsageTotals({this.calls = 0, this.failures = 0, this.inputTokens = 0, this.outputTokens = 0});
  final int calls;
  final int failures;
  final int inputTokens;
  final int outputTokens;
  int get totalTokens => inputTokens + outputTokens;

  UsageTotals add(UsageEntry e) => UsageTotals(
        calls: calls + 1,
        failures: failures + (e.ok ? 0 : 1),
        inputTokens: inputTokens + e.inputTokens,
        outputTokens: outputTokens + e.outputTokens,
      );
}

class UsageLog extends ChangeNotifier {
  UsageLog({required this.directoryPath, this.fileName = 'usage_log.json', this.maxEntries = 2000});

  /// Dari path file lengkap, mis. `<support dir>/usage_log.json`.
  UsageLog.file(String filePath, {this.maxEntries = 2000})
      : directoryPath = p.dirname(filePath),
        fileName = p.basename(filePath);

  final String directoryPath;
  final String fileName;
  final int maxEntries;

  final List<UsageEntry> _entries = [];
  List<UsageEntry> get entries => List.unmodifiable(_entries);

  File get file => File(p.join(directoryPath, fileName));

  Future<void> load() async {
    final f = file;
    if (!await f.exists()) return;
    try {
      final data = jsonDecode(await f.readAsString());
      _entries
        ..clear()
        ..addAll([
          for (final e in (data as List)) UsageEntry.fromJson((e as Map).cast<String, Object?>()),
        ]);
    } catch (_) {
      _entries.clear();
    }
    notifyListeners();
  }

  Future<void> record(UsageEntry entry) async {
    _entries.add(entry);
    if (_entries.length > maxEntries) _entries.removeRange(0, _entries.length - maxEntries);
    notifyListeners();
    await _save();
  }

  Future<void> clear() async {
    _entries.clear();
    notifyListeners();
    final f = file;
    if (await f.exists()) await f.delete();
  }

  Map<String, UsageTotals> get totalsPerProvider => _totals((e) => e.providerId);

  Map<String, UsageTotals> get totalsPerMission => _totals((e) => e.missionId ?? '');

  UsageTotals totalsFor({String? providerId, String? missionId, DateTime? since}) {
    var t = const UsageTotals();
    for (final e in _entries) {
      if (providerId != null && e.providerId != providerId) continue;
      if (missionId != null && e.missionId != missionId) continue;
      if (since != null && e.timestamp.isBefore(since)) continue;
      t = t.add(e);
    }
    return t;
  }

  Map<String, UsageTotals> _totals(String Function(UsageEntry) key) {
    final out = <String, UsageTotals>{};
    for (final e in _entries) {
      final k = key(e);
      out[k] = (out[k] ?? const UsageTotals()).add(e);
    }
    return out;
  }

  Future<void> _save() async {
    try {
      final f = file;
      await f.parent.create(recursive: true);
      await f.writeAsString(jsonEncode([for (final e in _entries) e.toJson()]));
    } catch (_) {
      // Gagal menulis log tidak boleh menggagalkan misi.
    }
  }
}
