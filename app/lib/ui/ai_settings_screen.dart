import 'package:flutter/material.dart';

import '../agents/agent_role.dart';
import '../ai/ai_provider.dart';
import '../ai/ai_settings.dart';
import '../ai/api_key_store.dart';
import '../ai/local/local_engine.dart';
import '../ai/providers/anthropic_provider.dart';
import '../ai/providers/gemini_provider.dart';
import '../app_controller.dart';
import 'theme.dart';

/// Pengaturan AI (PRD §6.4–6.5): mode, provider, penugasan per agent, pemakaian.
class AiSettingsScreen extends StatefulWidget {
  const AiSettingsScreen({super.key, required this.controller});
  final AppController controller;

  @override
  State<AiSettingsScreen> createState() => _AiSettingsScreenState();
}

class _AiSettingsScreenState extends State<AiSettingsScreen> {
  AppController get c => widget.controller;
  final _health = <String, HealthResult>{};
  final _testing = <String>{};

  void _toast(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _test(ProviderConfig cfg) async {
    setState(() => _testing.add(cfg.id));
    final key = await c.keyStore.read(cfg.id);
    final result = await c.router.testProvider(cfg, key);
    if (!mounted) return;
    setState(() {
      _testing.remove(cfg.id);
      _health[cfg.id] = result;
    });
  }

  Future<void> _edit([ProviderConfig? existing]) async {
    final saved = await showDialog<_ProviderForm>(
      context: context,
      builder: (_) => _ProviderDialog(existing: existing, keyStore: c.keyStore),
    );
    if (saved == null) return;
    await c.settingsStore.update((s) => s.upsertProvider(saved.config));
    if (saved.apiKey != null) {
      if (saved.apiKey!.isEmpty) {
        await c.keyStore.delete(saved.config.id);
      } else {
        await c.keyStore.write(saved.config.id, saved.apiKey!);
      }
    }
    if (mounted) _test(saved.config);
  }

  Future<void> _remove(ProviderConfig cfg) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Hapus ${cfg.name}?'),
        content: const Text('API key provider ini ikut dihapus dari penyimpanan aman.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Batal')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Hapus')),
        ],
      ),
    );
    if (ok != true) return;
    await c.keyStore.delete(cfg.id);
    await c.settingsStore.update((s) => s.removeProvider(cfg.id));
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([c.settingsStore, c.usage]),
      builder: (context, _) {
        final s = c.settings;
        return Scaffold(
          appBar: AppBar(title: const Text('Pengaturan AI'), backgroundColor: HqColors.panel),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => _edit(),
            icon: const Icon(Icons.add),
            label: const Text('Tambah Provider'),
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 90),
            children: [
              const _Section('MODE'),
              SegmentedButton<AiMode>(
                segments: [for (final m in AiMode.values) ButtonSegment(value: m, label: Text(m.label))],
                selected: {s.mode},
                onSelectionChanged: (v) => c.settingsStore.update((cur) => cur.copyWith(mode: v.first)),
              ),
              const SizedBox(height: 6),
              Text(
                switch (s.mode) {
                  AiMode.offlineOnly => 'Tidak ada panggilan jaringan. Semua agent memakai model lokal di HP.',
                  AiMode.hybrid => 'Provider cloud hanya untuk agent yang ditugaskan; gagal → kembali ke model lokal.',
                  AiMode.cloudPreferred => 'Provider cloud dicoba lebih dulu; model lokal menjadi cadangan.',
                },
                style: const TextStyle(fontSize: 12, color: HqColors.muted),
              ),
              const SizedBox(height: 18),
              const _Section('PROVIDER'),
              _ProviderTile(
                cfg: ProviderConfig.local,
                subtitle: c.models.activeModel?.name ?? 'Belum ada model aktif (menu Model)',
                health: c.engine.state.name == 'ready' ? const HealthResult.ok() : HealthResult.fail('Model belum dimuat'),
              ),
              for (final cfg in s.providers)
                _ProviderTile(
                  cfg: cfg,
                  subtitle: '${cfg.kind.label} · ${cfg.modelId.isEmpty ? 'model belum diisi' : cfg.modelId}${cfg.baseUrl.isEmpty ? '' : ' · ${cfg.baseUrl}'}',
                  health: _health[cfg.id],
                  testing: _testing.contains(cfg.id),
                  onTest: () => _test(cfg),
                  onEdit: () => _edit(cfg),
                  onDelete: () => _remove(cfg),
                  onToggle: (v) => c.settingsStore.update((cur) => cur.upsertProvider(cfg.copyWith(enabled: v))),
                ),
              const SizedBox(height: 18),
              const _Section('PENUGASAN PER AGENT'),
              for (final role in AgentRole.values)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    children: [
                      Container(width: 9, height: 9, decoration: BoxDecoration(color: role.color, shape: BoxShape.circle)),
                      const SizedBox(width: 8),
                      SizedBox(width: 100, child: Text(role.title, style: const TextStyle(fontWeight: FontWeight.w600))),
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          initialValue: s.assignedProviderId(role),
                          items: [
                            for (final p in s.allProviders)
                              DropdownMenuItem(value: p.id, child: Text(p.id == ProviderConfig.localId ? 'Model lokal' : p.name)),
                          ],
                          onChanged: (v) => v == null ? null : c.settingsStore.update((cur) => cur.assign(role, v)),
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 18),
              const _Section('PARAMETER MODEL LOKAL'),
              _Slider('Context (token)', s.contextLength.toDouble(), 1024, 8192, 1024, (v) => c.settingsStore.update((cur) => cur.copyWith(contextLength: v.round()))),
              _Slider('Thread CPU', s.threads.toDouble().clamp(2, c.cpu.recommendedThreads.toDouble()), 2, c.cpu.recommendedThreads.toDouble(), (c.cpu.recommendedThreads - 2).clamp(1, 6).toDouble(),
                  (v) => c.settingsStore.update((cur) => cur.copyWith(threads: v.round()))),
              Text(
                'Perangkat ini punya ${c.cpu.totalCores} core (${c.cpu.bigCores} core besar). llama.cpp menunggu thread paling lambat, jadi thread dibatasi ke core besar; lebih banyak thread justru memperlambat.',
                style: const TextStyle(fontSize: 11, color: HqColors.muted),
              ),
              _Slider('Output maks (token)', s.maxTokens.toDouble(), 128, 1024, 64, (v) => c.settingsStore.update((cur) => cur.copyWith(maxTokens: v.round()))),
              const SizedBox(height: 8),
              const Text('Backend inferensi', style: TextStyle(fontSize: 13)),
              const SizedBox(height: 4),
              SegmentedButton<LocalGpuBackend>(
                segments: const [
                  ButtonSegment(value: LocalGpuBackend.cpu, label: Text('CPU'), icon: Icon(Icons.memory, size: 16)),
                  ButtonSegment(value: LocalGpuBackend.vulkan, label: Text('Vulkan'), icon: Icon(Icons.videogame_asset_outlined, size: 16)),
                  ButtonSegment(value: LocalGpuBackend.opencl, label: Text('OpenCL'), icon: Icon(Icons.developer_board, size: 16)),
                ],
                selected: {s.gpuBackend},
                onSelectionChanged: (v) => c.settingsStore.update((cur) => cur.copyWith(gpuBackend: v.first)),
              ),
              _GpuInfoLine(engine: c.engine),
              if (s.useGpu) ...[
                const SizedBox(height: 8),
                const Text('Pembagian beban', style: TextStyle(fontSize: 13)),
                const SizedBox(height: 4),
                SegmentedButton<GpuSplitPreset>(
                  segments: [for (final p in GpuSplitPreset.values) ButtonSegment(value: p, label: Text(p.label))],
                  selected: {s.gpuPreset},
                  onSelectionChanged: (v) => c.settingsStore.update((cur) => cur.withGpuPreset(v.first, layerCount: c.engine.loadedModel?.layerCount)),
                ),
                const SizedBox(height: 6),
                _Slider('Layer di GPU', s.gpuLayers.toDouble().clamp(0, 99), 0, 99, 1, (v) => c.settingsStore.update((cur) => cur.copyWith(gpuLayers: v.round()))),
                Text(
                  s.gpuLayers <= 0
                      ? '0 = semua layer di CPU (${s.threads} thread) walau backend GPU dipilih.'
                      : s.gpuLayers >= AiSettings.allGpuLayers
                          ? '99 = semua layer ke GPU ${s.gpuBackend.label}. Kurangi bila memori GPU tidak cukup atau game view tersendat.'
                          : '${s.gpuLayers} layer ke GPU ${s.gpuBackend.label}, sisanya CPU ${s.threads} thread (hybrid). 99 = semua layer.'
                              '${c.engine.loadedModel != null && c.engine.loadedModel!.layerCount > 0 ? ' Model aktif: ${c.engine.loadedModel!.layerCount} layer.' : ''}',
                  style: const TextStyle(fontSize: 11, color: HqColors.muted),
                ),
              ],
              const Text('Perubahan context/thread/backend berlaku saat model dimuat ulang. Bila GPU tidak tersedia, model otomatis dimuat di CPU. Tombol "Uji otomatis" di menu Model memilih pembagian tercepat.', style: TextStyle(fontSize: 11, color: HqColors.muted)),
              const SizedBox(height: 18),
              const _Section('KEAMANAN'),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Izinkan HTTP ke alamat LAN/loopback'),
                subtitle: const Text('Hanya untuk Ollama/LM Studio di PC yang sama jaringan. Internet tetap wajib HTTPS.', style: TextStyle(fontSize: 11)),
                value: s.allowInsecureLan,
                onChanged: (v) => c.settingsStore.update((cur) => cur.copyWith(allowInsecureLan: v)),
              ),
              Wrap(
                spacing: 8,
                children: [
                  OutlinedButton(
                    onPressed: () async {
                      await c.forgetConsents();
                      _toast('Persetujuan pengiriman data dicabut; pratinjau akan ditanya lagi.');
                    },
                    child: const Text('Cabut persetujuan kirim data'),
                  ),
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(foregroundColor: HqColors.danger),
                    onPressed: () async {
                      for (final p in s.providers) {
                        await c.keyStore.delete(p.id);
                      }
                      _toast('Semua API key dihapus.');
                    },
                    child: const Text('Hapus semua API key'),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              const _Section('PEMAKAIAN TOKEN'),
              if (c.usage.entries.isEmpty)
                const Text('Belum ada pemakaian tercatat.', style: TextStyle(color: HqColors.muted, fontSize: 12))
              else
                for (final e in c.usage.totalsPerProvider.entries)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Row(
                      children: [
                        Expanded(child: Text(c.providerName(e.key))),
                        Text('${e.value.calls} panggilan · ${e.value.inputTokens} in / ${e.value.outputTokens} out · ${e.value.failures} gagal',
                            style: const TextStyle(fontSize: 12, color: HqColors.muted)),
                      ],
                    ),
                  ),
              if (c.usage.entries.isNotEmpty)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(onPressed: c.usage.clear, child: const Text('Hapus log pemakaian')),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _ProviderTile extends StatelessWidget {
  const _ProviderTile({
    required this.cfg,
    required this.subtitle,
    this.health,
    this.testing = false,
    this.onTest,
    this.onEdit,
    this.onDelete,
    this.onToggle,
  });
  final ProviderConfig cfg;
  final String subtitle;
  final HealthResult? health;
  final bool testing;
  final VoidCallback? onTest;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  final ValueChanged<bool>? onToggle;

  @override
  Widget build(BuildContext context) {
    final status = health;
    final color = status == null ? HqColors.muted : (status.healthy ? HqColors.local : HqColors.danger);
    return Card(
      child: ListTile(
        leading: Icon(cfg.kind == AiProviderKind.local ? Icons.phone_android : Icons.cloud_outlined, color: cfg.kind == AiProviderKind.local ? HqColors.local : HqColors.cloud),
        title: Text(cfg.name, style: TextStyle(decoration: cfg.enabled ? null : TextDecoration.lineThrough)),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(subtitle, style: const TextStyle(fontSize: 11.5)),
            Text(status == null ? 'Belum diuji' : status.detail, style: TextStyle(fontSize: 11.5, color: color)),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (onToggle != null) Switch(value: cfg.enabled, onChanged: onToggle),
            if (onTest != null)
              testing
                  ? const Padding(padding: EdgeInsets.all(12), child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)))
                  : IconButton(tooltip: 'Tes Koneksi', onPressed: onTest, icon: const Icon(Icons.network_check)),
            if (onEdit != null) IconButton(onPressed: onEdit, icon: const Icon(Icons.edit_outlined)),
            if (onDelete != null) IconButton(onPressed: onDelete, icon: const Icon(Icons.delete_outline, color: HqColors.danger)),
          ],
        ),
      ),
    );
  }
}

