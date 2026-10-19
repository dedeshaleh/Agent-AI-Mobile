/// Jawaban dan saran berbasis aturan dari [AnalysisResult], tanpa model AI.
///
/// Port dari `game/scripts/data_advisor.gd`.
library;

import 'dart:math' as math;

import 'analysis_result.dart';

class DataAdvisor {
  DataAdvisor._();

  /// Kata kunci yang bisa dijawab lokal tanpa model (lihat `main.gd`).
  static const List<String> localKeywords = [
    'omzet', 'total', 'revenue', 'pendapatan', 'rata', 'average', 'produk',
    'laku', 'terlaris', 'tertinggi', 'terendah', 'sedikit', 'tren', 'bulan',
    'ringkas', 'summary', 'saran', 'lihat', 'cek',
  ];

  static bool canAnswerLocally(String question) {
    final q = question.toLowerCase();
    return localKeywords.any(q.contains);
  }

  static String suggestions(AnalysisResult r) {
    final tips = <String>[];
    if (r.skipped > 0) {
      tips.add('Cek ${r.skipped} baris yang tidak memiliki angka omzet valid.');
    }
    if (r.products.isNotEmpty && r.total > 0) {
      final share = r.products[0].value / r.total;
      if (share >= 0.6) {
        tips.add('${r.products[0].name} menyumbang ${_fixed(share * 100.0, 0)}% omzet; '
            'periksa risiko ketergantungan stok.');
      }
    }
    final months = r.sortedMonths;
    if (months.length >= 2) {
      final previousKey = months[months.length - 2];
      final latestKey = months.last;
      final previous = r.months[previousKey]!;
      final latest = r.months[latestKey]!;
      if (previous > 0 && latest < previous) {
        tips.add('Omzet $latestKey turun ${_fixed((previous - latest) / previous * 100.0, 0)}% '
            'dari $previousKey; cek perubahan stok, harga, atau promosi.');
      }
    }
    if (!r.hasDate) tips.add('Tambahkan kolom tanggal untuk melihat tren dari waktu ke waktu.');
    tips.add('Laba belum bisa dihitung tanpa kolom modal/HPP dan diskon yang terstruktur.');
    return '• ${tips.join('\n• ')}';
  }

  static String answer(String question, AnalysisResult r) {
    final q = question.toLowerCase();
    final products = r.products;
    final total = r.total;
    bool has(List<String> words) => words.any(q.contains);
    if (has(const ['rata', 'average'])) {
      return 'Rata-rata omzet per baris valid adalah Rp ${formatNumber(r.average)} dari ${r.rows} baris.';
    }
    if (has(const ['total', 'omzet', 'pendapatan', 'revenue'])) {
      return 'Total omzet yang terhitung adalah Rp ${formatNumber(total)} dari ${r.rows} baris valid. '
          'Baris yang dilewati: ${r.skipped}.';
    }
    if (has(const ['rendah', 'sedikit', 'terkecil', 'bottom']) && products.isNotEmpty) {
      final item = products.last;
      return '${item.name} adalah produk dengan omzet terendah di antara produk yang terbaca: '
          'Rp ${formatNumber(item.value)}.';
    }
    if (has(const ['produk', 'laku', 'tertinggi', 'terlaris', 'top']) && products.isNotEmpty) {
      return 'Produk dengan omzet tertinggi adalah ${products[0].name}, '
          'Rp ${formatNumber(products[0].value)}. Total omzet Rp ${formatNumber(total)}.';
    }
    if (has(const ['tren', 'bulan', 'turun', 'naik'])) {
      final months = r.sortedMonths;
      if (months.length >= 2) {
        final first = months.first;
        final last = months.last;
        final start = r.months[first]!;
        final finish = r.months[last]!;
        final change = start != 0 ? (finish - start) / start.abs() * 100.0 : 0.0;
        final direction = change > 0 ? 'naik' : change < 0 ? 'turun' : 'tetap';
        final signed = change < 0 ? _fixed(change, 1) : '+${_fixed(change, 1)}';
        return 'Dari $first ke $last, omzet $direction dari Rp ${formatNumber(start)} '
            'menjadi Rp ${formatNumber(finish)} (perubahan $signed%).';
      }
      return 'Kolom tanggal belum cukup untuk menghitung tren bulanan.';
    }
    if (has(const ['ringkas', 'summary', 'saran', 'cek', 'lihat'])) {
      return 'Ringkasan: ${r.rows} baris valid, total omzet Rp ${formatNumber(total)}.\n${suggestions(r)}';
    }
    return 'Saya menemukan ${r.rows} baris valid dengan total omzet Rp ${formatNumber(total)}. '
        'Tanyakan total, rata-rata, tren bulanan, produk tertinggi/terendah, atau minta ringkasan dan saran.';
  }

  /// `49001.0` → `Rp 49.001`.
  static String formatRupiah(double v) => 'Rp ${formatNumber(v)}';

  /// Pembulatan ke bilangan bulat dengan pemisah ribuan titik: `1234567` → `1.234.567`.
  static String formatNumber(double v) {
    var raw = _fixed(v, 0);
    final negative = raw.startsWith('-');
    if (negative) raw = raw.substring(1);
    final grouped = StringBuffer();
    for (var i = 0; i < raw.length; i++) {
      if (i > 0 && (raw.length - i) % 3 == 0) grouped.write('.');
      grouped.write(raw[i]);
    }
    return negative ? '-$grouped' : grouped.toString();
  }

  // Meniru `%.Nf` Godot (snprintf): tepat di tengah dibulatkan ke genap,
  // berbeda dengan toStringAsFixed yang membulatkan menjauhi nol.
  static String _fixed(double v, int digits) {
    if (v.isNaN || v.isInfinite) return v.toString();
    final scale = math.pow(10, digits).toDouble();
    final scaled = v * scale;
    final floor = scaled.floorToDouble();
    if (scaled - floor == 0.5) {
      final even = floor % 2 == 0 ? floor : floor + 1;
      return (even / scale).toStringAsFixed(digits);
    }
    return v.toStringAsFixed(digits);
  }
}
