import 'dart:convert';

import 'package:agent_hq/data/analysis_result.dart';
import 'package:agent_hq/data/data_analyzer.dart';
import 'package:agent_hq/data/dataset_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'xlsx_reader_test.dart' show buildXlsx, fixtureParts;

const _csv = 'tanggal;produk;qty;harga\n2026-01-02;Kopi;2;19.500,50\n2026-02-01;"Teh, hijau";1;10.000\nrusak;Teh;x;1';

void main() {
  sqfliteFfiInit();
  late DatasetStore store;

  setUp(() async {
    store = DatasetStore(databaseFactoryFfi, inMemoryDatabasePath);
    await store.open();
  });

  tearDown(() => store.close());

  Future<DatasetInfo> insert(String name, List<int> bytes) =>
      store.insertDataset(name: name, sha256: name, data: normalizeBytes(bytes, name));

  void expectSameNumbers(AnalysisResult sql, AnalysisResult memory) {
    expect(sql.ok, isTrue, reason: sql.error);
    expect(sql.rows, memory.rows);
    expect(sql.skipped, memory.skipped);
    expect(sql.total, closeTo(memory.total, 1e-6));
    expect(sql.average, closeTo(memory.average, 1e-6));
    expect(sql.hasDate, memory.hasDate);
    expect(sql.months.keys.toSet(), memory.months.keys.toSet());
    for (final m in memory.months.keys) {
      expect(sql.months[m], closeTo(memory.months[m]!, 1e-6), reason: m);
    }
    expect(sql.products.map((p) => p.name), memory.products.map((p) => p.name));
    for (final (i, p) in memory.products.indexed) {
      expect(sql.products[i].value, closeTo(p.value, 1e-6));
    }
    expect(sql.preview.map((p) => p.toJson()), memory.preview.map((p) => p.toJson()));
    expect(sql.headers, memory.headers);
    expect(sql.mapping.toJson(), memory.mapping.toJson());
    expect(sql.warnings, memory.warnings);
  }

  test('schema has the dataset, period and product indexes', () async {
    final indexes = await store.indexColumns('sales_rows');
    expect(indexes, containsAll(['dataset_id', 'dataset_id,period', 'dataset_id,product']));
  });

  test('CSV: analyze([id]) equals analyzeRows', () async {
    final bytes = utf8.encode(_csv);
    final info = await insert('toko.csv', bytes);
    expect(info.rowCount, 2);
    expect(info.skipped, 1);
    expect(info.duplicate, isFalse);
    expect(info.headers, ['tanggal', 'produk', 'qty', 'harga']);
    final sql = await store.analyze([info.id]);
    expectSameNumbers(sql, analyzeBytes(bytes, 'toko.csv'));
    expect(sql.sourceName, 'toko.csv');
  });

  test('XLSX fixture: analyze([id]) equals analyzeBytes', () async {
    final bytes = buildXlsx(fixtureParts());
    final info = await insert('phase2_test.xlsx', bytes);
    final sql = await store.analyze([info.id]);
    expectSameNumbers(sql, analyzeBytes(bytes, 'phase2_test.xlsx'));
    expect(sql.total, closeTo(60000.0, 1e-6));
  });

  test('top products: max 5, ties keep first-seen order (same as analyzeRows)', () async {
    final rows = <List<String>>[['produk', 'revenue']];
    for (var i = 0; i < 8; i++) {
      rows.add(['P$i', '${(i % 4) * 100}']);
    }
    final csv = rows.map((r) => r.join(',')).join('\n');
    final info = await insert('ties.csv', utf8.encode(csv));
    final sql = await store.analyze([info.id]);
    expectSameNumbers(sql, analyzeRows(rows));
    expect(sql.products.map((p) => p.name), ['P3', 'P7', 'P2', 'P6', 'P1']);
  });

  test('combined analyze over two datasets sums correctly', () async {
    final a = await insert('a.csv', utf8.encode(_csv));
    final b = await insert('b.csv', utf8.encode('product,revenue\nKopi,not-a-number\nTeh,5000'));
    final sql = await store.analyze([a.id, b.id]);
    expect(sql.ok, isTrue, reason: sql.error);
    expect(sql.sourceName, 'Gabungan 2 dataset');
    expect(sql.rows, 3);
    expect(sql.skipped, 2);
    expect(sql.total, closeTo(54001.0, 1e-6));
    expect(sql.average, closeTo(54001.0 / 3, 1e-6));
    expect(sql.months, {
      '2026-01': closeTo(39001.0, 1e-6),
      '2026-02': closeTo(10000.0, 1e-6),
      'Tanpa tanggal': closeTo(5000.0, 1e-6),
    });
    expect(sql.products.map((p) => p.name), ['Kopi', 'Teh, hijau', 'Teh']);
    expect(sql.preview.length, 3);
    expect(sql.headers, a.headers);
    expect(sql.warnings, ['Gabungan 2 dataset']);
    expect(sql.hasDate, isTrue);
  });

  test('duplicate sha256 is not re-inserted', () async {
    final data = normalizeBytes(utf8.encode(_csv), 'a.csv');
    final first = await store.insertDataset(name: 'a.csv', sha256: 'abc', data: data);
    final second = await store.insertDataset(name: 'copy.csv', sha256: 'abc', data: data);
    expect(second.duplicate, isTrue);
    expect(second.id, first.id);
    expect(second.name, 'a.csv');
    expect(await store.list(), hasLength(1));
    expect((await store.rowsOf(first.id)).length, 2);
  });

  test('delete cascades rows; deleteAll empties everything', () async {
    final a = await insert('a.csv', utf8.encode(_csv));
    final b = await insert('b.csv', utf8.encode('product,revenue\nTeh,5000'));
    await store.delete(a.id);
    expect(await store.rowsOf(a.id), isEmpty);
    expect((await store.list()).map((d) => d.id), [b.id]);
    expect((await store.rowsOf(b.id)).length, 1);
    await store.deleteAll();
    expect(await store.list(), isEmpty);
    expect(await store.rowsOf(b.id), isEmpty);
    expect((await store.analyze([b.id])).ok, isFalse);
  });

  test('analyze with no ids or unknown ids fails cleanly', () async {
    expect((await store.analyze([])).error, 'Pilih minimal satu dataset.');
    expect((await store.analyze([999])).error, 'Dataset tidak ditemukan.');
  });

  test('inserting a failed normalisation throws', () async {
    expect(
      () => store.insertDataset(name: 'x', sha256: 'x', data: normalizeRows([])),
      throwsArgumentError,
    );
  });
}
