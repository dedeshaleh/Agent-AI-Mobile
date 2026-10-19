/// Pembaca XLSX minimal: lembar pertama saja, tanpa rumus.
///
/// Port dari `game/scripts/xlsx_reader.gd`. Memakai parser event `xml`
/// agar memori tetap terbatas pada ukuran bagian XML, bukan pohon DOM.
library;

import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:xml/xml_events.dart';

import 'csv_parser.dart' show parseGodotFloat;

const int xlsxMaxXmlBytes = 20 * 1024 * 1024;
const int xlsxMaxRows = 100001;
const int xlsxMaxColumns = 512;

class XlsxReadResult {
  const XlsxReadResult.ok(this.rows)
      : ok = true,
        error = null;
  const XlsxReadResult.failure(this.error)
      : ok = false,
        rows = const [];
  final bool ok;
  final String? error;
  final List<List<String>> rows;
}

/// Membaca semua sel lembar pertama sebagai teks, grid persegi (sel kosong = "").
XlsxReadResult readXlsxRows(List<int> bytes) {
  final Archive zip;
  try {
    zip = ZipDecoder().decodeBytes(bytes);
  } catch (_) {
    return const XlsxReadResult.failure('File XLSX tidak valid atau tidak bisa dibuka.');
  }
  if (zip.isEmpty) {
    return const XlsxReadResult.failure('File XLSX tidak valid atau tidak bisa dibuka.');
  }
  final workbook = zip.findFile('xl/workbook.xml');
  final rels = zip.findFile('xl/_rels/workbook.xml.rels');
  if (workbook == null || rels == null) {
    return const XlsxReadResult.failure('Struktur XLSX tidak lengkap. Simpan ulang sebagai .xlsx.');
  }
  final sharedStringsFile = zip.findFile('xl/sharedStrings.xml');
  final stringsBytes = sharedStringsFile?.content ?? const <int>[];
  final workbookBytes = workbook.content;
  final relsBytes = rels.content;
  if (stringsBytes.length + workbookBytes.length + relsBytes.length > xlsxMaxXmlBytes) {
    return const XlsxReadResult.failure('Isi XML workbook terlalu besar (batas 20 MB).');
  }
  final strings = _readSharedStrings(_text(stringsBytes));
  final target = _firstSheet(_text(workbookBytes), _text(relsBytes));
  final sheet = target.isEmpty ? null : zip.findFile(target);
  if (sheet == null) {
    return const XlsxReadResult.failure('Lembar pertama workbook tidak ditemukan.');
  }
  var dateStyles = const <bool>[];
  final stylesFile = zip.findFile('xl/styles.xml');
  if (stylesFile != null) {
    final styleBytes = stylesFile.content;
    if (styleBytes.length > xlsxMaxXmlBytes) {
      return const XlsxReadResult.failure('Format workbook terlalu besar.');
    }
    dateStyles = _readDateStyles(_text(styleBytes));
  }
  final sheetBytes = sheet.content;
  if (sheetBytes.length > xlsxMaxXmlBytes) {
    return const XlsxReadResult.failure('Lembar pertama melebihi batas 20 MB.');
  }
  return _readSheet(_text(sheetBytes), strings, dateStyles);
}

String _text(List<int> bytes) => bytes.isEmpty ? '' : utf8.decode(bytes, allowMalformed: true);

String _local(String name) {
  final colon = name.lastIndexOf(':');
  return colon < 0 ? name : name.substring(colon + 1);
}

String? _attr(XmlStartElementEvent element, String name) {
  for (final attribute in element.attributes) {
    if (attribute.name == name) return attribute.value;
  }
  return null;
}

List<String> _readSharedStrings(String xml) {
  final values = <String>[];
  var insideSi = false;
  var insideT = false;
  final current = StringBuffer();
  for (final event in parseEvents(xml)) {
    if (event is XmlStartElementEvent) {
      final name = _local(event.name);
      if (name == 'si') {
        insideSi = true;
        current.clear();
      } else if (name == 't' && insideSi) {
        insideT = !event.isSelfClosing;
      }
    } else if (event is XmlTextEvent) {
      if (insideT) current.write(event.value);
    } else if (event is XmlCDATAEvent) {
      if (insideT) current.write(event.value);
    } else if (event is XmlEndElementEvent) {
      final name = _local(event.name);
      if (name == 't') {
        insideT = false;
      } else if (name == 'si') {
        values.add(current.toString());
        insideSi = false;
      }
    }
  }
  return values;
}

String _firstSheet(String workbookXml, String relsXml) {
  var relationshipId = '';
  for (final event in parseEvents(workbookXml)) {
    if (event is XmlStartElementEvent && _local(event.name) == 'sheet') {
      relationshipId = _attr(event, 'r:id') ?? _attr(event, 'id') ?? '';
      if (relationshipId.isEmpty) {
        for (final attribute in event.attributes) {
          if (attribute.localName == 'id') relationshipId = attribute.value;
        }
      }
      break;
    }
  }
  if (relationshipId.isEmpty) return '';
  for (final event in parseEvents(relsXml)) {
    if (event is! XmlStartElementEvent || _local(event.name) != 'Relationship') continue;
    if ((_attr(event, 'Id') ?? '') != relationshipId) continue;
    var target = _attr(event, 'Target') ?? '';
    if (target.startsWith('/')) target = target.substring(1);
    if (target.startsWith('xl/')) return target;
    if (target.startsWith('../')) target = target.substring(3);
    return 'xl/$target';
  }
  return '';
}

