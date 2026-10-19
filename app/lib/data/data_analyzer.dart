/// Analisis omzet deterministik dari baris CSV/XLSX.
///
/// Port dari `game/scripts/csv_analyzer.gd`. Semua KPI dihitung di sini,
/// tanpa model AI. Alurnya dua tahap: [normalizeRows] mengenali kolom dan
/// mengubah tiap baris valid menjadi [SalesRow]; [summarize] mengagregasi
/// baris tersebut. Jalur SQLite ([DatasetStore]) memakai tahap pertama yang
/// sama, lalu agregasinya dihitung oleh SQL.
library;

import 'dart:convert';

import 'analysis_result.dart';
import 'csv_parser.dart';
import 'sales_row.dart';
import 'xlsx_reader.dart';

const int analyzerMaxBytes = 20 * 1024 * 1024;
const int analyzerMaxRows = 100000;

/// Teks pengganti bila kolom/sel tanggal kosong.
const String noDatePeriod = 'Tanpa tanggal';

const Map<String, List<String>> _aliases = {
  'date': ['tanggal', 'tanggal_transaksi', 'date', 'bulan', 'month'],
  'product': ['produk', 'nama_produk', 'product', 'item', 'barang', 'nama'],
  'quantity': ['qty', 'quantity', 'jumlah', 'jumlah_terjual', 'kuantitas'],
  'price': ['harga', 'price', 'unit_price', 'harga_satuan'],
  'revenue': ['revenue', 'pendapatan', 'total_pendapatan', 'total_omzet', 'omzet', 'sales', 'total'],
};

/// Hasil [normalizeRows]: pemetaan kolom dan baris valid, atau [error].
class NormalizedDataset {
  const NormalizedDataset({
    this.headers = const [],
    this.mapping = const ColumnMapping(),
    this.rows = const [],
    this.skipped = 0,
    this.warnings = const [],
    this.error,
  });

  factory NormalizedDataset.failure(String error, {List<String> headers = const []}) =>
      NormalizedDataset(error: error, headers: headers);

  final List<String> headers;
  final ColumnMapping mapping;
  final List<SalesRow> rows;
  final int skipped;
  final List<String> warnings;
  final String? error;

  bool get ok => error == null;
}

/// Memilih pembaca dari ekstensi nama berkas, lalu menganalisis.
AnalysisResult analyzeBytes(List<int> bytes, String fileName) =>
    summarizeDataset(normalizeBytes(bytes, fileName));

/// Seperti [analyzeBytes], tetapi berhenti di tahap normalisasi.
NormalizedDataset normalizeBytes(List<int> bytes, String fileName) {
  final name = fileName.toLowerCase();
  if (bytes.length > analyzerMaxBytes) {
    return NormalizedDataset.failure('Ukuran file maksimum 20 MB.');
  }
  if (name.endsWith('.xlsx')) {
    final workbook = readXlsxRows(bytes);
    if (!workbook.ok) return NormalizedDataset.failure(workbook.error!);
    return normalizeRows(workbook.rows);
  }
  if (!name.endsWith('.csv')) {
    return NormalizedDataset.failure('Pilih berkas .csv atau .xlsx.');
  }
  return normalizeCsvText(utf8.decode(bytes, allowMalformed: true));
}

AnalysisResult analyzeCsvText(String text) => summarizeDataset(normalizeCsvText(text));

NormalizedDataset normalizeCsvText(String text) {
  if (utf8.encode(text).length > analyzerMaxBytes) {
    return NormalizedDataset.failure('File lebih besar dari batas 20 MB.');
  }
  final clean = text.replaceAll('﻿', '');
  return normalizeRows(parseCsv(clean, delimiter: detectDelimiter(clean)));
}

/// Mengenali kolom lewat alias judul (Indonesia/Inggris), lalu mengagregasi.
/// Omzet diambil dari kolom revenue bila ada; jika tidak, `qty * harga`.
AnalysisResult analyzeRows(List<List<String>> rows) => summarizeDataset(normalizeRows(rows));

