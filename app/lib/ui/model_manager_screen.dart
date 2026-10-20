import 'dart:async';

import 'package:flutter/material.dart';

import '../ai/ai_provider.dart';
import '../ai/ai_settings.dart';
import '../ai/local/local_engine.dart';
import '../ai/model_manager.dart';
import '../app_controller.dart';
import 'theme.dart';

/// Manajer model GGUF (PRD §6.3): unduh/impor, aktifkan, muat, benchmark.
class ModelManagerScreen extends StatefulWidget {
  const ModelManagerScreen({super.key, required this.controller});
  final AppController controller;

  @override
  State<ModelManagerScreen> createState() => _ModelManagerScreenState();
}

class _ModelManagerScreenState extends State<ModelManagerScreen> {
  AppController get c => widget.controller;
  final _progress = <String, DownloadProgress>{};
  final _cancels = <String, CancelToken>{};
  String? _benchmark;
  bool _benchmarking = false;
  bool _loading = false;

  void _toast(String m, {bool error = false}) => ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(m), backgroundColor: error ? HqColors.danger.withValues(alpha: 0.9) : null),
      );

  Future<void> _download(ModelCatalogEntry entry) async {
    final cancel = _cancels[entry.id] = CancelToken();
    try {
      await for (final p in c.models.download(entry.id, cancel: cancel)) {
        if (!mounted) return;
        setState(() => _progress[entry.id] = p);
      }
      if (c.models.activeModelPath == null) await c.models.setActiveModel(c.models.pathForCatalog(entry.id));
      _toast('${entry.name} terpasang.');
    } catch (e) {
      if (mounted) _toast('Unduhan gagal: $e', error: true);
    } finally {
      _cancels.remove(entry.id);
      if (mounted) setState(() => _progress.remove(entry.id));
    }
  }

  Future<void> _import() async {
    try {
      final path = await c.models.importGguf();
      if (c.models.activeModelPath == null) await c.models.setActiveModel(path);
      _toast('Model diimpor.');
    } catch (e) {
      _toast('Impor gagal: $e', error: true);
    }
  }

  Future<void> _load() async {
    final warning = c.memoryWarningForActiveModel();
    if (warning != null) {
      final proceed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('RAM tidak cukup'),
          content: Text(warning),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Batal')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Tetap muat')),
          ],
        ),
      );
      if (proceed != true || !mounted) return;
    }
    setState(() => _loading = true);
    final error = await c.loadActiveModel();
    if (!mounted) return;
    setState(() => _loading = false);
    if (error != null) _toast(error, error: true);
  }

  Future<void> _runBenchmark() async {
    setState(() {
      _benchmarking = true;
      _benchmark = null;
    });
    try {
      final stats = await c.runBenchmark(onText: (t) {
        if (mounted) setState(() => _benchmark = t);
      });
      final text = (stats.remove('text') as String?) ?? '';
      final elapsed = stats.remove('elapsed_ms');
      _benchmark = '${stripThinking(text)}\n\n— $elapsed ms total · ${_fmtStats(stats)}';
    } catch (e) {
      _benchmark = 'Benchmark gagal: $e';
    } finally {
      if (mounted) setState(() => _benchmarking = false);
    }
  }

  AutoTuneResult? _autoTune;
  final _autoTuneAttempts = <AutoTuneAttempt>[];

  Future<void> _runAutoTune() async {
    final warning = c.memoryWarningForActiveModel();
    if (warning != null) {
      final proceed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('RAM tidak cukup'),
          content: Text('$warning\n\nUji otomatis memuat model tiga kali.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Batal')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Tetap uji')),
          ],
        ),
      );
      if (proceed != true || !mounted) return;
    }
    setState(() {
      _autoTune = null;
      _autoTuneAttempts.clear();
    });
    try {
      final result = await c.autoTune(onAttempt: (a) {
        if (mounted) setState(() => _autoTuneAttempts.add(a));
      });
      if (!mounted) return;
      setState(() => _autoTune = result);
      final best = result.best;
      if (result.cancelled) {
        _toast('Uji otomatis dibatalkan.');
      } else if (best == null) {
        _toast('Semua percobaan gagal; setelan tidak diubah.', error: true);
      } else {
        _toast('Tercepat: ${best.preset.label} (${best.tokensPerSecond.toStringAsFixed(1)} tok/s), disimpan ke Pengaturan AI.');
      }
    } catch (e) {
      if (mounted) _toast('Uji otomatis gagal: $e', error: true);
    }
  }

  bool _selfTesting = false;
  GpuSelfTestReport? _selfTest;

  /// Uji kernel GPU: op demi op dibandingkan CPU vs GPU (backend di setelan,
  /// atau GPU pertama yang terdeteksi). Tidak memerlukan model dimuat.
  Future<void> _runSelfTest() async {
    var backend = c.settings.gpuBackend;
    if (!backend.isGpu) {
      final report = await c.engine.gpuInfo().catchError((_) => LocalGpuReport.none);
      final first = report.firstAvailable;
      if (first == null) {
        _toast('Tidak ada GPU yang terdeteksi (Vulkan/OpenCL).', error: true);
        return;
      }
      backend = first;
    }
    setState(() {
      _selfTesting = true;
      _selfTest = null;
    });
    try {
      final report = await c.engine.gpuSelfTest(backend);
      if (!mounted) return;
      setState(() => _selfTest = report);
      if (!report.available) {
        _toast(report.reason, error: true);
      } else if (report.allOk) {
        _toast('Semua kernel ${backend.label} memberi hasil yang sama dengan CPU.');
      } else {
        _toast('${report.wrongCount + report.failedCount} kernel ${backend.label} bermasalah; lihat tabel.', error: true);
      }
    } catch (e) {
      if (mounted) _toast('Uji kernel gagal: $e', error: true);
    } finally {
      if (mounted) setState(() => _selfTesting = false);
    }
  }

  Widget _selfTestTable() {
    final r = _selfTest;
    if (r == null) return const SizedBox.shrink();
    final sg = r.runtimeSubgroups;
    Color colorOf(GpuKernelCheck k) => switch (k.status) {
          'OK' => HqColors.local,
          'CPU' => HqColors.muted,
          _ => HqColors.danger,
        };
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: HqColors.background, borderRadius: BorderRadius.circular(8)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Uji kernel ${r.backend == 'opencl' ? 'OpenCL' : 'Vulkan'}${r.device.isEmpty ? '' : ' · ${r.device}'}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
          Text(r.summary, style: TextStyle(fontSize: 11.5, color: r.allOk ? HqColors.local : HqColors.muted)),
          if (sg.isNotEmpty)
            Text(
              'Subgroup nyata per ukuran work-group: ${sg.entries.map((e) => '${e.key}→${e.value ?? '?'}').join(', ')} · max work-group ${r.subgroup['max_wg'] ?? '?'}',
              style: const TextStyle(fontSize: 10.5, color: HqColors.muted),
            ),
          const SizedBox(height: 4),
          for (final k in r.checks)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(k.status == 'OK' ? Icons.check : (k.status == 'CPU' ? Icons.remove : Icons.close), size: 14, color: colorOf(k)),
                  const SizedBox(width: 6),
                  Expanded(flex: 5, child: Text(k.op, style: const TextStyle(fontSize: 11.5))),
                  Expanded(flex: 2, child: Text(k.status, style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: colorOf(k)))),
                  Expanded(flex: 3, child: Text(k.supported && k.error.isEmpty ? k.nmseLabel : k.error, style: const TextStyle(fontSize: 10.5, color: HqColors.muted), maxLines: 2, overflow: TextOverflow.ellipsis)),
                  Text(
                    k.supported && k.error.isEmpty ? '${k.gpuMs.toStringAsFixed(1)} / ${k.cpuMs.toStringAsFixed(1)} ms' : '',
                    style: const TextStyle(fontSize: 10.5, color: HqColors.muted, fontFamily: 'monospace'),
                  ),
                ],
              ),
            ),
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: Text('Waktu = GPU / CPU per op. "SALAH" = hasil GPU berbeda dari CPU (kernel perlu ditambal); "CPU" = op tidak didukung GPU dan otomatis dijalankan CPU.', style: TextStyle(fontSize: 10.5, color: HqColors.muted)),
          ),
        ],
      ),
    );
  }

  /// "CPU 4 thread", "OpenCL 37 layer" atau "OpenCL 18/36 layer + CPU 4 thread"
  /// dari model yang dimuat; bila belum dimuat, dari setelan yang akan dipakai.
  String _backendLabel() {
    final m = c.engine.loadedModel;
    if (m != null) return m.backendLabel;
    final s = c.settings;
    if (!s.useGpu || s.gpuLayers <= 0) return 'CPU ${s.threads} thread';
    final layers = s.gpuLayers >= AiSettings.allGpuLayers ? 'semua' : '${s.gpuLayers}';
    return '${s.gpuBackend.label} $layers layer + CPU ${s.threads} thread (saat dimuat)';
  }

  Widget _autoTuneTable() {
    final rows = [..._autoTuneAttempts];
    if (rows.isEmpty) return const SizedBox.shrink();
    final best = _autoTune?.best;
    String tps(AutoTuneAttempt a) => a.succeeded ? '${a.tokensPerSecond.toStringAsFixed(1)} tok/s' : 'gagal';
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: HqColors.background, borderRadius: BorderRadius.circular(8)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Uji otomatis (${_autoTune?.backend.label ?? c.settings.gpuBackend.label})', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          for (final a in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Icon(identical(a, best) ? Icons.star : (a.succeeded ? Icons.check : Icons.close), size: 14, color: identical(a, best) ? HqColors.local : HqColors.muted),
                  const SizedBox(width: 6),
                  Expanded(flex: 3, child: Text('${a.preset.label}${a.gpuLayers > 0 ? ' · ${a.gpuLayers} layer' : ''}', style: const TextStyle(fontSize: 12))),
                  Expanded(flex: 2, child: Text(tps(a), style: const TextStyle(fontSize: 12))),
                  Text('${(a.elapsed.inMilliseconds / 1000).toStringAsFixed(1)} s', style: const TextStyle(fontSize: 12, color: HqColors.muted)),
                ],
              ),
            ),
          if (rows.any((a) => !a.succeeded))
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(rows.where((a) => !a.succeeded).map((a) => '${a.preset.label}: ${a.error}').join('\n'), style: const TextStyle(fontSize: 10.5, color: HqColors.muted)),
            ),
        ],
      ),
    );
  }

  String _fmtStats(Map<String, Object?> s) {
    if (s.isEmpty) return 'statistik belum tersedia';
    return s.entries.map((e) => '${e.key}: ${e.value is double ? (e.value as double).toStringAsFixed(1) : e.value}').join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: c,
      builder: (context, _) {
        final m = c.models;
        final state = c.engine.state;
        return Scaffold(
          appBar: AppBar(title: const Text('Model lokal'), backgroundColor: HqColors.panel),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.memory, color: state == LocalEngineState.ready ? HqColors.local : HqColors.muted),
                          const SizedBox(width: 8),
                          Text('Runtime: ${state.name.toUpperCase()}', style: const TextStyle(fontWeight: FontWeight.w700)),
                          const Spacer(),
                          if (state == LocalEngineState.ready || state == LocalEngineState.generating)
                            OutlinedButton(onPressed: c.unloadModel, child: const Text('Unload'))
                          else
                            FilledButton(
                              onPressed: _loading || m.activeModelPath == null ? null : _load,
                              child: Text(_loading || state == LocalEngineState.loading ? 'Memuat…' : 'Muat model aktif'),
                            ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text('Aktif: ${m.activeModel?.name ?? '—'}', style: const TextStyle(fontSize: 12, color: HqColors.muted)),
                      Text('Context ${c.settings.contextLength} · arm64 (llama.cpp tertanam)', style: const TextStyle(fontSize: 12, color: HqColors.muted)),
                      Text('Backend: ${_backendLabel()}', style: const TextStyle(fontSize: 12, color: HqColors.muted)),
                      if (c.engine.lastStats.isNotEmpty) Text(_fmtStats(c.engine.lastStats), style: const TextStyle(fontSize: 11, color: HqColors.muted)),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          OutlinedButton.icon(
                            onPressed: state == LocalEngineState.ready && !_benchmarking ? _runBenchmark : null,
                            icon: const Icon(Icons.speed),
                            label: Text(_benchmarking ? 'Mengukur…' : 'Benchmark singkat'),
                          ),
                          const SizedBox(width: 10),
                          const Expanded(child: Text('Catat hasilnya di docs/BENCHMARK.md (Fase 0).', style: TextStyle(fontSize: 11, color: HqColors.muted))),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          if (c.autoTuning)
                            OutlinedButton.icon(onPressed: c.cancelAutoTune, icon: const Icon(Icons.stop), label: const Text('Batalkan uji'))
                          else
                            OutlinedButton.icon(
                              onPressed: m.activeModelPath == null || _benchmarking || _loading || state == LocalEngineState.loading ? null : _runAutoTune,
                              icon: const Icon(Icons.auto_fix_high),
                              label: const Text('Uji otomatis'),
                            ),
                          const SizedBox(width: 10),
                          const Expanded(child: Text('Memuat model 3× (CPU / seimbang / GPU penuh), memilih yang tercepat dan menyimpannya.', style: TextStyle(fontSize: 11, color: HqColors.muted))),
                        ],
                      ),
                      _autoTuneTable(),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          OutlinedButton.icon(
                            onPressed: _selfTesting || state == LocalEngineState.loading || state == LocalEngineState.generating ? null : _runSelfTest,
                            icon: const Icon(Icons.fact_check_outlined),
                            label: Text(_selfTesting ? 'Menguji…' : 'Uji kernel GPU'),
                          ),
                          const SizedBox(width: 10),
                          const Expanded(child: Text('Membandingkan hasil tiap op (mul_mat, rms_norm, softmax, …) di GPU vs CPU untuk menemukan kernel yang salah hitung.', style: TextStyle(fontSize: 11, color: HqColors.muted))),
                        ],
                      ),
                      _selfTestTable(),
                      if (_benchmarking || c.autoTuning || state == LocalEngineState.generating)
                        ValueListenableBuilder<GenerationProgress?>(
                          valueListenable: c.engine.progress,
                          builder: (context, p, _) => Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  p == null ? 'Menyiapkan…' : p.label,
                                  style: const TextStyle(fontSize: 12, color: HqColors.text, fontFamily: 'monospace'),
                                ),
                                const SizedBox(height: 4),
                                const LinearProgressIndicator(minHeight: 3),
                              ],
                            ),
                          ),
                        ),
                      if (_benchmark != null) ...[
                        const SizedBox(height: 8),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(color: HqColors.background, borderRadius: BorderRadius.circular(8)),
                          child: Text(_benchmark!, style: const TextStyle(fontSize: 12)),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 18),
              const _Section('KATALOG (UNDUH, BUTUH INTERNET SEKALI)'),
              for (final entry in m.catalog) _CatalogTile(entry: entry, manager: m, progress: _progress[entry.id], onDownload: () => _download(entry), onCancel: () => _cancels[entry.id]?.cancel()),
              const SizedBox(height: 10),
              OutlinedButton.icon(onPressed: _import, icon: const Icon(Icons.file_open), label: const Text('Impor file .gguf dari penyimpanan (offline)')),
              const SizedBox(height: 18),
              const _Section('TERPASANG'),
              if (m.installed.isEmpty) const Text('Belum ada model. Unduh atau impor dulu.', style: TextStyle(color: HqColors.muted, fontSize: 12)),
              for (final model in m.installed)
                Card(
                  child: ListTile(
                    leading: Icon(model.path == m.activeModelPath ? Icons.check_circle : Icons.circle_outlined, color: model.path == m.activeModelPath ? HqColors.local : HqColors.muted),
                    title: Text(model.name),
                    subtitle: Text('${(model.sizeBytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB', style: const TextStyle(fontSize: 11.5)),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (model.path != m.activeModelPath) TextButton(onPressed: () => m.setActiveModel(model.path), child: const Text('Aktifkan')),
                        IconButton(
                          icon: const Icon(Icons.delete_outline, color: HqColors.danger),
                          onPressed: () async {
                            if (model.path == m.activeModelPath) await c.unloadModel();
                            await m.delete(model.path);
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              const Text(
                'Model tidak dibundel di APK dan tidak pernah dikirim ke mana pun. Setelah terpasang, seluruh fitur AI lokal berjalan dalam mode pesawat.',
                style: TextStyle(fontSize: 11, color: HqColors.muted),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _CatalogTile extends StatelessWidget {
  const _CatalogTile({required this.entry, required this.manager, required this.progress, required this.onDownload, required this.onCancel});
  final ModelCatalogEntry entry;
  final ModelManager manager;
  final DownloadProgress? progress;
  final VoidCallback onDownload;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final installed = manager.isInstalled(entry.id);
    final p = progress;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(entry.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                      Text('${(entry.sizeBytes / 1e9).toStringAsFixed(1)} GB · ${entry.note}', style: const TextStyle(fontSize: 11.5, color: HqColors.muted)),
                    ],
                  ),
                ),
                if (installed)
                  const Chip(label: Text('Terpasang', style: TextStyle(fontSize: 11)), visualDensity: VisualDensity.compact)
                else if (p != null)
                  TextButton(onPressed: onCancel, child: const Text('Batal'))
                else
                  FilledButton.icon(onPressed: onDownload, icon: const Icon(Icons.download), label: const Text('Unduh')),
              ],
            ),
            if (p != null) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(value: p.fraction),
              const SizedBox(height: 4),
              Text(
                '${p.status.name} · ${(p.received / 1e6).toStringAsFixed(0)} MB${p.total == null ? '' : ' / ${(p.total! / 1e6).toStringAsFixed(0)} MB'}',
                style: const TextStyle(fontSize: 11, color: HqColors.muted),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text, style: const TextStyle(fontSize: 10.5, color: HqColors.muted, letterSpacing: 1.2, fontWeight: FontWeight.w700)),
      );
}
