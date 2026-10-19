/// Penyimpanan dataset penjualan di SQLite (privat aplikasi).
///
/// Baris mentah tidak pernah keluar dari sini; [analyze] hanya menghasilkan
/// [AnalysisResult] agregat, sama seperti jalur di memori.
library;

import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import 'analysis_result.dart';
import 'data_analyzer.dart';
import 'sales_row.dart';

/// Metadata satu dataset yang tersimpan.
class DatasetInfo {
  const DatasetInfo({
    required this.id,
    required this.name,
    required this.importedAt,
    required this.sha256,
    required this.headers,
    required this.mapping,
    required this.rowCount,
    required this.skipped,
    required this.warnings,
    this.duplicate = false,
  });

  final int id;
  final String name;
  final DateTime importedAt;
  final String sha256;
  final List<String> headers;
  final ColumnMapping mapping;
  final int rowCount;
  final int skipped;
  final List<String> warnings;

  /// True bila [DatasetStore.insertDataset] menemukan berkas yang sama
  /// sudah ada dan mengembalikan dataset lama.
  final bool duplicate;

  factory DatasetInfo.fromRow(Map<String, Object?> row, {bool duplicate = false}) => DatasetInfo(
        id: row['id'] as int,
        name: row['name'] as String,
        importedAt: DateTime.tryParse(row['imported_at'] as String) ?? DateTime.fromMillisecondsSinceEpoch(0),
        sha256: row['source_sha256'] as String,
        headers: (jsonDecode(row['headers_json'] as String) as List).cast<String>(),
        mapping: ColumnMapping.fromJson((jsonDecode(row['mapping_json'] as String) as Map).cast<String, Object?>()),
        rowCount: row['row_count'] as int,
        skipped: row['skipped'] as int,
        warnings: (jsonDecode(row['warnings_json'] as String) as List).cast<String>(),
        duplicate: duplicate,
      );
}

class DatasetStore {
  DatasetStore(this._factory, this.path);

  final DatabaseFactory _factory;
  final String path;
  Database? _db;

  static const int schemaVersion = 1;
  static const int _batchSize = 500;

