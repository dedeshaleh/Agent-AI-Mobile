import 'dart:convert';
import 'dart:io';

import 'package:agent_hq/data/data_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('analyzeBytesInBackground runs the analysis in another isolate', () async {
    final result = await analyzeBytesInBackground(utf8.encode('produk,revenue\nKopi,5000'), 'toko.csv');
    expect(result.ok, isTrue, reason: result.error);
    expect(result.sourceName, 'toko.csv');
    expect(result.total, 5000.0);
  });

  test('analyzeFileInBackground reads the file and names the source', () async {
    final dir = await Directory.systemTemp.createTemp('agent_hq_data_');
    try {
      final file = File('${dir.path}${Platform.pathSeparator}penjualan.csv');
      await file.writeAsString('tanggal;produk;qty;harga\n2026-01-02;Kopi;2;19.500,50\n');
      final result = await analyzeFileInBackground(file.path);
      expect(result.ok, isTrue, reason: result.error);
      expect(result.sourceName, 'penjualan.csv');
      expect(result.total, closeTo(39001.0, 1e-6));
      final missing = await analyzeFileInBackground('${dir.path}${Platform.pathSeparator}tidak_ada.csv');
      expect(missing.error, 'File tidak bisa dibaca. Coba simpan lalu pilih ulang.');
      expect(missing.sourceName, 'tidak_ada.csv');
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
