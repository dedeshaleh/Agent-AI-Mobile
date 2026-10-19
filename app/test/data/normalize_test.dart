import 'package:agent_hq/data/data_analyzer.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fixture yang sama dengan data_analyzer_test.dart: normalizeRows harus
/// menghasilkan baris/omzet yang identik dengan analyzeRows.
const _fixtures = <String, List<List<String>>>{
  'revenue wins over qty*price': [
    ['Tanggal', 'Nama Produk', 'Jumlah', 'Harga Satuan', 'Total Omzet'],
    ['2026-03-05', 'Kopi', '2', '10000', '15000'],
  ],
  'aliases': [
    ['  Omzet ', 'Sales', 'PRODUK', 'item'],
    ['100', '999', 'A', 'B'],
  ],
  'missing product and date': [
    ['revenue'],
    ['10'],
    ['5'],
  ],
  'empty cells': [
    ['tanggal', 'produk', 'revenue'],
    ['', '', '10'],
    ['2026-05', 'X', '1'],
  ],
  'month key': [
    ['date', 'revenue'],
    ['2026-01-15 10:00', '1'],
    ['2026-01-20', '2'],
    ['Q1', '3'],
  ],
  'short and blank rows': [
    ['revenue', 'produk'],
    ['10'],
    [''],
    ['20', 'B'],
  ],
  'invalid qty or price': [
    ['qty', 'harga'],
    ['2', 'x'],
    ['y', '2'],
    ['3', 'Rp 1.000'],
  ],
};

void main() {
  group('normalizeRows parity with analyzeRows', () {
    for (final entry in _fixtures.entries) {
      test(entry.key, () {
        final analysis = analyzeRows(entry.value);
        final data = normalizeRows(entry.value);
        expect(data.ok, analysis.ok, reason: data.error);
        expect(data.rows.length, analysis.rows);
        expect(data.skipped, analysis.skipped);
        expect(data.rows.fold<double>(0, (s, r) => s + r.revenue), closeTo(analysis.total, 1e-9));
        expect(data.mapping.toJson(), analysis.mapping.toJson());
        expect(data.headers, analysis.headers);
        expect(data.warnings, analysis.warnings);
        final periods = <String, double>{};
        for (final r in data.rows) {
          periods[r.period] = (periods[r.period] ?? 0) + r.revenue;
        }
        expect(periods.keys.toSet(), analysis.months.keys.toSet());
        expect(summarizeDataset(data).toJson(), analysis.toJson());
      });
    }

    test('csv text fixture keeps row index, date, qty and price', () {
      final data = normalizeCsvText('tanggal;produk;qty;harga\n2026-01-02;Kopi;2;19.500,50\n\n2026-02-01;"Teh, hijau";1;10.000');
      expect(data.ok, isTrue, reason: data.error);
      expect(data.rows.map((r) => r.rowIndex), [1, 3]);
      expect(data.rows.first.date, '2026-01-02');
      expect(data.rows.first.period, '2026-01');
      expect(data.rows.first.qty, 2);
      expect(data.rows.first.price, closeTo(19500.5, 1e-9));
      expect(data.rows.first.revenue, closeTo(39001.0, 1e-9));
      expect(data.rows.last.product, 'Teh, hijau');
    });

    test('rows without a date column have null date and Tanpa tanggal period', () {
      final data = normalizeRows([
        ['product', 'revenue'],
        ['Kopi', 'not-a-number'],
        ['Teh', '5000'],
      ]);
      expect(data.rows.single.date, isNull);
      expect(data.rows.single.period, noDatePeriod);
      expect(data.rows.single.qty, isNull);
      expect(data.skipped, 1);
    });

    test('errors mirror analyzeRows', () {
      expect(normalizeRows([]).error, analyzeRows([]).error);
      expect(normalizeRows([['header'], ['x']]).error, analyzeRows([['header'], ['x']]).error);
      expect(normalizeRows([['revenue'], ['abc']]).error, 'Tidak ada baris dengan angka omzet yang valid.');
      expect(normalizeBytes([1, 2], 'x.txt').error, 'Pilih berkas .csv atau .xlsx.');
    });
  });
}