const _builtinDateFormats = {14, 15, 16, 17, 18, 19, 20, 21, 22, 45, 46, 47};

/// Satu flag per entri `cellXfs`: true bila gaya tersebut menampilkan tanggal.
List<bool> _readDateStyles(String xml) {
  final customIds = <int>{};
  final formats = <bool>[];
  var inXfs = false;
  for (final event in parseEvents(xml)) {
    if (event is XmlStartElementEvent) {
      final name = _local(event.name);
      if (name == 'numFmt') {
        final fmt = (_attr(event, 'formatCode') ?? '').toLowerCase();
        if (fmt.contains('y') || fmt.contains('d')) {
          customIds.add(int.tryParse(_attr(event, 'numFmtId') ?? '') ?? -1);
        }
      } else if (name == 'cellXfs') {
        inXfs = !event.isSelfClosing;
      } else if (name == 'xf' && inXfs) {
        final numId = int.tryParse(_attr(event, 'numFmtId') ?? '') ?? 0;
        formats.add(_builtinDateFormats.contains(numId) || customIds.contains(numId));
      }
    } else if (event is XmlEndElementEvent && _local(event.name) == 'cellXfs') {
      inXfs = false;
    }
  }
  return formats;
}

final RegExp _validInt = RegExp(r'^[+-]?\d+$');

XlsxReadResult _readSheet(String xml, List<String> strings, List<bool> dateStyles) {
  final table = <int, Map<int, String>>{};
  var maxRow = -1;
  var maxCol = -1;
  var cellRef = '';
  var cellType = '';
  var styleIndex = 0;
  final valueText = StringBuffer();
  final inlineText = StringBuffer();
  var readingV = false;
  var readingT = false;
  for (final event in parseEvents(xml)) {
    if (event is XmlStartElementEvent) {
      final name = _local(event.name);
      if (name == 'c') {
        cellRef = _attr(event, 'r') ?? '';
        cellType = _attr(event, 't') ?? '';
        styleIndex = int.tryParse(_attr(event, 's') ?? '') ?? 0;
        valueText.clear();
        inlineText.clear();
      } else if (name == 'v') {
        readingV = !event.isSelfClosing;
      } else if (name == 't' && cellType == 'inlineStr') {
        readingT = !event.isSelfClosing;
      }
    } else if (event is XmlTextEvent || event is XmlCDATAEvent) {
      final data = event is XmlTextEvent ? event.value : (event as XmlCDATAEvent).value;
      if (readingV) {
        valueText.write(data);
      } else if (readingT) {
        inlineText.write(data);
      }
    } else if (event is XmlEndElementEvent) {
      final name = _local(event.name);
      if (name == 'v') {
        readingV = false;
      } else if (name == 't') {
        readingT = false;
      } else if (name == 'c') {
        final address = parseCellAddress(cellRef);
        final r = address.$1;
        final c = address.$2;
        if (r >= 0 && r < xlsxMaxRows && c >= 0 && c < xlsxMaxColumns) {
          final raw = valueText.toString();
          var value = raw;
          if (cellType == 's' && _validInt.hasMatch(raw)) {
            final index = int.parse(raw);
            value = index >= 0 && index < strings.length ? strings[index] : '';
          } else if (cellType == 'inlineStr') {
            value = inlineText.toString();
          } else if (_isDateStyle(dateStyles, styleIndex)) {
            final serial = parseGodotFloat(raw);
            if (serial != null) value = excelSerialToDate(serial);
          }
          (table[r] ??= <int, String>{})[c] = value;
          if (r > maxRow) maxRow = r;
          if (c > maxCol) maxCol = c;
        }
      }
    }
  }
  if (table.isEmpty) {
    return const XlsxReadResult.failure('Worksheet tidak memiliki sel dekripsi yang bisa dibaca.');
  }
  final rows = <List<String>>[];
  for (var r = 0; r <= maxRow; r++) {
    final source = table[r];
    rows.add(List<String>.generate(maxCol + 1, (c) => source?[c] ?? ''));
  }
  return XlsxReadResult.ok(rows);
}

/// `B3` → (baris 2, kolom 1), berbasis nol. `(-1, -1)` bila tidak valid.
(int, int) parseCellAddress(String reference) {
  var col = 0;
  var rowStart = -1;
  for (var i = 0; i < reference.length; i++) {
    final code = reference.codeUnitAt(i);
    if (code >= 65 && code <= 90) {
      col = col * 26 + code - 64;
    } else if (code >= 97 && code <= 122) {
      col = col * 26 + code - 96;
    } else {
      rowStart = i;
      break;
    }
  }
  if (rowStart < 0) return (-1, -1);
  final digits = RegExp(r'^[+-]?\d+').firstMatch(reference.substring(rowStart))?.group(0);
  final rowNum = digits == null ? 0 : (int.tryParse(digits) ?? 0);
  return (rowNum - 1, col - 1);
}

bool _isDateStyle(List<bool> styles, int index) =>
    index >= 0 && index < styles.length && styles[index];

/// Serial Excel (1900-based, 25569 = 1970-01-01) → `YYYY-MM-DD` UTC.
String excelSerialToDate(double serial) {
  final seconds = ((serial - 25569.0) * 86400.0).truncate();
  final date = DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
  final year = date.year.toString().padLeft(4, '0');
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');
  return '$year-$month-$day';
}
