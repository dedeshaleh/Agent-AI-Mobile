import 'package:flutter/material.dart';

import '../agents/agent_role.dart';
import '../agents/mission_orchestrator.dart';
import '../ai/local/local_engine.dart';
import '../app_controller.dart';
import 'ai_settings_screen.dart';
import 'analytics_sheet.dart';
import 'datasets_screen.dart';
import 'game_view.dart';
import 'minutes_dialog.dart';
import 'model_manager_screen.dart';
import 'theme.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.controller});
  final AppController controller;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  AppController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    c.consentPrompt = _consent;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Android dapat menghentikan proses di background; jeda simulasi agar
    // state misi konsisten saat kembali (PRD §9).
    if (state == AppLifecycleState.paused && c.ready && c.mission.busy && !c.mission.paused) {
      c.mission.setPaused(true);
    }
  }

  Future<bool> _consent(String providerName, String payload) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Kirim ke $providerName?'),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Hanya ringkasan agregat berikut yang dikirim, bukan baris mentah atau file:'),
              const SizedBox(height: 8),
              Container(
                constraints: const BoxConstraints(maxHeight: 180),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(color: HqColors.background, borderRadius: BorderRadius.circular(8)),
                child: SingleChildScrollView(child: Text(payload, style: const TextStyle(fontSize: 11, fontFamily: 'monospace'))),
              ),
              const SizedBox(height: 8),
              const Text('Persetujuan diingat untuk provider ini. Bisa dicabut di Pengaturan AI.', style: TextStyle(color: HqColors.muted, fontSize: 12)),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Batal')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Kirim')),
        ],
      ),
    );
    return ok ?? false;
  }

  void _toast(String message, {bool error = false}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: error ? HqColors.danger.withValues(alpha: 0.9) : HqColors.panelAlt,
    ));
  }

  Future<void> _analyze() async {
    final outcome = await c.importDatasets();
    if (!mounted || outcome == null) return;
    if (outcome.okCount == 0) {
      _toast(outcome.files.first.error ?? 'Impor gagal.', error: true);
      return;
    }
    if (outcome.errorCount > 0) {
      await showImportSummary(context, outcome);
      if (!mounted) return;
    }
    final error = await c.analyzeSelectedDatasets();
    if (!mounted) return;
    if (error != null) {
      _toast(error, error: true);
      return;
    }
    if (c.analysis != null) _openAnalytics();
  }

  Future<void> _openDatasets() async {
    final analyzed = await Navigator.push<bool>(
      context,
      MaterialPageRoute<bool>(builder: (_) => DatasetsScreen(controller: c)),
    );
    if (mounted && analyzed == true && c.analysis != null) _openAnalytics();
  }

  void _openAnalytics() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => AnalyticsSheet(controller: c, onStartMission: _startMission),
    );
  }

  Future<void> _startMission() async {
    final started = await c.startMission();
    if (!mounted) return;
    if (!started) _toast('Misi tidak dimulai. Pastikan file sudah dianalisis dan tidak ada misi berjalan.');
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: c,
      builder: (context, _) {
        if (c.startupError != null) {
          return Scaffold(body: Center(child: Padding(padding: const EdgeInsets.all(24), child: Text('Gagal memulai: ${c.startupError}'))));
        }
        if (!c.ready) return const Scaffold(body: Center(child: CircularProgressIndicator()));
        final m = c.mission;
        return Scaffold(
          body: SafeArea(
            child: Column(
              children: [
                _Header(controller: c),
                Expanded(
                  child: Row(
                    children: [
                      Expanded(
                        flex: 62,
                        child: Stack(
                          children: [
                            Positioned.fill(child: GameView(bridge: c.game)),
                            if (m.streamingAgent != null) Positioned(left: 10, right: 10, bottom: 10, child: _StreamingBubble(controller: c)),
                          ],
                        ),
                      ),
                      SizedBox(width: 340, child: _SidePanel(controller: c)),
                    ],
                  ),
                ),
                _ActionBar(
                  controller: c,
                  onAnalyze: _analyze,
                  onOpenDatasets: _openDatasets,
                  onOpenAnalytics: _openAnalytics,
                  onStartMission: _startMission,
                  onToast: _toast,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final m = controller.mission;
    final engineState = controller.engine.state;
    final status = m.paused
        ? 'DIJEDA'
        : switch (m.phase) {
            MissionPhase.idle => 'KANTOR SIAP',
            MissionPhase.dataPrep => 'VALIDASI DATA',
            MissionPhase.analysis => 'ANALISIS KPI',
            MissionPhase.strategy => 'INTERPRETASI',
            MissionPhase.meeting => 'MEETING AKTIF',
            MissionPhase.report => 'MENYUSUN LAPORAN',
            MissionPhase.done => 'MISI SELESAI',
            MissionPhase.failed => 'MISI GAGAL',
          };
    final modelLabel = switch (engineState) {
      LocalEngineState.ready => 'Model lokal siap',
      LocalEngineState.loading => 'Memuat model…',
      LocalEngineState.generating => 'Model bekerja…',
      LocalEngineState.error => 'Model error',
      LocalEngineState.unloaded => 'Model belum dimuat',
    };
    return Container(
      height: 46,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      color: HqColors.panel,
      child: Row(
        children: [
          const Text('AGENT / HQ', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, letterSpacing: 1.5)),
          const SizedBox(width: 10),
          const Text('KANTOR AI · FLUTTER + UNITY', style: TextStyle(fontSize: 10, color: HqColors.muted, letterSpacing: 1)),
          const Spacer(),
          _Chip(status, color: m.phase == MissionPhase.failed ? HqColors.danger : HqColors.accent),
          const SizedBox(width: 8),
          _Chip(modelLabel, color: engineState == LocalEngineState.ready ? HqColors.local : HqColors.muted),
          const SizedBox(width: 8),
          _Chip(controller.settings.mode.label, color: HqColors.cloud),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip(this.text, {required this.color});
  final String text;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(999)),
        child: Text(text, style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600)),
      );
}

class _SidePanel extends StatelessWidget {
  const _SidePanel({required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final m = controller.mission;
    final selected = m.agents[m.selected]!;
    return Container(
      color: HqColors.panel,
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('TIM KAMU', style: TextStyle(fontSize: 11, color: HqColors.muted, letterSpacing: 1)),
          const SizedBox(height: 6),
          for (final role in AgentRole.values)
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: InkWell(
                onTap: () => m.select(role),
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: role == m.selected ? role.color.withValues(alpha: 0.16) : HqColors.panelAlt,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Container(width: 9, height: 9, decoration: BoxDecoration(color: role.color, shape: BoxShape.circle)),
                      const SizedBox(width: 8),
                      Text(role.title, style: TextStyle(color: role.color, fontWeight: FontWeight.w600)),
                      const Spacer(),
                      Text(m.agents[role]!.state.wire, style: const TextStyle(fontSize: 11, color: HqColors.muted)),
                    ],
                  ),
                ),
              ),
            ),
          const SizedBox(height: 6),
          Expanded(
            flex: 3,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: HqColors.panelAlt, borderRadius: BorderRadius.circular(10)),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(m.selected.title, style: TextStyle(fontSize: 20, color: m.selected.color, fontWeight: FontWeight.w700)),
                    Text(m.selected.duty, style: const TextStyle(fontSize: 12, color: HqColors.muted)),
                    const SizedBox(height: 8),
                    _kv('STATUS', '${selected.state.wire}\n${selected.activity}'),
                    _kv('LOKASI', selected.roomIndex < 0 ? 'Koridor' : OfficeRoom.fromIndex(selected.roomIndex).label),
                    const SizedBox(height: 4),
                    SourceBadge(providerId: selected.providerId, providerName: controller.providerName(selected.providerId)),
                    const SizedBox(height: 8),
                    const Text('CATATAN TERAKHIR', style: TextStyle(fontSize: 10, color: HqColors.muted, letterSpacing: 1)),
                    for (final h in selected.history.reversed.take(4)) Text('• $h', style: const TextStyle(fontSize: 12)),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Expanded(
            flex: 2,
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: HqColors.background, borderRadius: BorderRadius.circular(10)),
              child: ListView(
                reverse: true,
                children: [for (final line in m.log.reversed.take(30)) Text(line, style: const TextStyle(fontSize: 10.5, color: HqColors.muted))],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(k, style: const TextStyle(fontSize: 10, color: HqColors.muted, letterSpacing: 1)),
            Text(v, style: const TextStyle(fontSize: 13)),
          ],
        ),
      );
}

class _StreamingBubble extends StatelessWidget {
  const _StreamingBubble({required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final m = controller.mission;
    final role = m.streamingAgent!;
    final id = controller.router.providerIdFor(role);
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: HqColors.panel.withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: role.color.withValues(alpha: 0.6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Text('${role.title.toUpperCase()} MENYUSUN JAWABAN', style: TextStyle(fontSize: 11, color: role.color, fontWeight: FontWeight.w700)),
              const SizedBox(width: 8),
              SourceBadge(providerId: id, providerName: controller.providerName(id)),
            ],
          ),
          const SizedBox(height: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 90),
            child: SingleChildScrollView(reverse: true, child: Text(m.streaming.isEmpty ? '…' : m.streaming, style: const TextStyle(fontSize: 13))),
          ),
        ],
      ),
    );
  }
}

