import 'dart:convert';

import 'package:agent_hq/data/data_analyzer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('run_tests.gd fixtures', () {
    test('semicolon CSV with quotes and Indonesian currency', () {
      final csv = analyzeCsvText('tanggal;produk;qty;harga\n2026-01-02;Kopi;2;19.500,50\n2026-02-01;"Teh, hijau";1;10.000');
      expect(csv.ok, isTrue, reason: csv.error);
      expect(csv.rows, 2);
      expect(csv.skipped, 0);
      expect(csv.total, closeTo(49001.0, 1e-6));
      expect(csv.average, closeTo(24500.5, 1e-6));
      expect(csv.hasDate, isTrue);
      expect(csv.months, {'2026-01': closeTo(39001.0, 1e-6), '2026-02': closeTo(10000.0, 1e-6)});
      expect(csv.products.map((p) => p.name), ['Kopi', 'Teh, hijau']);
      expect(csv.products.first.value, closeTo(39001.0, 1e-6));
      expect(csv.preview.length, 2);
      expect(csv.preview.first.product, 'Kopi');
      expect(csv.preview.first.month, '2026-01');
      expect(csv.mapping.toJson(), {'date': 0, 'product': 1, 'quantity': 2, 'price': 3, 'revenue': -1});
      expect(csv.warnings, isEmpty);
    });
    test('messy CSV skips invalid rows', () {
      final messy = analyzeCsvText('product,revenue\nKopi,not-a-number\nTeh,5000');
      expect(messy.ok, isTrue);
      expect(messy.rows, 1);
      expect(messy.skipped, 1);
      expect(messy.total, 5000.0);
      expect(messy.hasDate, isFalse);
      expect(messy.months, {'Tanpa tanggal': 5000.0});
    });
    test('quoted comma and direct revenue', () {
      final quoted = analyzeCsvText('product,revenue\n"Tea, green",12500\nCoffee,7500');
      expect(quoted.ok, isTrue);
      expect(quoted.total, closeTo(20000.0, 1e-6));
      expect(quoted.products.first.name, 'Tea, green');
    });
    test('invalid numeric CSV is rejected', () {
      final result = analyzeCsvText('header\nno numbers');
      expect(result.ok, isFalse);
      expect(result.error, 'Kolom omzet/revenue atau pasangan qty + harga tidak ditemukan.');
      expect(result.headers, ['header']);
    });
  });

  group('analyzeRows', () {
    test('needs a header and one data row', () {
      expect(analyzeRows([]).error, 'CSV perlu satu baris judul dan minimal satu baris data.');
      expect(analyzeRows([['revenue']]).error, 'CSV perlu satu baris judul dan minimal satu baris data.');
    });
    test('rejects more than 100000 data rows', () {
      final rows = <List<String>>[['revenue']];
      for (var i = 0; i < analyzerMaxRows + 1; i++) {
        rows.add(const ['1']);
      }
      expect(analyzeRows(rows).error, 'CSV melebihi batas 100.000 baris.');
      rows.removeLast();
      expect(analyzeRows(rows).ok, isTrue);
    });
    test('no valid revenue rows', () {
      final result = analyzeRows([['revenue'], ['abc'], ['']]);
      expect(result.ok, isFalse);
      expect(result.error, 'Tidak ada baris dengan angka omzet yang valid.');
    });
    test('revenue column wins over qty * price and emits a double-count warning', () {
      final result = analyzeRows([
        ['Tanggal', 'Nama Produk', 'Jumlah', 'Harga Satuan', 'Total Omzet'],
        ['2026-03-05', 'Kopi', '2', '10000', '15000'],
      ]);
      expect(result.ok, isTrue);
      expect(result.total, 15000.0);
      expect(result.mapping.hasRevenue, isTrue);
      expect(result.mapping.hasQuantityAndPrice, isTrue);
      expect(result.warnings, hasLength(1));
      expect(result.warnings.first, contains('Total Omzet'));
      expect(result.warnings.first, contains('dihitung ganda'));
    });
    test('header aliases: first match wins, case and spaces normalised', () {
      final result = analyzeRows([
        ['  Omzet ', 'Sales', 'PRODUK', 'item'],
        ['100', '999', 'A', 'B'],
      ]);
      expect(result.mapping.revenue, 0);
      expect(result.mapping.product, 2);
      expect(result.total, 100.0);
      expect(result.products.single.name, 'A');
    });
    test('missing product and date columns use fallbacks and warn', () {
      final result = analyzeRows([
        ['revenue'],
        ['10'],
        ['5'],
      ]);
      expect(result.products.single.name, 'Produk');
      expect(result.months.keys.single, 'Tanpa tanggal');
      expect(result.hasDate, isFalse);
      expect(result.warnings.single, contains('Kolom produk tidak ditemukan'));
    });
    test('empty product and date cells use Tanpa nama / Tanpa tanggal', () {
      final result = analyzeRows([
        ['tanggal', 'produk', 'revenue'],
        ['', '', '10'],
        ['2026-05', 'X', '1'],
      ]);
      expect(result.products.map((p) => p.name), ['Tanpa nama', 'X']);
      expect(result.months.keys, containsAll(['Tanpa tanggal', '2026-05']));
    });
    test('month key is the first 7 chars of the date cell', () {
      final result = analyzeRows([
        ['date', 'revenue'],
        ['2026-01-15 10:00', '1'],
        ['2026-01-20', '2'],
        ['Q1', '3'],
      ]);
      expect(result.months, {'2026-01': 3.0, 'Q1': 3.0});
      expect(analyzeRows([['date', 'revenue'], ['', '1']]).months.keys.single, 'Tanpa tanggal');
    });
    test('short rows are skipped after value check, blank rows ignored', () {
      final result = analyzeRows([
        ['revenue', 'produk'],
        ['10'],
        [''],
        ['20', 'B'],
      ]);
      expect(result.rows, 1);
      expect(result.skipped, 1);
      expect(result.total, 20.0);
    });
    test('top products: max 5, sorted descending, ties keep first-seen order', () {
      final rows = <List<String>>[['produk', 'revenue']];
      for (var i = 0; i < 8; i++) {
        rows.add(['P$i', '${(i % 4) * 100}']);
      }
      final result = analyzeRows(rows);
      expect(result.products.length, 5);
      expect(result.products.map((p) => p.name), ['P3', 'P7', 'P2', 'P6', 'P1']);
      expect(result.products.first.value, 300.0);
    });
    test('preview holds at most 5 valid rows', () {
      final rows = <List<String>>[['revenue']];
      for (var i = 0; i < 9; i++) {
        rows.add(['$i']);
      }
      final result = analyzeRows(rows);
      expect(result.preview.length, 5);
      expect(result.preview.map((p) => p.value), [0.0, 1.0, 2.0, 3.0, 4.0]);
    });
    test('invalid qty or price skips the row', () {
      final result = analyzeRows([
        ['qty', 'harga'],
        ['2', 'x'],
        ['y', '2'],
        ['3', 'Rp 1.000'],
      ]);
      expect(result.rows, 1);
      expect(result.skipped, 2);
      expect(result.total, 3000.0);
    });
  });

  group('analyzeCsvText / analyzeBytes', () {
    test('strips BOM and detects tab delimiter', () {
      final result = analyzeCsvText('﻿produk\trevenue\r\nA\t1.000\r\n');
      expect(result.ok, isTrue, reason: result.error);
      expect(result.headers, ['produk', 'revenue']);
      expect(result.total, 1000.0);
    });
    test('rejects unknown extension and oversized input', () {
      expect(analyzeBytes(utf8.encode('a,b'), 'data.txt').error, 'Pilih berkas .csv atau .xlsx.');
      expect(analyzeBytes(List.filled(analyzerMaxBytes + 1, 32), 'big.csv').error, 'Ukuran file maksimum 20 MB.');
    });
    test('csv bytes go through the text path', () {
      final result = analyzeBytes(utf8.encode('produk,revenue\nKopi,5'), 'Sales.CSV');
      expect(result.ok, isTrue);
      expect(result.total, 5.0);
    });
    test('invalid xlsx bytes surface the reader error', () {
      expect(analyzeBytes([1, 2, 3], 'x.xlsx').error, 'File XLSX tidak valid atau tidak bisa dibuka.');
    });
  });
}
