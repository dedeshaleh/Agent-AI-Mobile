import 'dart:async';

import 'package:flutter/material.dart';

import '../agents/agent_chat.dart';
import '../agents/agent_role.dart';
import '../agents/mission_orchestrator.dart';
import '../ai/local/local_engine.dart';
import '../app_controller.dart';
import '../perf/perf_monitor.dart';
import 'agent_settings_screen.dart';
import 'ai_settings_screen.dart';
import 'analytics_sheet.dart';
import 'datasets_screen.dart';
import 'game_view.dart';
import 'minutes_dialog.dart';
import 'model_manager_screen.dart';
import 'theme.dart';

enum _PanelMode { team, chat }

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.controller});
  final AppController controller;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  AppController get c => widget.controller;

  _PanelMode _mode = _PanelMode.team;
  bool _collapsed = false;
  int _seenChat = 0;
  ChatTarget _target = const ChatTarget.team();
  final _input = TextEditingController();
  final _chatScroll = ScrollController();
  Timer? _tick;
  bool _wired = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    c.consentPrompt = _consent;
    // Timer berjalan untuk durasi "menyusun jawaban…" dan overlay performa.
    _tick = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted && (c.ready && c.mission.streamingAgent != null)) setState(() {});
    });
  }

  void _wire() {
    if (_wired || !c.ready) return;
    _wired = true;
    c.mission.onAgentTapped = (role) => _openChat(target: ChatTarget.agent(role));
  }

  @override
  void dispose() {
    _tick?.cancel();
    _input.dispose();
    _chatScroll.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Android dapat menghentikan proses di background; jeda simulasi agar
    // state misi konsisten saat kembali (PRD §9).
    if (state == AppLifecycleState.paused && c.ready && c.mission.missionRunning && !c.mission.paused) {
      c.mission.setPaused(true);
    }
  }

  // ---------------------------------------------------------------- dialogs

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
    final analyzed = await Navigator.push<bool>(context, MaterialPageRoute<bool>(builder: (_) => DatasetsScreen(controller: c)));
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

  // ---------------------------------------------------------------- panel

  void _openChat({ChatTarget? target}) {
    setState(() {
      _collapsed = false;
      _mode = _PanelMode.chat;
      if (target != null) _target = target;
      _seenChat = c.mission.chat.length;
    });
    _scrollChatToEnd();
  }

  void _scrollChatToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_chatScroll.hasClients) _chatScroll.jumpTo(_chatScroll.position.maxScrollExtent);
    });
  }

  Future<void> _send([String? preset]) async {
    final text = (preset ?? _input.text).trim();
    if (text.isEmpty) return;
    if (c.mission.busy) {
      _toast('Agent sedang sibuk. Tunggu sampai selesai atau batalkan misi.');
      return;
    }
    _input.clear();
    _scrollChatToEnd();
    await c.mission.command(_target, text);
    _scrollChatToEnd();
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
        _wire();
        final m = c.mission;
        if (_mode == _PanelMode.chat && !_collapsed) {
          _seenChat = m.chat.length;
          _scrollChatToEnd();
        }
        final unread = (m.chat.length - _seenChat).clamp(0, 99);
        return Scaffold(
          body: SafeArea(
            child: Column(
              children: [
                _Header(controller: c),
                Expanded(
                  child: Row(
                    children: [
                      Expanded(
                        child: Stack(
                          children: [
                            Positioned.fill(child: GameView(bridge: c.game)),
                            Positioned(
                              left: 10,
                              top: 10,
                              child: _PerfOverlay(controller: c),
                            ),
                            if (m.streamingAgent != null)
                              Positioned(
                                left: 10,
                                bottom: 10,
                                child: _StreamingChip(controller: c, onTap: () => _openChat()),
                              ),
                            if (_collapsed)
                              Positioned(
                                right: 0,
                                top: 0,
                                bottom: 0,
                                child: Center(
                                  child: _EdgeTab(
                                    unread: unread,
                                    onTap: () => setState(() => _collapsed = false),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      if (!_collapsed)
                        SizedBox(
                          width: 340,
                          child: Container(
                            color: HqColors.panel,
                            padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _PanelHeader(
                                  mode: _mode,
                                  unread: unread,
                                  onTeam: () => setState(() => _mode = _PanelMode.team),
                                  onChat: () => _openChat(),
                                  onCollapse: () => setState(() => _collapsed = true),
                                ),
                                const SizedBox(height: 6),
                                Expanded(
                                  child: _mode == _PanelMode.team
                                      ? _TeamView(controller: c, onConfigure: (role) => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => AgentSettingsScreen(controller: c, initial: role))))
                                      : _ChatView(
                                          controller: c,
                                          scroll: _chatScroll,
                                          input: _input,
                                          target: _target,
                                          onTarget: (t) => setState(() => _target = t),
                                          onSend: _send,
                                        ),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                _ActionBar(
                  controller: c,
                  onAnalyze: _analyze,
                  onOpenDatasets: _openDatasets,
                  onOpenAnalytics: _openAnalytics,
                  onStartMission: _startMission,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ======================================================================= header

class _Header extends StatelessWidget {
  const _Header({required this.controller});
  final AppController controller;

  static const _steps = [
    (MissionPhase.dataPrep, 'Data'),
    (MissionPhase.analysis, 'KPI'),
    (MissionPhase.strategy, 'Strategi'),
    (MissionPhase.meeting, 'Meeting'),
    (MissionPhase.report, 'Laporan'),
  ];

  @override
  Widget build(BuildContext context) {
    final m = controller.mission;
    final engineState = controller.engine.state;
    final status = m.paused
        ? 'DIJEDA'
        : m.commanding
            ? 'AGENT MENJAWAB'
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
    final showSteps = m.missionRunning || m.phase == MissionPhase.done;
    final activeIndex = _steps.indexWhere((s) => s.$1 == m.phase);
    return Container(
      height: 46,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      color: HqColors.panel,
      child: Row(
        children: [
          const Text('AGENT / HQ', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, letterSpacing: 1.5)),
          const SizedBox(width: 10),
          if (!showSteps)
            const Text('KANTOR AI · FLUTTER + UNITY', style: TextStyle(fontSize: 10, color: HqColors.muted, letterSpacing: 1))
          else
            Row(
              children: [
                for (final (i, step) in _steps.indexed) ...[
                  _Step(
                    label: step.$2,
                    done: m.phase == MissionPhase.done || i < activeIndex,
                    active: i == activeIndex,
                  ),
                  if (i < _steps.length - 1) Container(width: 14, height: 2, color: (m.phase == MissionPhase.done || i < activeIndex) ? HqColors.accent : HqColors.border),
                ],
              ],
            ),
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

class _Step extends StatelessWidget {
  const _Step({required this.label, required this.done, required this.active});
  final String label;
  final bool done;
  final bool active;
  @override
  Widget build(BuildContext context) {
    final color = done || active ? HqColors.accent : HqColors.muted;
    return Row(
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: done ? HqColors.accent : Colors.transparent,
            border: Border.all(color: color, width: active ? 2.5 : 1.5),
          ),
        ),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(fontSize: 10, color: color, fontWeight: active ? FontWeight.w700 : FontWeight.w500)),
      ],
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

// ======================================================================= overlays

class _PerfOverlay extends StatelessWidget {
  const _PerfOverlay({required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final show = controller.showPerf;
    return AnimatedBuilder(
      animation: controller.perf,
      builder: (context, _) {
        final p = controller.perf;
        if (!show) {
          return _OverlayButton(
            tooltip: 'Tampilkan info performa',
            icon: Icons.visibility_off_outlined,
            onTap: () => controller.setShowPerf(true),
          );
        }
        const mono = TextStyle(fontSize: 11, fontFamily: 'monospace', color: HqColors.text);
        Widget item(String label, String value, {Color color = HqColors.text}) => Text.rich(
              TextSpan(children: [
                TextSpan(text: '$label ', style: mono.copyWith(color: HqColors.muted)),
                TextSpan(text: value, style: mono.copyWith(color: color, fontWeight: FontWeight.w700)),
              ]),
            );
        final sep = Container(width: 1, height: 14, color: HqColors.border, margin: const EdgeInsets.symmetric(horizontal: 8));
        return Container(
          padding: const EdgeInsets.fromLTRB(10, 5, 5, 5),
          decoration: BoxDecoration(
            color: HqColors.panel.withValues(alpha: 0.92),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: HqColors.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              item('FPS', p.hasUnity ? '${p.flutterFps.toStringAsFixed(0)}/${p.unityFps.toStringAsFixed(0)}' : p.flutterFps.toStringAsFixed(0),
                  color: (p.hasUnity ? p.unityFps : p.flutterFps) >= 27 ? HqColors.local : HqColors.warning),
              sep,
              item('CPU', '${p.cpuPercent.toStringAsFixed(0)}%'),
              sep,
              item('RAM', p.availableBytes > 0 ? '${p.rssLabel} · sisa ${p.availableLabel}' : p.rssLabel,
                  color: p.memoryPressure ? HqColors.danger : HqColors.text),
              sep,
              item('GPU', p.gpuName.isEmpty ? '—' : '${p.gpuName.replaceAll(RegExp(r'^(ARM|Qualcomm|Adreno \(TM\)) '), '')} · ${p.unityFrameMs.toStringAsFixed(0)} ms', color: HqColors.muted),
              if (p.thermal != ThermalLevel.unknown) ...[
                sep,
                item('SUHU', p.thermal.label, color: p.thermal.isHot ? HqColors.danger : (p.thermal == ThermalLevel.light ? HqColors.warning : HqColors.local)),
              ],
              if (p.tokensPerSecond > 0) ...[
                sep,
                item('', '${p.tokensPerSecond.toStringAsFixed(0)} tok/s', color: HqColors.warning),
              ],
              const SizedBox(width: 6),
              _OverlayButton(tooltip: 'Sembunyikan info performa', icon: Icons.visibility_outlined, onTap: () => controller.setShowPerf(false), flat: true),
            ],
          ),
        );
      },
    );
  }
}

class _OverlayButton extends StatelessWidget {
  const _OverlayButton({required this.tooltip, required this.icon, required this.onTap, this.flat = false});
  final String tooltip;
  final IconData icon;
  final VoidCallback onTap;
  final bool flat;
  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            width: 30,
            height: 26,
            decoration: BoxDecoration(
              color: flat ? HqColors.panelAlt : HqColors.panel.withValues(alpha: 0.92),
              borderRadius: BorderRadius.circular(8),
              border: flat ? null : Border.all(color: HqColors.border),
            ),
            child: Icon(icon, size: 15, color: HqColors.muted),
          ),
        ),
      );
}

class _StreamingChip extends StatelessWidget {
  const _StreamingChip({required this.controller, required this.onTap});
  final AppController controller;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final m = controller.mission;
    final role = m.streamingAgent!;
    final started = m.streamingStartedAt;
    final secs = started == null ? 0.0 : DateTime.now().difference(started).inMilliseconds / 1000;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: HqColors.panel.withValues(alpha: 0.94),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: role.color.withValues(alpha: 0.6)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2, color: role.color)),
            const SizedBox(width: 8),
            Text('${controller.profiles.of(role).displayName} menyusun jawaban…', style: TextStyle(fontSize: 11, color: role.color, fontWeight: FontWeight.w700)),
            const SizedBox(width: 8),
            Text('⏱ ${secs.toStringAsFixed(1).replaceAll('.', ',')} s', style: const TextStyle(fontSize: 11, color: HqColors.muted, fontFamily: 'monospace')),
            const SizedBox(width: 4),
            const Icon(Icons.chat_bubble_outline, size: 13, color: HqColors.muted),
          ],
        ),
      ),
    );
  }
}

class _EdgeTab extends StatelessWidget {
  const _EdgeTab({required this.unread, required this.onTap});
  final int unread;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Tooltip(
        message: 'Tampilkan panel tim & chat',
        child: InkWell(
          onTap: onTap,
          child: Container(
            height: 56,
            padding: const EdgeInsets.fromLTRB(10, 0, 12, 0),
            decoration: BoxDecoration(
              color: HqColors.panel.withValues(alpha: 0.96),
              borderRadius: const BorderRadius.horizontal(left: Radius.circular(12)),
              border: Border.all(color: HqColors.border),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.chevron_left, size: 18),
                const SizedBox(width: 4),
                const Icon(Icons.chat_bubble_outline, size: 16, color: HqColors.local),
                if (unread > 0) ...[const SizedBox(width: 6), _Badge(unread)],
              ],
            ),
          ),
        ),
      );
}

class _Badge extends StatelessWidget {
  const _Badge(this.count);
  final int count;
  @override
  Widget build(BuildContext context) => Container(
        constraints: const BoxConstraints(minWidth: 16),
        height: 16,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        decoration: BoxDecoration(color: HqColors.warning, borderRadius: BorderRadius.circular(999)),
        alignment: Alignment.center,
        child: Text('$count', style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w800, color: HqColors.background)),
      );
}

// ======================================================================= side panel

class _PanelHeader extends StatelessWidget {
  const _PanelHeader({required this.mode, required this.unread, required this.onTeam, required this.onChat, required this.onCollapse});
  final _PanelMode mode;
  final int unread;
  final VoidCallback onTeam;
  final VoidCallback onChat;
  final VoidCallback onCollapse;

  @override
  Widget build(BuildContext context) {
    Widget button(IconData icon, String tooltip, bool active, VoidCallback onTap, {int badge = 0}) => Tooltip(
          message: tooltip,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(8),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  width: 36,
                  height: 32,
                  decoration: BoxDecoration(
                    color: active ? HqColors.accent.withValues(alpha: 0.18) : HqColors.panelAlt,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: HqColors.border),
                  ),
                  child: Icon(icon, size: 16, color: active ? HqColors.accent : HqColors.text),
                ),
                if (badge > 0) Positioned(top: -6, right: -6, child: _Badge(badge)),
              ],
            ),
          ),
        );
    return Row(
      children: [
        Expanded(
          child: Text(mode == _PanelMode.team ? 'TIM KAMU' : 'PERCAKAPAN', style: const TextStyle(fontSize: 11, color: HqColors.muted, letterSpacing: 1)),
        ),
        button(Icons.groups_outlined, 'Mode tim', mode == _PanelMode.team, onTeam),
        const SizedBox(width: 6),
        button(Icons.chat_bubble_outline, 'Mode chat', mode == _PanelMode.chat, onChat, badge: mode == _PanelMode.chat ? 0 : unread),
        const SizedBox(width: 6),
        button(Icons.chevron_right, 'Sembunyikan panel', false, onCollapse),
      ],
    );
  }
}

class _TeamView extends StatelessWidget {
  const _TeamView({required this.controller, required this.onConfigure});
  final AppController controller;
  final void Function(AgentRole role) onConfigure;

  @override
  Widget build(BuildContext context) {
    final m = controller.mission;
    final selected = m.agents[m.selected]!;
    final profile = controller.profiles.of(m.selected);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final role in AgentRole.values)
          Padding(
            padding: const EdgeInsets.only(bottom: 3),
            child: InkWell(
              onTap: () => m.select(role),
              borderRadius: BorderRadius.circular(8),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: role == m.selected ? role.color.withValues(alpha: 0.16) : HqColors.panelAlt,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Container(width: 9, height: 9, decoration: BoxDecoration(color: role.color, shape: BoxShape.circle)),
                    const SizedBox(width: 8),
                    Text(controller.profiles.of(role).displayName, style: TextStyle(color: role.color, fontWeight: FontWeight.w600)),
                    const Spacer(),
                    Text(m.agents[role]!.state.wire, style: const TextStyle(fontSize: 11, color: HqColors.muted)),
                  ],
                ),
              ),
            ),
          ),
        const SizedBox(height: 6),
        Expanded(
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: HqColors.panelAlt, borderRadius: BorderRadius.circular(10)),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(child: Text(profile.displayName, style: TextStyle(fontSize: 20, color: m.selected.color, fontWeight: FontWeight.w700))),
                      IconButton(
                        tooltip: 'Atur perilaku ${profile.displayName}',
                        onPressed: () => onConfigure(m.selected),
                        icon: const Icon(Icons.tune, size: 18, color: HqColors.muted),
                        visualDensity: VisualDensity.compact,
                      ),
                    ],
                  ),
                  Text('${m.selected.title} · ${m.selected.duty}', style: const TextStyle(fontSize: 12, color: HqColors.muted)),
                  Text('${profile.tone.label} · ${profile.verbosity.label}${profile.canDelegate ? ' · boleh delegasi' : ''}', style: const TextStyle(fontSize: 11, color: HqColors.muted)),
                  const SizedBox(height: 8),
                  _kv('STATUS', '${selected.state.wire}\n${selected.activity}'),
                  _kv('LOKASI', selected.roomIndex < 0 ? 'Koridor' : OfficeRoom.fromIndex(selected.roomIndex).label),
                  if (selected.lastTimingLabel != null) _kv('PROSES TERAKHIR', selected.lastTimingLabel!, mono: true),
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
      ],
    );
  }

  Widget _kv(String k, String v, {bool mono = false}) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(k, style: const TextStyle(fontSize: 10, color: HqColors.muted, letterSpacing: 1)),
            Text(v, style: TextStyle(fontSize: 13, fontFamily: mono ? 'monospace' : null)),
          ],
        ),
      );
}

