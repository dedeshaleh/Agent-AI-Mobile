import 'package:agent_hq/data/analysis_result.dart';
import 'package:agent_hq/data/data_advisor.dart';
import 'package:agent_hq/data/data_analyzer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final csv = analyzeCsvText('tanggal;produk;qty;harga\n2026-01-02;Kopi;2;19.500,50\n2026-02-01;"Teh, hijau";1;10.000');
  final messy = analyzeCsvText('product,revenue\nKopi,not-a-number\nTeh,5000');

  group('run_tests.gd expectations', () {
    test('answers top-product question from parsed facts', () {
      expect(DataAdvisor.answer('produk terlaris', csv), contains('Kopi'));
    });
    test('suggests reviewing invalid rows', () {
      expect(DataAdvisor.suggestions(messy), contains('baris'));
    });
  });

  group('formatNumber / formatRupiah', () {
    test('groups thousands with dots and rounds to integer', () {
      expect(DataAdvisor.formatNumber(0), '0');
      expect(DataAdvisor.formatNumber(999), '999');
      expect(DataAdvisor.formatNumber(1000), '1.000');
      expect(DataAdvisor.formatNumber(49001.0), '49.001');
      expect(DataAdvisor.formatNumber(1234567.49), '1.234.567');
      expect(DataAdvisor.formatNumber(24500.5), '24.500', reason: 'snprintf ties go to even');
      expect(DataAdvisor.formatNumber(24501.5), '24.502');
      expect(DataAdvisor.formatNumber(24500.51), '24.501');
      expect(DataAdvisor.formatNumber(-1234), '-1.234');
      expect(DataAdvisor.formatNumber(-123), '-123');
    });
    test('formatRupiah prefixes Rp', () {
      expect(DataAdvisor.formatRupiah(49001), 'Rp 49.001');
    });
  });

  group('answer', () {
    test('average', () {
      expect(DataAdvisor.answer('Berapa rata-rata?', csv),
          'Rata-rata omzet per baris valid adalah Rp 24.500 dari 2 baris.');
    });
    test('total', () {
      expect(DataAdvisor.answer('total omzet', messy),
          'Total omzet yang terhitung adalah Rp 5.000 dari 1 baris valid. Baris yang dilewati: 1.');
    });
    test('lowest product', () {
      expect(DataAdvisor.answer('produk terendah', csv),
          'Teh, hijau adalah produk dengan omzet terendah di antara produk yang terbaca: Rp 10.000.');
    });
    test('top product', () {
      expect(DataAdvisor.answer('produk terlaris', csv),
          'Produk dengan omzet tertinggi adalah Kopi, Rp 39.001. Total omzet Rp 49.001.');
    });
    test('trend with two months', () {
      expect(DataAdvisor.answer('tren bulanan', csv),
          'Dari 2026-01 ke 2026-02, omzet turun dari Rp 39.001 menjadi Rp 10.000 (perubahan -74.4%).');
    });
    test('trend rising and flat use signed percentage', () {
      final up = analyzeRows([
        ['bulan', 'revenue'],
        ['2026-01', '100'],
        ['2026-02', '150'],
      ]);
      expect(DataAdvisor.answer('tren', up), contains('naik'));
      expect(DataAdvisor.answer('tren', up), contains('(perubahan +50.0%)'));
      final flat = analyzeRows([
        ['bulan', 'revenue'],
        ['2026-01', '100'],
        ['2026-02', '100'],
      ]);
      expect(DataAdvisor.answer('tren', flat), contains('omzet tetap'));
      expect(DataAdvisor.answer('tren', flat), contains('+0.0%'));
    });
    test('trend without enough months', () {
      expect(DataAdvisor.answer('bagaimana tren?', messy), 'Kolom tanggal belum cukup untuk menghitung tren bulanan.');
    });
    test('summary includes suggestions', () {
      final text = DataAdvisor.answer('ringkas', messy);
      expect(text, startsWith('Ringkasan: 1 baris valid, total omzet Rp 5.000.\n• '));
      expect(text, contains('Cek 1 baris'));
    });
    test('fallback', () {
      expect(DataAdvisor.answer('halo', messy),
          'Saya menemukan 1 baris valid dengan total omzet Rp 5.000. Tanyakan total, rata-rata, tren bulanan, produk tertinggi/terendah, atau minta ringkasan dan saran.');
    });
    test('keyword priority: rata beats total', () {
      expect(DataAdvisor.answer('rata-rata total', csv), startsWith('Rata-rata'));
    });
  });

  group('suggestions', () {
    test('dominant product, declining month and profit note', () {
      final tips = DataAdvisor.suggestions(csv);
      expect(tips, contains('• Kopi menyumbang 80% omzet; periksa risiko ketergantungan stok.'));
      expect(tips, contains('• Omzet 2026-02 turun 74% dari 2026-01; cek perubahan stok, harga, atau promosi.'));
      expect(tips, endsWith('• Laba belum bisa dihitung tanpa kolom modal/HPP dan diskon yang terstruktur.'));
      expect(tips, isNot(contains('Tambahkan kolom tanggal')));
    });
    test('no date column tip', () {
      final tips = DataAdvisor.suggestions(messy);
      expect(tips, '• Cek 1 baris yang tidak memiliki angka omzet valid.\n'
          '• Teh menyumbang 100% omzet; periksa risiko ketergantungan stok.\n'
          '• Tambahkan kolom tanggal untuk melihat tren dari waktu ke waktu.\n'
          '• Laba belum bisa dihitung tanpa kolom modal/HPP dan diskon yang terstruktur.');
    });
    test('works on an empty result', () {
      expect(DataAdvisor.suggestions(const AnalysisResult(ok: false)),
          '• Tambahkan kolom tanggal untuk melihat tren dari waktu ke waktu.\n'
          '• Laba belum bisa dihitung tanpa kolom modal/HPP dan diskon yang terstruktur.');
    });
  });

  group('canAnswerLocally', () {
    test('matches the main.gd keyword set', () {
      for (final word in DataAdvisor.localKeywords) {
        expect(DataAdvisor.canAnswerLocally('Tolong $word dong'), isTrue, reason: word);
      }
      expect(DataAdvisor.localKeywords, containsAll([
        'omzet', 'total', 'revenue', 'pendapatan', 'rata', 'average', 'produk', 'laku', 'terlaris',
        'tertinggi', 'terendah', 'sedikit', 'tren', 'bulan', 'ringkas', 'summary', 'saran', 'lihat', 'cek',
      ]));
      expect(DataAdvisor.canAnswerLocally('PRODUK TERLARIS'), isTrue);
      expect(DataAdvisor.canAnswerLocally('buatkan strategi marketing'), isFalse);
    });
  });
}