  Future<void> open() async {
    if (_db != null) return;
    _db = await _factory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: schemaVersion,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        onCreate: (db, _) async {
          await db.execute('''
            CREATE TABLE datasets(
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              name TEXT NOT NULL,
              imported_at TEXT NOT NULL,
              source_sha256 TEXT NOT NULL,
              headers_json TEXT NOT NULL,
              mapping_json TEXT NOT NULL,
              row_count INTEGER NOT NULL,
              skipped INTEGER NOT NULL,
              warnings_json TEXT NOT NULL
            )''');
          await db.execute('''
            CREATE TABLE sales_rows(
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              dataset_id INTEGER NOT NULL REFERENCES datasets(id) ON DELETE CASCADE,
              row_index INTEGER NOT NULL,
              period TEXT NOT NULL,
              date TEXT,
              product TEXT NOT NULL,
              qty REAL,
              price REAL,
              revenue REAL NOT NULL
            )''');
          await db.execute('CREATE INDEX idx_sales_rows_dataset ON sales_rows(dataset_id)');
          await db.execute('CREATE INDEX idx_sales_rows_period ON sales_rows(dataset_id, period)');
          await db.execute('CREATE INDEX idx_sales_rows_product ON sales_rows(dataset_id, product)');
        },
      ),
    );
  }

  Database get _database {
    final db = _db;
    if (db == null) throw StateError('DatasetStore belum dibuka; panggil open() dulu.');
    return db;
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }

  /// Menyimpan dataset ternormalisasi. Berkas dengan SHA-256 yang sama tidak
  /// disimpan dua kali; dataset lama dikembalikan dengan `duplicate: true`.
  Future<DatasetInfo> insertDataset({
    required String name,
    required String sha256,
    required NormalizedDataset data,
  }) async {
    if (!data.ok) throw ArgumentError('Dataset gagal dinormalisasi: ${data.error}');
    final db = _database;
    final existing = await db.query('datasets', where: 'source_sha256 = ?', whereArgs: [sha256], limit: 1);
    if (existing.isNotEmpty) return DatasetInfo.fromRow(existing.first, duplicate: true);
    final id = await db.transaction((txn) async {
      final id = await txn.insert('datasets', {
        'name': name,
        'imported_at': DateTime.now().toIso8601String(),
        'source_sha256': sha256,
        'headers_json': jsonEncode(data.headers),
        'mapping_json': jsonEncode(data.mapping.toJson()),
        'row_count': data.rows.length,
        'skipped': data.skipped,
        'warnings_json': jsonEncode(data.warnings),
      });
      for (var start = 0; start < data.rows.length; start += _batchSize) {
        final batch = txn.batch();
        final end = start + _batchSize > data.rows.length ? data.rows.length : start + _batchSize;
        for (final row in data.rows.sublist(start, end)) {
          batch.insert('sales_rows', row.toMap()..['dataset_id'] = id);
        }
        await batch.commit(noResult: true);
      }
      return id;
    });
    final rows = await db.query('datasets', where: 'id = ?', whereArgs: [id]);
    return DatasetInfo.fromRow(rows.first);
  }

  Future<List<DatasetInfo>> list() async {
    final rows = await _database.query('datasets', orderBy: 'id ASC');
    return rows.map(DatasetInfo.fromRow).toList();
  }

  Future<void> delete(int id) async {
    await _database.delete('datasets', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> deleteAll() async {
    await _database.delete('datasets');
  }

  /// Agregat SQL untuk satu atau beberapa dataset. Angkanya identik dengan
  /// [analyzeRows] pada berkas yang sama (dibuktikan di test).
  Future<AnalysisResult> analyze(List<int> datasetIds, {String? sourceName}) async {
    final ids = datasetIds.toSet().toList();
    if (ids.isEmpty) return AnalysisResult.failure('Pilih minimal satu dataset.');
    final db = _database;
    final marks = List.filled(ids.length, '?').join(',');
    final infoRows = await db.query('datasets', where: 'id IN ($marks)', whereArgs: ids);
    final byId = {for (final r in infoRows) r['id'] as int: DatasetInfo.fromRow(r)};
    final infos = [for (final id in ids) if (byId[id] != null) byId[id]!];
    if (infos.isEmpty) return AnalysisResult.failure('Dataset tidak ditemukan.');
    final first = infos.first;
    final name = sourceName ?? (infos.length == 1 ? first.name : 'Gabungan ${infos.length} dataset');

    final totals = await db.rawQuery(
      'SELECT COUNT(*) AS c, COALESCE(SUM(revenue), 0) AS t FROM sales_rows WHERE dataset_id IN ($marks)',
      ids,
    );
    final count = (totals.first['c'] as num).toInt();
    final total = (totals.first['t'] as num).toDouble();
    if (count == 0) {
      return AnalysisResult.failure('Tidak ada baris dengan angka omzet yang valid.', headers: first.headers)
          .copyWith(sourceName: name);
    }
    final monthRows = await db.rawQuery(
      'SELECT period, SUM(revenue) AS v FROM sales_rows WHERE dataset_id IN ($marks) GROUP BY period',
      ids,
    );
    final months = {for (final r in monthRows) r['period'] as String: (r['v'] as num).toDouble()};
    // Seri diputus oleh id terkecil = urutan pertama muncul, sama dengan summarize().
    final productRows = await db.rawQuery(
      'SELECT product, SUM(revenue) AS v FROM sales_rows WHERE dataset_id IN ($marks) '
      'GROUP BY product ORDER BY v DESC, MIN(id) ASC LIMIT 5',
      ids,
    );
    final products = [for (final r in productRows) ProductTotal(r['product'] as String, (r['v'] as num).toDouble())];
    final previewRows = await db.query(
      'sales_rows',
      columns: ['product', 'period', 'revenue'],
      where: 'dataset_id IN ($marks)',
      whereArgs: ids,
      orderBy: 'dataset_id ASC, row_index ASC',
      limit: 5,
    );
    final preview = [
      for (final r in previewRows)
        PreviewRow(product: r['product'] as String, month: r['period'] as String, value: (r['revenue'] as num).toDouble()),
    ];
    final skipped = infos.fold<int>(0, (sum, d) => sum + d.skipped);
    final hasDate = infos.any((d) => d.mapping.date >= 0) || months.keys.any((m) => m != noDatePeriod);
    final warnings = <String>{for (final d in infos) ...d.warnings}.toList();
    if (infos.length > 1) warnings.add('Gabungan ${infos.length} dataset');
    return AnalysisResult(
      ok: true,
      sourceName: name,
      headers: first.headers,
      mapping: first.mapping,
      hasDate: hasDate,
      rows: count,
      skipped: skipped,
      total: total,
      average: total / count,
      months: Map.unmodifiable(months),
      products: List.unmodifiable(products),
      preview: List.unmodifiable(preview),
      warnings: List.unmodifiable(warnings),
    );
  }

  /// Kolom tiap indeks pada [table] sebagai `kolom1,kolom2` (diagnostik/test).
  Future<List<String>> indexColumns(String table) async {
    final db = _database;
    final result = <String>[];
    for (final index in await db.rawQuery('PRAGMA index_list($table)')) {
      final columns = (await db.rawQuery('PRAGMA index_info(${index['name']})')).toList()
        ..sort((a, b) => (a['seqno'] as int).compareTo(b['seqno'] as int));
      result.add(columns.map((c) => c['name']).join(','));
    }
    return result;
  }

  /// Baris mentah satu dataset (untuk debug/test; tidak dikirim ke model).
  Future<List<SalesRow>> rowsOf(int datasetId) async {
    final rows = await _database.query('sales_rows', where: 'dataset_id = ?', whereArgs: [datasetId], orderBy: 'row_index ASC');
    return rows.map(SalesRow.fromMap).toList();
  }
}