class _ChatView extends StatelessWidget {
  const _ChatView({
    required this.controller,
    required this.scroll,
    required this.input,
    required this.target,
    required this.onTarget,
    required this.onSend,
  });
  final AppController controller;
  final ScrollController scroll;
  final TextEditingController input;
  final ChatTarget target;
  final ValueChanged<ChatTarget> onTarget;
  final Future<void> Function([String? preset]) onSend;

  static const _quick = ['Ringkas data', 'Cek anomali', 'Bandingkan bulan lalu', 'Siapkan laporan'];

  @override
  Widget build(BuildContext context) {
    final m = controller.mission;
    final busy = m.busy;
    return Column(
      children: [
        Expanded(
          child: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(color: HqColors.background, borderRadius: BorderRadius.circular(10)),
            child: ListView.builder(
              controller: scroll,
              itemCount: m.chat.length + (m.streamingAgent != null ? 1 : 0),
              itemBuilder: (context, i) {
                if (i == m.chat.length) return _StreamingRow(controller: controller);
                return _ChatRow(message: m.chat[i], controller: controller);
              },
            ),
          ),
        ),
        const SizedBox(height: 6),
        SizedBox(
          height: 30,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              for (final q in _quick)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ActionChip(
                    label: Text(q, style: const TextStyle(fontSize: 11)),
                    visualDensity: VisualDensity.compact,
                    onPressed: busy ? null : () => onSend(q),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            DropdownButtonHideUnderline(
              child: Container(
                height: 40,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                decoration: BoxDecoration(color: HqColors.panelAlt, borderRadius: BorderRadius.circular(8), border: Border.all(color: HqColors.border)),
                child: DropdownButton<ChatTarget>(
                  value: target,
                  isDense: true,
                  style: const TextStyle(fontSize: 12, color: HqColors.text),
                  items: [
                    const DropdownMenuItem(value: ChatTarget.team(), child: Text('Tim')),
                    for (final r in AgentRole.values)
                      DropdownMenuItem(
                        value: ChatTarget.agent(r),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(width: 8, height: 8, decoration: BoxDecoration(color: r.color, shape: BoxShape.circle)),
                            const SizedBox(width: 6),
                            Text(controller.profiles.of(r).displayName),
                          ],
                        ),
                      ),
                  ],
                  onChanged: (v) => v == null ? null : onTarget(v),
                ),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: TextField(
                controller: input,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => onSend(),
                enabled: !busy,
                decoration: InputDecoration(hintText: busy ? 'Agent sedang bekerja…' : 'Perintah untuk ${target.isTeam ? 'tim' : controller.profiles.of(target.role!).displayName}…'),
              ),
            ),
            const SizedBox(width: 6),
            SizedBox(
              width: 40,
              height: 40,
              child: FilledButton(
                style: FilledButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(40, 40)),
                onPressed: busy ? null : () => onSend(),
                child: const Icon(Icons.send, size: 16),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _ChatRow extends StatelessWidget {
  const _ChatRow({required this.message, required this.controller});
  final ChatMessage message;
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    const stampStyle = TextStyle(fontSize: 9.5, color: HqColors.muted, fontFamily: 'monospace');
    switch (message.author) {
      case ChatAuthor.system:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Text('${message.stamp}  ${message.text}', style: const TextStyle(fontSize: 10.5, color: HqColors.muted)),
        );
      case ChatAuthor.user:
        return Align(
          alignment: Alignment.centerRight,
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 4),
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
            constraints: const BoxConstraints(maxWidth: 250),
            decoration: const BoxDecoration(
              color: Color(0xFF26588D),
              borderRadius: BorderRadius.only(topLeft: Radius.circular(12), topRight: Radius.circular(12), bottomLeft: Radius.circular(12), bottomRight: Radius.circular(2)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Kamu → ${message.target?.isTeam == false ? controller.profiles.of(message.target!.role!).displayName : 'Tim'}', style: const TextStyle(fontSize: 9.5, color: Colors.white70)),
                    const SizedBox(width: 10),
                    Text(message.stamp, style: const TextStyle(fontSize: 9.5, color: Colors.white70, fontFamily: 'monospace')),
                  ],
                ),
                const SizedBox(height: 2),
                Text(message.text, style: const TextStyle(fontSize: 12.5, color: Colors.white)),
              ],
            ),
          ),
        );
      case ChatAuthor.agent:
        final role = message.agent!;
        final name = controller.profiles.of(role).displayName;
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(padding: const EdgeInsets.only(top: 2), child: Text(message.stamp, style: stampStyle)),
                  const SizedBox(width: 6),
                  SizedBox(width: 62, child: Text(name, style: TextStyle(color: role.color, fontWeight: FontWeight.w600, fontSize: 12), overflow: TextOverflow.ellipsis)),
                  Expanded(child: Text(message.text, style: const TextStyle(fontSize: 12.5))),
                ],
              ),
              if (message.source != null || message.timingLabel != null)
                Padding(
                  padding: const EdgeInsets.only(left: 104, top: 3),
                  child: Row(
                    children: [
                      if (message.source != null) SourceBadge(providerId: message.source, providerName: controller.providerName(message.source)),
                      if (message.timingLabel != null) ...[
                        const SizedBox(width: 6),
                        Text(message.timingLabel!, style: stampStyle),
                      ],
                    ],
                  ),
                ),
            ],
          ),
        );
    }
  }
}

