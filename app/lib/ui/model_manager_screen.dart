import 'dart:async';

import 'package:flutter/material.dart';

import '../ai/ai_provider.dart';
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
    final buffer = StringBuffer();
    final sw = Stopwatch()..start();
    try {
      final prompt = formatChatMl([
        (role: 'system', content: 'Jawab singkat dalam bahasa Indonesia.'),
        (role: 'user', content: 'Sebutkan tiga manfaat mencatat penjualan harian untuk toko kecil.'),
      ]);
      await for (final piece in c.engine.generate(prompt, const LocalGenerateOptions(maxTokens: 96, temperature: 0.3))) {
        buffer.write(piece);
        if (mounted) setState(() => _benchmark = buffer.toString());
      }
      sw.stop();
      final stats = c.engine.lastStats;
      _benchmark = '${stripThinking(buffer.toString())}\n\n— ${sw.elapsed.inMilliseconds} ms total · ${_fmtStats(stats)}';
    } catch (e) {
      _benchmark = 'Benchmark gagal: $e';
    } finally {
      if (mounted) setState(() => _benchmarking = false);
    }
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
                      Text('Context ${c.settings.contextLength} · ${c.settings.threads} thread · CPU arm64 (llama.cpp tertanam)', style: const TextStyle(fontSize: 12, color: HqColors.muted)),
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
