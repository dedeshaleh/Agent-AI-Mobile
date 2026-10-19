/// Pintu masuk analisis dari UI: semua parsing berjalan di isolate terpisah.
library;

import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import 'analysis_result.dart';
import 'data_analyzer.dart';

/// Membaca dan menganalisis berkas di isolate latar belakang.
Future<AnalysisResult> analyzeFileInBackground(String path) {
  final name = p.basename(path);
  return Isolate.run(() async {
    final file = File(path);
    final int size;
    try {
      size = await file.length();
    } catch (_) {
      return AnalysisResult.failure('File tidak bisa dibaca. Coba simpan lalu pilih ulang.')
          .copyWith(sourceName: name);
    }
    if (size > analyzerMaxBytes) {
      return AnalysisResult.failure('Ukuran file maksimum 20 MB.').copyWith(sourceName: name);
    }
    final List<int> bytes;
    try {
      bytes = await file.readAsBytes();
    } catch (_) {
      return AnalysisResult.failure('File tidak bisa dibaca. Coba simpan lalu pilih ulang.')
          .copyWith(sourceName: name);
    }
    return analyzeBytes(bytes, name).copyWith(sourceName: name);
  });
}

/// Menganalisis isi berkas yang sudah ada di memori (mis. dari file picker).
Future<AnalysisResult> analyzeBytesInBackground(List<int> bytes, String name) =>
    Isolate.run(() => analyzeBytes(bytes, name).copyWith(sourceName: name));