class _StreamingRow extends StatelessWidget {
  const _StreamingRow({required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final m = controller.mission;
    final role = m.streamingAgent!;
    final started = m.streamingStartedAt;
    final secs = started == null ? 0.0 : DateTime.now().difference(started).inMilliseconds / 1000;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(width: 44),
          SizedBox(width: 62, child: Text(controller.profiles.of(role).displayName, style: TextStyle(color: role.color, fontWeight: FontWeight.w600, fontSize: 12), overflow: TextOverflow.ellipsis)),
          Expanded(
            child: Text(
              m.streaming.isEmpty ? 'menyusun jawaban… ⏱ ${secs.toStringAsFixed(1).replaceAll('.', ',')} s' : '${m.streaming} ▍',
              style: TextStyle(fontSize: 12.5, color: m.streaming.isEmpty ? HqColors.muted : HqColors.text, fontStyle: m.streaming.isEmpty ? FontStyle.italic : FontStyle.normal),
            ),
          ),
        ],
      ),
    );
  }
}

// ======================================================================= action bar

class _ActionBar extends StatelessWidget {
  const _ActionBar({
    required this.controller,
    required this.onAnalyze,
    required this.onOpenDatasets,
    required this.onOpenAnalytics,
    required this.onStartMission,
  });
  final AppController controller;
  final VoidCallback onAnalyze;
  final VoidCallback onOpenDatasets;
  final VoidCallback onOpenAnalytics;
  final VoidCallback onStartMission;

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
              icon: busyWithData ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.upload_file),
              label: const Text('Analisis File'),
            ),
            const SizedBox(width: 6),
            OutlinedButton.icon(
              onPressed: onOpenDatasets,
              icon: const Icon(Icons.table_chart),
              label: Text(controller.datasetList.isEmpty ? 'Dataset' : 'Dataset (${controller.datasetList.length})'),
            ),
            const SizedBox(width: 6),
            if (hasData) OutlinedButton.icon(onPressed: onOpenAnalytics, icon: const Icon(Icons.insights), label: const Text('Hasil')),
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
            OutlinedButton(onPressed: () => m.setPaused(!m.paused), child: Text(m.paused ? 'Lanjutkan' : 'Jeda')),
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
              onPressed: m.hasTranscript || controller.history.isNotEmpty ? () => showMinutesDialog(context, controller) : null,
              icon: const Icon(Icons.description_outlined),
              label: const Text('Notulen'),
            ),
            const SizedBox(width: 6),
            OutlinedButton.icon(
              onPressed: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => AgentSettingsScreen(controller: controller))),
              icon: const Icon(Icons.smart_toy_outlined),
              label: const Text('Agent'),
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
