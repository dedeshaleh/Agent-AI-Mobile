import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../data/dataset_import.dart';
import '../data/dataset_store.dart';
import 'theme.dart';

/// Daftar dataset di SQLite: impor banyak berkas, pilih, hapus, analisis.
/// Menutup dengan `true` bila analisis dataset terpilih berhasil, sehingga
/// layar utama bisa membuka AnalyticsSheet.
class DatasetsScreen extends StatelessWidget {
  const DatasetsScreen({super.key, required this.controller});
  final AppController controller;

  Future<void> _import(BuildContext context) async {
    final outcome = await controller.importDatasets();
    if (outcome == null || !context.mounted) return;
    await showImportSummary(context, outcome);
  }

  Future<void> _analyze(BuildContext context) async {
    final error = await controller.analyzeSelectedDatasets();
    if (!context.mounted) return;
    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error), backgroundColor: HqColors.danger.withValues(alpha: 0.9)));
      return;
    }
    Navigator.pop(context, true);
  }

  Future<void> _deleteAll(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Hapus semua dataset?'),
        content: const Text('Semua baris yang tersimpan di ponsel akan dihapus. Berkas aslinya tidak tersentuh.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Batal')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: HqColors.danger, foregroundColor: Colors.black),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Hapus semua'),
          ),
        ],
      ),
    );
    if (ok == true) await controller.deleteAllDatasets();
  }

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return AnimatedBuilder(
      animation: c,
      builder: (context, _) {
        final list = c.datasetList;
        final selected = list.where((d) => c.selectedDatasets.contains(d.id)).length;
        return Scaffold(
          appBar: AppBar(backgroundColor: HqColors.panel, title: const Text('Dataset tersimpan')),
          body: Column(
            children: [
              _ImportBar(controller: c, onImport: () => _import(context)),
              Expanded(
                child: list.isEmpty
                    ? const Center(
                        child: Padding(
                          padding: EdgeInsets.all(24),
                          child: Text(
                            'Belum ada dataset. Impor satu atau banyak berkas CSV/XLSX; semuanya disimpan di penyimpanan privat aplikasi.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: HqColors.muted),
                          ),
                        ),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                        itemCount: list.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 6),
                        itemBuilder: (context, i) => _DatasetTile(
                          info: list[i],
                          selected: c.selectedDatasets.contains(list[i].id),
                          onChanged: (v) => c.toggleDataset(list[i].id, v),
                          onDelete: () => c.deleteDataset(list[i].id),
                        ),
                      ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                color: HqColors.panel,
                child: SafeArea(
                  top: false,
                  child: Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: selected > 0 && !c.analyzing && !c.importing ? () => _analyze(context) : null,
                          icon: c.analyzing
                              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(Icons.insights),
                          label: Text('Analisis $selected dataset terpilih'),
                        ),
                      ),
                      const SizedBox(width: 6),
                      OutlinedButton(
                        onPressed: list.isEmpty || selected == list.length ? null : c.selectAllDatasets,
                        child: const Text('Pilih semua'),
                      ),
                      const SizedBox(width: 6),
                      OutlinedButton(
                        style: OutlinedButton.styleFrom(foregroundColor: HqColors.danger),
                        onPressed: list.isEmpty || c.importing ? null : () => _deleteAll(context),
                        child: const Text('Hapus semua'),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ImportBar extends StatelessWidget {
  const _ImportBar({required this.controller, required this.onImport});
  final AppController controller;
  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) {
    final progress = controller.importProgress;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      color: HqColors.panel,
      child: Row(
        children: [
          FilledButton.icon(
            onPressed: controller.importing ? null : onImport,
            icon: controller.importing
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.upload_file),
            label: const Text('Impor file (bisa banyak)'),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: controller.importing
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        progress == null ? 'Menyiapkan…' : 'File ${progress.index}/${progress.count}: ${progress.name}',
                        style: const TextStyle(fontSize: 12),
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      LinearProgressIndicator(value: progress == null ? null : (progress.index - 1) / progress.count),
                    ],
                  )
                : const Text(
                    'CSV/XLSX maks 20 MB dan 100.000 baris per berkas. Berkas yang sama tidak disimpan dua kali.',
                    style: TextStyle(fontSize: 11.5, color: HqColors.muted),
                  ),
          ),
        ],
      ),
    );
  }
}

class _DatasetTile extends StatelessWidget {
  const _DatasetTile({required this.info, required this.selected, required this.onChanged, required this.onDelete});
  final DatasetInfo info;
  final bool selected;
  final ValueChanged<bool> onChanged;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final d = info.importedAt.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    final date = '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
    return InkWell(
      onTap: () => onChanged(!selected),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
        decoration: BoxDecoration(
          color: selected ? HqColors.accent.withValues(alpha: 0.12) : HqColors.panelAlt,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: selected ? HqColors.accent.withValues(alpha: 0.6) : HqColors.border),
        ),
        child: Row(
          children: [
            Checkbox(value: selected, onChanged: (v) => onChanged(v ?? false)),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(info.name, style: const TextStyle(fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 2),
                  Text(
                    '${info.rowCount} baris valid · ${info.skipped} dilewati · diimpor $date',
                    style: TextStyle(fontSize: 11.5, color: info.skipped > 0 ? HqColors.warning : HqColors.muted),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Hapus dataset',
              onPressed: onDelete,
              icon: const Icon(Icons.delete_outline, color: HqColors.danger),
            ),
          ],
        ),
      ),
    );
  }
}

/// Ringkasan hasil impor: status tiap berkas (ok / duplikat / error).
Future<void> showImportSummary(BuildContext context, ImportOutcome outcome) {
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Impor selesai: ${outcome.okCount} berhasil, ${outcome.errorCount} gagal'),
      content: SizedBox(
        width: 480,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 320),
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final f in outcome.files)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        f.ok ? (f.duplicate ? Icons.copy_outlined : Icons.check_circle_outline) : Icons.error_outline,
                        size: 18,
                        color: f.ok ? (f.duplicate ? HqColors.warning : HqColors.accent) : HqColors.danger,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(f.name, style: const TextStyle(fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis),
                            Text(
                              f.ok
                                  ? (f.duplicate
                                      ? 'Duplikat: berkas ini sudah pernah diimpor, dipakai dataset lama.'
                                      : '${f.rows} baris valid, ${f.skipped} dilewati.')
                                  : f.error ?? 'Gagal.',
                              style: TextStyle(fontSize: 12, color: f.ok ? HqColors.muted : HqColors.danger),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Tutup'))],
    ),
  );
}
