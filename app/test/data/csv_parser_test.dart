import 'package:agent_hq/data/csv_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('detectDelimiter', () {
    test('picks the most frequent candidate on the first line', () {
      expect(detectDelimiter('a;b;c\n1,2;3'), ';');
      expect(detectDelimiter('a\tb\tc\n'), '\t');
      expect(detectDelimiter('a,b\n'), ',');
    });
    test('ties and no delimiter fall back to comma', () {
      expect(detectDelimiter('a;b,c'), ',');
      expect(detectDelimiter('header'), ',');
      expect(detectDelimiter(''), ',');
    });
  });

  group('parseCsv', () {
    test('handles quotes, escaped quotes and CRLF', () {
      final rows = parseCsv('a,b\r\n"x, y","say ""hi"""\r\n');
      expect(rows, [
        ['a', 'b'],
        ['x, y', 'say "hi"'],
      ]);
    });
    test('keeps blank lines as a single empty cell like GDScript', () {
      expect(parseCsv('a\n\nb'), [
        ['a'],
        [''],
        ['b'],
      ]);
    });
    test('last row without trailing newline is kept', () {
      expect(parseCsv('a;b\n1;2', delimiter: ';'), [
        ['a', 'b'],
        ['1', '2'],
      ]);
    });
    test('quoted newline stays inside the cell', () {
      expect(parseCsv('"multi\nline",x'), [
        ['multi\nline', 'x'],
      ]);
    });
    test('semicolon fixture from run_tests.gd', () {
      final rows = parseCsv('tanggal;produk;qty;harga\n2026-01-02;Kopi;2;19.500,50\n2026-02-01;"Teh, hijau";1;10.000');
      expect(rows[1], ['2026-01-02', 'Kopi', '2', '19.500,50']);
      expect(rows[2], ['2026-02-01', 'Teh, hijau', '1', '10.000']);
    });
  });

  group('normalizeNumber / parseIndonesianNumber', () {
    const table = <String, double?>{
      '19.500,50': 19500.50,
      '10.000': 10000,
      '1,5': 1.5,
      '1,500': 1500,
      'Rp 25.000': 25000,
      'IDR 1.250.000': 1250000,
      'Rp1.234,56': 1234.56,
      '1,234.56': 1234.56,
      '2,000,000': 2000000,
      '19.5': 19.5,
      '0,75': 0.75,
      '-3': -3,
      '+4.0': 4,
      '1e3': 1000,
      '5.': 5,
      '.5': 0.5,
      '': null,
      'not-a-number': null,
      'Rp': null,
      '1.234.5': null,
      '12abc': null,
      'nan': null,
      'inf': null,
    };
    table.forEach((input, expected) {
      test('"$input" -> $expected', () {
        expect(parseIndonesianNumber(input), expected);
        expect(isValidNumber(input), expected != null);
      });
    });
    test('normalizeNumber strips currency and spaces only', () {
      expect(normalizeNumber(' Rp 19.500,50 '), '19500.50');
      expect(normalizeNumber('10.000'), '10000');
      expect(normalizeNumber('1,5'), '1.5');
      expect(normalizeNumber('1,500'), '1500');
      expect(normalizeNumber('abc'), 'abc');
    });
  });
}