class _ActionBar extends StatelessWidget {
  const _ActionBar({
    required this.controller,
    required this.onAnalyze,
    required this.onOpenDatasets,
    required this.onOpenAnalytics,
    required this.onStartMission,
    required this.onToast,
  });
  final AppController controller;
  final VoidCallback onAnalyze;
  final VoidCallback onOpenDatasets;
  final VoidCallback onOpenAnalytics;
  final VoidCallback onStartMission;
  final void Function(String message, {bool error}) onToast;

  @override
  Widget build(BuildContext context) {
    final m = controller.mission;
    final hasData = controller.analysis?.ok == true;
    final busyWithData = controller.analyzing || controller.importing;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      color: HqColors.panel,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            FilledButton.icon(
              onPressed: busyWithData ? null : onAnalyze,
              icon: busyWithData
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.upload_file),
              label: const Text('Analisis File'),
            ),
            const SizedBox(width: 6),
            OutlinedButton.icon(
              onPressed: onOpenDatasets,
              icon: const Icon(Icons.table_chart),
              label: Text(controller.datasetList.isEmpty ? 'Dataset' : 'Dataset (${controller.datasetList.length})'),
            ),
            const SizedBox(width: 6),
            if (hasData)
              OutlinedButton.icon(onPressed: onOpenAnalytics, icon: const Icon(Icons.insights), label: const Text('Hasil')),
            if (hasData) const SizedBox(width: 6),
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: const Color(0xFF225F50), foregroundColor: Colors.white),
              onPressed: hasData && !m.busy && !m.paused ? onStartMission : null,
              icon: const Icon(Icons.play_arrow),
              label: const Text('Mulai Misi'),
            ),
            const SizedBox(width: 6),
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: const Color(0xFF26588D), foregroundColor: Colors.white),
              onPressed: !m.busy && !m.paused ? controller.startDemoMeeting : null,
              icon: const Icon(Icons.groups),
              label: const Text('Meeting Demo'),
            ),
            const SizedBox(width: 6),
            OutlinedButton(
              onPressed: () => m.setPaused(!m.paused),
              child: Text(m.paused ? 'Lanjutkan' : 'Jeda'),
            ),
            const SizedBox(width: 6),
            OutlinedButton(onPressed: () => m.setSpeed(m.speed == 1 ? 2 : 1), child: Text('x${m.speed}')),
            const SizedBox(width: 6),
            if (m.busy)
              OutlinedButton(
                style: OutlinedButton.styleFrom(foregroundColor: HqColors.danger),
                onPressed: m.cancelMission,
                child: const Text('Batalkan'),
              ),
            if (m.busy) const SizedBox(width: 6),
            OutlinedButton.icon(
              onPressed: m.hasTranscript || controller.history.isNotEmpty
                  ? () => showMinutesDialog(context, controller)
                  : null,
              icon: const Icon(Icons.description_outlined),
              label: const Text('Notulen'),
            ),
            const SizedBox(width: 6),
            OutlinedButton.icon(
              onPressed: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => ModelManagerScreen(controller: controller))),
              icon: const Icon(Icons.memory),
              label: const Text('Model'),
            ),
            const SizedBox(width: 6),
            OutlinedButton.icon(
              onPressed: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => AiSettingsScreen(controller: controller))),
              icon: const Icon(Icons.tune),
              label: const Text('Pengaturan AI'),
            ),
            const SizedBox(width: 6),
            IconButton(tooltip: 'Reset kamera', onPressed: m.resetCamera, icon: const Icon(Icons.center_focus_strong)),
          ],
        ),
      ),
    );
  }
}