class _ProviderForm {
  const _ProviderForm(this.config, this.apiKey);
  final ProviderConfig config;

  /// null = tidak diubah; '' = hapus.
  final String? apiKey;
}

class _ProviderDialog extends StatefulWidget {
  const _ProviderDialog({this.existing, required this.keyStore});
  final ProviderConfig? existing;
  final ApiKeyStore keyStore;

  @override
  State<_ProviderDialog> createState() => _ProviderDialogState();
}

class _ProviderDialogState extends State<_ProviderDialog> {
  late AiProviderKind kind = widget.existing?.kind ?? AiProviderKind.openaiCompatible;
  late final name = TextEditingController(text: widget.existing?.name ?? '');
  late final baseUrl = TextEditingController(text: widget.existing?.baseUrl ?? '');
  late final modelId = TextEditingController(text: widget.existing?.modelId ?? '');
  final apiKey = TextEditingController();
  late bool allowRawRows = widget.existing?.allowRawRows ?? false;
  bool obscure = true;
  String? existingMasked;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    if (e != null) {
      widget.keyStore.read(e.id).then((k) {
        if (mounted && k != null && k.isNotEmpty) setState(() => existingMasked = ApiKeyStore.masked(k));
      });
    }
  }

  @override
  void dispose() {
    for (final c in [name, baseUrl, modelId, apiKey]) {
      c.dispose();
    }
    super.dispose();
  }

  bool get needsUrl => kind == AiProviderKind.openaiCompatible || kind == AiProviderKind.custom;

  List<String> get suggestions => switch (kind) {
        AiProviderKind.anthropic => AnthropicProvider.suggestedModelIds,
        AiProviderKind.gemini => GeminiProvider.suggestedModelIds,
        AiProviderKind.openaiCompatible => const ['gpt-4o-mini', 'deepseek-chat', 'llama-3.3-70b-versatile'],
        AiProviderKind.custom => const ['qwen3:4b', 'llama3.2'],
        AiProviderKind.local => const [],
      };

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? 'Tambah provider AI' : 'Ubah provider'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DropdownButtonFormField<AiProviderKind>(
                initialValue: kind,
                decoration: const InputDecoration(labelText: 'Jenis'),
                items: [
                  for (final k in AiProviderKind.values.where((k) => k != AiProviderKind.local)) DropdownMenuItem(value: k, child: Text(k.label)),
                ],
                onChanged: widget.existing == null ? (v) => setState(() => kind = v ?? kind) : null,
              ),
              const SizedBox(height: 10),
              TextField(controller: name, decoration: const InputDecoration(labelText: 'Nama tampilan')),
              if (needsUrl) ...[
                const SizedBox(height: 10),
                TextField(
                  controller: baseUrl,
                  keyboardType: TextInputType.url,
                  decoration: InputDecoration(
                    labelText: 'Base URL',
                    hintText: kind == AiProviderKind.custom ? 'http://192.168.1.10:11434' : 'https://api.openai.com',
                  ),
                ),
              ],
              const SizedBox(height: 10),
              TextField(controller: modelId, decoration: const InputDecoration(labelText: 'Model ID')),
              if (suggestions.isNotEmpty)
                Wrap(
                  spacing: 6,
                  children: [
                    for (final s in suggestions) ActionChip(label: Text(s, style: const TextStyle(fontSize: 11)), onPressed: () => modelId.text = s),
                  ],
                ),
              const SizedBox(height: 10),
              TextField(
                controller: apiKey,
                obscureText: obscure,
                decoration: InputDecoration(
                  labelText: 'API key${kind == AiProviderKind.custom ? ' (opsional)' : ''}',
                  helperText: existingMasked == null ? 'Disimpan di Android Keystore, tidak pernah dicatat di log.' : 'Tersimpan: $existingMasked (kosongkan untuk tetap memakai)',
                  suffixIcon: IconButton(icon: Icon(obscure ? Icons.visibility : Icons.visibility_off), onPressed: () => setState(() => obscure = !obscure)),
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Izinkan kirim baris mentah', style: TextStyle(fontSize: 14)),
                subtitle: const Text('Default hanya agregat KPI. Nyalakan hanya jika kamu paham datanya keluar dari HP.', style: TextStyle(fontSize: 11)),
                value: allowRawRows,
                onChanged: (v) => setState(() => allowRawRows = v),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Batal')),
        FilledButton(
          onPressed: () {
            if (name.text.trim().isEmpty || modelId.text.trim().isEmpty || (needsUrl && baseUrl.text.trim().isEmpty)) return;
            final id = widget.existing?.id ?? '${kind.name}-${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';
            final cfg = ProviderConfig(
              id: id,
              kind: kind,
              name: name.text.trim(),
              baseUrl: baseUrl.text.trim(),
              modelId: modelId.text.trim(),
              enabled: widget.existing?.enabled ?? true,
              allowRawRows: allowRawRows,
            );
            final key = apiKey.text.trim();
            Navigator.pop(context, _ProviderForm(cfg, key.isEmpty && widget.existing != null ? null : key));
          },
          child: const Text('Simpan & tes'),
        ),
      ],
    );
  }
}

