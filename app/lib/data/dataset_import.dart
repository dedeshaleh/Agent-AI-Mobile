/// Impor banyak berkas CSV/XLSX ke [DatasetStore].
///
/// Parsing + normalisasi + SHA-256 berjalan di isolate terpisah per berkas;
/// penyisipan SQLite tetap di isolate utama karena sqflite memakai platform
/// channel. Satu berkas gagal tidak menghentikan berkas lain.
library;

import 'dart:isolate';

import 'package:crypto/crypto.dart';

import 'data_analyzer.dart';
import 'dataset_store.dart';

/// Sumber berkas yang dipilih pengguna; byte dibaca malas agar berkas besar
/// tidak semuanya ada di memori sekaligus.
typedef PickedSource = ({String name, Future<List<int>> Function() readBytes});

class ImportProgress {
  const ImportProgress({required this.index, required this.count, required this.name});

  /// Berbasis satu: berkas ke-[index] dari [count].
  final int index;
  final int count;
  final String name;
}

class ImportFileResult {
  const ImportFileResult({
    required this.name,
    required this.ok,
    this.error,
    this.datasetId,
    this.rows = 0,
    this.skipped = 0,
    this.duplicate = false,
  });
  final String name;
  final bool ok;
  final String? error;
  final int? datasetId;
  final int rows;
  final int skipped;
  final bool duplicate;
}

class ImportOutcome {
  const ImportOutcome(this.files);
  final List<ImportFileResult> files;

  List<ImportFileResult> get succeeded => files.where((f) => f.ok).toList();
  List<ImportFileResult> get failed => files.where((f) => !f.ok).toList();
  int get okCount => succeeded.length;
  int get errorCount => failed.length;
  int get duplicateCount => files.where((f) => f.duplicate).length;

  /// Id dataset dari semua berkas yang berhasil (termasuk duplikat).
  List<int> get datasetIds => [for (final f in succeeded) if (f.datasetId != null) f.datasetId!];
}

const String _unreadable = 'File tidak bisa dibaca. Coba simpan lalu pilih ulang.';

Future<ImportOutcome> importFiles(
  DatasetStore store,
  Iterable<PickedSource> sources, {
  void Function(ImportProgress progress)? onProgress,
}) async {
  final list = sources.toList();
  final results = <ImportFileResult>[];
  for (var i = 0; i < list.length; i++) {
    final source = list[i];
    onProgress?.call(ImportProgress(index: i + 1, count: list.length, name: source.name));
    results.add(await _importOne(store, source));
  }
  return ImportOutcome(results);
}

Future<ImportFileResult> _importOne(DatasetStore store, PickedSource source) async {
  final List<int> bytes;
  try {
    bytes = await source.readBytes();
  } catch (_) {
    return ImportFileResult(name: source.name, ok: false, error: _unreadable);
  }
  if (bytes.length > analyzerMaxBytes) {
    return ImportFileResult(name: source.name, ok: false, error: 'Ukuran file maksimum 20 MB.');
  }
  final name = source.name;
  final _Parsed parsed;
  try {
    parsed = await Isolate.run(() => _parse(bytes, name));
  } catch (e) {
    return ImportFileResult(name: name, ok: false, error: 'Gagal membaca berkas: $e');
  }
  if (!parsed.data.ok) return ImportFileResult(name: name, ok: false, error: parsed.data.error);
  try {
    final info = await store.insertDataset(name: name, sha256: parsed.sha256, data: parsed.data);
    return ImportFileResult(
      name: name,
      ok: true,
      datasetId: info.id,
      rows: info.rowCount,
      skipped: info.skipped,
      duplicate: info.duplicate,
    );
  } catch (e) {
    return ImportFileResult(name: name, ok: false, error: 'Gagal menyimpan ke basis data: $e');
  }
}

class _Parsed {
  const _Parsed(this.data, this.sha256);
  final NormalizedDataset data;
  final String sha256;
}

_Parsed _parse(List<int> bytes, String name) =>
    _Parsed(normalizeBytes(bytes, name), sha256.convert(bytes).toString());
