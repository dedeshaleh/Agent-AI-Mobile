import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../agents/mission_orchestrator.dart';
import '../app_controller.dart';
import 'theme.dart';

Future<void> showMinutesDialog(BuildContext context, AppController c) {
  final m = c.mission;
  final current = m.hasTranscript
      ? MissionRecord(
          id: m.missionId ?? '-',
          startedAt: DateTime.now(),
          sourceName: m.data?.sourceName ?? 'demo',
          transcript: m.transcript,
          report: m.report,
          facts: const {},
        )
      : null;
  final records = [?current, ...c.history.where((h) => h.id != current?.id)];
  return showDialog<void>(
    context: context,
    builder: (context) => Dialog(
      child: SizedBox(
        width: 760,
        height: 460,
        child: DefaultTabController(
          length: records.length,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 6, 0),
                child: Row(
                  children: [
                    const Expanded(child: Text('Notulen & laporan', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700))),
                    if (c.history.isNotEmpty)
                      TextButton(
                        onPressed: () async {
                          await c.clearHistory();
                          if (context.mounted) Navigator.pop(context);
                        },
                        child: const Text('Hapus riwayat'),
                      ),
                    IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
                  ],
                ),
              ),
              if (records.isEmpty)
                const Expanded(child: Center(child: Text('Belum ada notulen.')))
              else ...[
                TabBar(
                  isScrollable: true,
                  tabAlignment: TabAlignment.start,
                  tabs: [for (final r in records) Tab(text: '${r.sourceName} · ${_stamp(r.startedAt)}')],
                ),
                Expanded(child: TabBarView(children: [for (final r in records) _RecordView(record: r, controller: c)])),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}

String _stamp(DateTime t) =>
    '${t.day.toString().padLeft(2, '0')}/${t.month.toString().padLeft(2, '0')} ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

class _RecordView extends StatelessWidget {
  const _RecordView({required this.record, required this.controller});
  final MissionRecord record;
  final AppController controller;

  String get _exportText => 'AGENT HQ — NOTULEN\nSumber: ${record.sourceName}\nWaktu: ${record.startedAt}\n\n'
      'TRANSKRIP\n${record.transcript.map((l) => '${l.agent.title}: ${l.text}').join('\n')}\n\nLAPORAN\n${record.report}';

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const Text('TRANSKRIP', style: TextStyle(fontSize: 10.5, color: HqColors.muted, letterSpacing: 1.2)),
              for (final line in record.transcript)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(width: 84, child: Text(line.agent.title, style: TextStyle(color: line.agent.color, fontWeight: FontWeight.w600))),
                      Expanded(child: Text(line.text)),
                      const SizedBox(width: 8),
                      SourceBadge(providerId: line.source, providerName: controller.providerName(line.source)),
                    ],
                  ),
                ),
              const SizedBox(height: 12),
              const Text('LAPORAN', style: TextStyle(fontSize: 10.5, color: HqColors.muted, letterSpacing: 1.2)),
              const SizedBox(height: 4),
              SelectableText(record.report.isEmpty ? '(belum ada)' : record.report),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Row(
            children: [
              OutlinedButton.icon(
                onPressed: () => SharePlus.instance.share(ShareParams(text: _exportText, subject: 'Notulen Agent HQ — ${record.sourceName}')),
                icon: const Icon(Icons.share),
                label: const Text('Bagikan teks'),
              ),
              const SizedBox(width: 10),
              const Expanded(child: Text('Ekspor PDF/Excel menyusul di Fase 4.', style: TextStyle(fontSize: 11, color: HqColors.muted))),
            ],
          ),
        ),
      ],
    );
  }
}