class _Slider extends StatelessWidget {
  const _Slider(this.label, this.value, this.min, this.max, this.step, this.onChanged);
  final String label;
  final double value, min, max, step;
  final ValueChanged<double> onChanged;
  @override
  Widget build(BuildContext context) => Row(
        children: [
          SizedBox(width: 150, child: Text(label, style: const TextStyle(fontSize: 13))),
          Expanded(
            child: Slider(value: value.clamp(min, max), min: min, max: max, divisions: ((max - min) / step).round(), onChanged: onChanged),
          ),
          SizedBox(width: 50, child: Text(value.round().toString(), textAlign: TextAlign.right)),
        ],
      );
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

/// Dua baris deteksi, satu per backend: "Vulkan: GPU tidak bisa dipakai: Vulkan
/// 1.1 (ggml butuh 1.2)" dan "OpenCL: Terdeteksi: Mali-G610 MC6, OpenCL 3.0,
/// VRAM bersama". Ditanya sekali ke engine (lewat isolate pekerja), bukan tiap build.
class _GpuInfoLine extends StatefulWidget {
  const _GpuInfoLine({required this.engine});
  final LocalEngine engine;

  @override
  State<_GpuInfoLine> createState() => _GpuInfoLineState();
}

class _GpuInfoLineState extends State<_GpuInfoLine> {
  late final Future<LocalGpuReport> _info = widget.engine.gpuInfo().catchError((_) => LocalGpuReport.none);

  @override
  Widget build(BuildContext context) => FutureBuilder<LocalGpuReport>(
        future: _info,
        builder: (context, snap) {
          final report = snap.data;
          if (report == null) {
            return const Padding(
              padding: EdgeInsets.only(top: 4, bottom: 2),
              child: Text('Mendeteksi GPU (Vulkan, OpenCL)…', style: TextStyle(fontSize: 11, color: HqColors.muted)),
            );
          }
          return Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 2),
            child: Column(
              children: [
                for (final info in report.all)
                  Row(
                    children: [
                      Icon(info.available ? Icons.check_circle_outline : Icons.info_outline, size: 14, color: info.available ? HqColors.local : HqColors.muted),
                      const SizedBox(width: 6),
                      Expanded(child: Text(info.labeledWithBackend, style: const TextStyle(fontSize: 11, color: HqColors.muted))),
                    ],
                  ),
              ],
            ),
          );
        },
      );
}