/// Mengenali kolom dan mengubah setiap baris valid menjadi [SalesRow].
/// Aturan validasi/lewat sama persis dengan [analyzeRows].
NormalizedDataset normalizeRows(List<List<String>> rows) {
  if (rows.length < 2) {
    return NormalizedDataset.failure('CSV perlu satu baris judul dan minimal satu baris data.');
  }
  if (rows.length > analyzerMaxRows + 1) {
    return NormalizedDataset.failure('CSV melebihi batas 100.000 baris.');
  }
  final headers = List<String>.unmodifiable(rows[0]);
  final map = <String, int>{'date': -1, 'product': -1, 'quantity': -1, 'price': -1, 'revenue': -1};
  for (var i = 0; i < headers.length; i++) {
    final key = headers[i].trim().toLowerCase().replaceAll(' ', '_');
    for (final field in _aliases.keys) {
      if (_aliases[field]!.contains(key) && map[field]! < 0) map[field] = i;
    }
  }
  final mapping = ColumnMapping(
    date: map['date']!,
    product: map['product']!,
    quantity: map['quantity']!,
    price: map['price']!,
    revenue: map['revenue']!,
  );
  if (!mapping.hasRevenue && !mapping.hasQuantityAndPrice) {
    return NormalizedDataset.failure(
      'Kolom omzet/revenue atau pasangan qty + harga tidak ditemukan.',
      headers: headers,
    );
  }
  final maxColumn = map.values.reduce((a, b) => a > b ? a : b);
  var skipped = 0;
  final out = <SalesRow>[];
  for (var r = 1; r < rows.length; r++) {
    final row = rows[r];
    if (row.length == 1 && row[0].trim().isEmpty) continue;
    final quantity = mapping.quantity >= 0 ? parseIndonesianNumber(_cell(row, mapping.quantity)) : null;
    final price = mapping.price >= 0 ? parseIndonesianNumber(_cell(row, mapping.price)) : null;
    double value;
    if (mapping.hasRevenue) {
      final revenue = parseIndonesianNumber(_cell(row, mapping.revenue));
      if (revenue == null) {
        skipped++;
        continue;
      }
      value = revenue;
    } else {
      if (quantity == null || price == null) {
        skipped++;
        continue;
      }
      value = quantity * price;
    }
    if (row.length <= maxColumn) {
      skipped++;
      continue;
    }
    var product = mapping.product >= 0 ? _cell(row, mapping.product) : 'Produk';
    if (product.isEmpty) product = 'Tanpa nama';
    // Kunci bulan = 7 karakter pertama tanggal (`YYYY-MM`). Berbeda dari
    // GDScript, teks pengganti "Tanpa tanggal" tidak ikut dipotong.
    final date = mapping.date >= 0 ? _cell(row, mapping.date) : '';
    var period = date.length >= 7 ? date.substring(0, 7) : date;
    if (period.isEmpty) period = noDatePeriod;
    out.add(SalesRow(
      rowIndex: r,
      period: period,
      date: date.isEmpty ? null : date,
      product: product,
      qty: quantity,
      price: price,
      revenue: value,
    ));
  }
  if (out.isEmpty) {
    return NormalizedDataset.failure('Tidak ada baris dengan angka omzet yang valid.');
  }
  final warnings = <String>[];
  if (mapping.hasRevenue && mapping.hasQuantityAndPrice) {
    warnings.add(
      'Omzet diambil dari kolom "${headers[mapping.revenue]}"; kolom '
      '"${headers[mapping.quantity]}" dan "${headers[mapping.price]}" diabaikan '
      'agar tidak dihitung ganda.',
    );
  }
  if (mapping.product < 0) {
    warnings.add('Kolom produk tidak ditemukan; semua baris digabung sebagai "Produk".');
  }
  return NormalizedDataset(
    headers: headers,
    mapping: mapping,
    rows: List.unmodifiable(out),
    skipped: skipped,
    warnings: List.unmodifiable(warnings),
  );
}

/// [summarize] untuk hasil [normalizeRows]; meneruskan error apa adanya.
AnalysisResult summarizeDataset(NormalizedDataset data, {String sourceName = ''}) {
  if (!data.ok) {
    return AnalysisResult.failure(data.error!, headers: data.headers).copyWith(sourceName: sourceName);
  }
  return summarize(
    data.rows,
    headers: data.headers,
    mapping: data.mapping,
    skipped: data.skipped,
    warnings: data.warnings,
    sourceName: sourceName,
  );
}

/// Mengagregasi baris ternormalisasi di memori: total, per periode, 5 produk
/// teratas (seri menurut urutan pertama muncul) dan pratinjau 5 baris pertama.
AnalysisResult summarize(
  Iterable<SalesRow> rows, {
  List<String> headers = const [],
  ColumnMapping mapping = const ColumnMapping(),
  int skipped = 0,
  List<String> warnings = const [],
  String sourceName = '',
}) {
  var total = 0.0;
  var valid = 0;
  final byMonth = <String, double>{};
  final byProduct = <String, double>{};
  final preview = <PreviewRow>[];
  for (final row in rows) {
    byMonth[row.period] = (byMonth[row.period] ?? 0.0) + row.revenue;
    byProduct[row.product] = (byProduct[row.product] ?? 0.0) + row.revenue;
    total += row.revenue;
    valid++;
    if (preview.length < 5) {
      preview.add(PreviewRow(product: row.product, month: row.period, value: row.revenue));
    }
  }
  if (valid == 0) {
    return AnalysisResult.failure('Tidak ada baris dengan angka omzet yang valid.', headers: headers)
        .copyWith(sourceName: sourceName);
  }
  final top = <ProductTotal>[];
  var order = 0;
  final seen = <String, int>{};
  byProduct.forEach((name, value) {
    seen[name] = order++;
    top.add(ProductTotal(name, value));
  });
  top.sort((a, b) {
    final byValue = b.value.compareTo(a.value);
    return byValue != 0 ? byValue : seen[a.name]!.compareTo(seen[b.name]!);
  });
  return AnalysisResult(
    ok: true,
    sourceName: sourceName,
    headers: headers,
    mapping: mapping,
    hasDate: mapping.date >= 0,
    rows: valid,
    skipped: skipped,
    total: total,
    average: total / valid,
    months: Map.unmodifiable(byMonth),
    products: List.unmodifiable(top.length > 5 ? top.sublist(0, 5) : top),
    preview: List.unmodifiable(preview),
    warnings: List.unmodifiable(warnings),
  );
}

String _cell(List<String> row, int index) =>
    index >= 0 && index < row.length ? row[index].trim() : '';
