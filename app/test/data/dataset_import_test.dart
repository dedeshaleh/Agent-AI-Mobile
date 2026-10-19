import 'dart:convert';

import 'package:agent_hq/data/data_analyzer.dart';
import 'package:agent_hq/data/dataset_import.dart';
import 'package:agent_hq/data/dataset_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'xlsx_reader_test.dart' show buildXlsx, fixtureParts;

PickedSource source(String name, List<int> bytes) => (name: name, readBytes: () async => bytes);

void main() {
  sqfliteFfiInit();
  late DatasetStore store;

  setUp(() async {
    store = DatasetStore(databaseFactoryFfi, inMemoryDatabasePath);
    await store.open();
  });

  tearDown(() => store.close());

  test('two good files + one broken file: 2 ok, 1 error, 2 datasets stored', () async {
    final progress = <String>[];
    final outcome = await importFiles(
      store,
      [
        source('toko.csv', utf8.encode('tanggal;produk;qty;harga\n2026-01-02;Kopi;2;19.500,50')),
        source('rusak.xlsx', [1, 2, 3]),
        source('phase2.xlsx', buildXlsx(fixtureParts())),
      ],
      onProgress: (p) => progress.add('${p.index}/${p.count} ${p.name}'),
    );
    expect(progress, ['1/3 toko.csv', '2/3 rusak.xlsx', '3/3 phase2.xlsx']);
    expect(outcome.okCount, 2);
    expect(outcome.errorCount, 1);
    expect(outcome.duplicateCount, 0);
    expect(outcome.files[0].ok, isTrue);
    expect(outcome.files[0].rows, 1);
    expect(outcome.files[1].ok, isFalse);
    expect(outcome.files[1].error, 'File XLSX tidak valid atau tidak bisa dibuka.');
    expect(outcome.files[2].ok, isTrue);
    expect(outcome.files[2].rows, 2);
    final stored = await store.list();
    expect(stored.map((d) => d.name), ['toko.csv', 'phase2.xlsx']);
    expect(outcome.datasetIds, stored.map((d) => d.id));
    final combined = await store.analyze(outcome.datasetIds);
    expect(combined.rows, 3);
    expect(combined.total, closeTo(99001.0, 1e-6));
  });

  test('same bytes twice is reported as duplicate and stored once', () async {
    final bytes = utf8.encode('product,revenue\nTeh,5000');
    final outcome = await importFiles(store, [source('a.csv', bytes), source('b.csv', bytes)]);
    expect(outcome.okCount, 2);
    expect(outcome.duplicateCount, 1);
    expect(outcome.files[1].duplicate, isTrue);
    expect(outcome.files[1].datasetId, outcome.files[0].datasetId);
    expect(await store.list(), hasLength(1));
  });

  test('limits and unreadable sources use the existing Indonesian messages', () async {
    final outcome = await importFiles(store, [
      source('big.csv', List.filled(analyzerMaxBytes + 1, 32)),
      (name: 'hilang.csv', readBytes: () async => throw Exception('gone')),
      source('data.txt', utf8.encode('a,b')),
      source('kosong.csv', utf8.encode('revenue\nabc')),
    ]);
    expect(outcome.files.map((f) => f.error), [
      'Ukuran file maksimum 20 MB.',
      'File tidak bisa dibaca. Coba simpan lalu pilih ulang.',
      'Pilih berkas .csv atau .xlsx.',
      'Tidak ada baris dengan angka omzet yang valid.',
    ]);
    expect(await store.list(), isEmpty);
  });
}
