/// Parser CSV deterministik dan normalisasi angka gaya Indonesia.
///
/// Port 1:1 dari `game/scripts/csv_analyzer.gd` (bagian parsing).
library;

/// Batas baris data yang diparse (judul tidak dihitung).
const int csvMaxRows = 100000;

/// Memilih pemisah `,` `;` atau tab yang paling sering muncul di baris pertama.
/// Seri dimenangkan oleh kandidat yang lebih dulu (koma).
String detectDelimiter(String text) {
  final newline = text.indexOf('\n');
  final line = newline < 0 ? text : text.substring(0, newline);
  var chosen = ',';
  var maxCount = -1;
  for (final candidate in const [',', ';', '\t']) {
    final count = candidate.allMatches(line).length;
    if (count > maxCount) {
      maxCount = count;
      chosen = candidate;
    }
  }
  return chosen;
}

/// Parse CSV dengan kutip ganda gaya RFC (`""` sebagai escape) dan `\r\n`.
/// Baris kosong menghasilkan satu sel kosong, sama seperti GDScript.
/// Berhenti setelah [csvMaxRows] + 2 baris agar memori tetap terbatas.
List<List<String>> parseCsv(String text, {String? delimiter}) {
  final sep = delimiter ?? detectDelimiter(text);
  final rows = <List<String>>[];
  var row = <String>[];
  final cell = StringBuffer();
  var quoted = false;
  var i = 0;
  final length = text.length;
  while (i < length) {
    final ch = text[i];
    if (ch == '"') {
      if (quoted && i + 1 < length && text[i + 1] == '"') {
        cell.write('"');
        i++;
      } else {
        quoted = !quoted;
      }
    } else if (!quoted && ch == sep) {
      row.add(cell.toString());
      cell.clear();
    } else if (!quoted && (ch == '\n' || ch == '\r')) {
      row.add(cell.toString());
      cell.clear();
      rows.add(row);
      if (rows.length > csvMaxRows + 1) return rows;
      row = <String>[];
      if (ch == '\r' && i + 1 < length && text[i + 1] == '\n') i++;
    } else {
      cell.write(ch);
    }
    i++;
  }
  if (cell.isNotEmpty || row.isNotEmpty) {
    row.add(cell.toString());
    rows.add(row);
  }
  return rows;
}

/// Membersihkan teks angka Indonesia menjadi notasi titik desimal.
///
/// `Rp 19.500,50` → `19500.50`, `10.000` → `10000`, `1,5` → `1.5`,
/// `1,500` → `1500`. Hasil belum tentu angka valid; cek dengan [isValidNumber].
String normalizeNumber(String value) {
  var s = value.trim().replaceAll('Rp', '').replaceAll('IDR', '').replaceAll(' ', '');
  final hasComma = s.contains(',');
  final hasDot = s.contains('.');
  if (hasComma && hasDot) {
    if (s.lastIndexOf(',') > s.lastIndexOf('.')) {
      s = s.replaceAll('.', '').replaceAll(',', '.');
    } else {
      s = s.replaceAll(',', '');
    }
  } else if (hasDot) {
    if (s.substring(s.lastIndexOf('.') + 1).length == 3) s = s.replaceAll('.', '');
  } else if (hasComma) {
    final fraction = s.substring(s.lastIndexOf(',') + 1);
    s = fraction.length == 3 ? s.replaceAll(',', '') : s.replaceAll(',', '.');
  }
  return s;
}

// Meniru String.is_valid_float milik Godot: tanda opsional, digit dengan
// titik opsional, eksponen `e` huruf kecil yang boleh tanpa digit.
final RegExp _godotFloat = RegExp(r'^[+-]?(\d+\.?\d*|\.\d+)(e[+-]?\d*)?$');

/// True bila [text] lolos `String.is_valid_float` Godot (tanpa normalisasi).
bool isGodotFloat(String text) => _godotFloat.hasMatch(text);

/// Setara `String.to_float` Godot untuk teks yang lolos [isGodotFloat];
/// `null` bila tidak lolos.
double? parseGodotFloat(String text) {
  if (!_godotFloat.hasMatch(text)) return null;
  var s = text;
  final e = s.indexOf('e');
  if (e >= 0 && !RegExp(r'\d').hasMatch(s.substring(e + 1))) s = s.substring(0, e);
  s = s.replaceFirstMapped(RegExp(r'^([+-]?)\.'), (m) => '${m[1]}0.');
  if (s.endsWith('.')) s = '${s}0';
  s = s.replaceFirst('.e', '.0e');
  return double.tryParse(s);
}

/// True bila [value] (setelah normalisasi) adalah angka yang diterima GDScript.
bool isValidNumber(String value) => isGodotFloat(normalizeNumber(value));

/// Angka dari teks Indonesia, atau `null` bila tidak valid.
double? parseIndonesianNumber(String value) => parseGodotFloat(normalizeNumber(value));
