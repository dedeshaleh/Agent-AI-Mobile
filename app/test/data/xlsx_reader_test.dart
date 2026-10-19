import 'package:agent_hq/data/data_analyzer.dart';
import 'package:agent_hq/data/xlsx_reader.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

const _sharedStrings =
    '<sst><si><t>tanggal</t></si><si><t>produk</t></si><si><t>qty</t></si><si><t>harga</t></si><si><t>2026-01-02</t></si><si><t>Kopi</t></si><si><t>Teh</t></si></sst>';
const _workbook =
    '<workbook xmlns:r="urn:r"><sheets><sheet name="Sales" sheetId="1" r:id="rId1"/></sheets></workbook>';
const _rels = '<Relationships><Relationship Id="rId1" Target="worksheets/sheet1.xml"/></Relationships>';
const _styles = '<styleSheet><cellXfs count="1"><xf numFmtId="0"/></cellXfs></styleSheet>';
const _sheet =
    '<worksheet><sheetData><row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c><c r="C1" t="s"><v>2</v></c><c r="D1" t="s"><v>3</v></c></row><row r="2"><c r="A2" t="s"><v>4</v></c><c r="B2" t="s"><v>5</v></c><c r="C2"><v>2</v></c><c r="D2"><v>25000</v></c></row><row r="3"><c r="A3" t="s"><v>4</v></c><c r="B3" t="s"><v>6</v></c><c r="C3"><v>1</v></c><c r="D3"><v>10000</v></c></row></sheetData></worksheet>';

List<int> buildXlsx(Map<String, String> parts) {
  final archive = Archive();
  parts.forEach((name, content) => archive.addFile(ArchiveFile.string(name, content)));
  return ZipEncoder().encode(archive);
}

Map<String, String> fixtureParts() => {
      'xl/sharedStrings.xml': _sharedStrings,
      'xl/workbook.xml': _workbook,
      'xl/_rels/workbook.xml.rels': _rels,
      'xl/styles.xml': _styles,
      'xl/worksheets/sheet1.xml': _sheet,
    };

void main() {
  test('run_tests.gd fixture: shared strings and numeric cells give total 60000', () {
    final bytes = buildXlsx(fixtureParts());
    final read = readXlsxRows(bytes);
    expect(read.ok, isTrue, reason: read.error);
    expect(read.rows, [
      ['tanggal', 'produk', 'qty', 'harga'],
      ['2026-01-02', 'Kopi', '2', '25000'],
      ['2026-01-02', 'Teh', '1', '10000'],
    ]);
    final result = analyzeBytes(bytes, 'phase2_test.xlsx');
    expect(result.ok, isTrue, reason: result.error);
    expect(result.total, closeTo(60000.0, 1e-6));
    expect(result.rows, 2);
    expect(result.products.first.name, 'Kopi');
  });

  test('invalid zip', () {
    expect(readXlsxRows([0, 1, 2]).error, 'File XLSX tidak valid atau tidak bisa dibuka.');
  });

  test('missing workbook parts', () {
    final parts = fixtureParts()..remove('xl/_rels/workbook.xml.rels');
    expect(readXlsxRows(buildXlsx(parts)).error, 'Struktur XLSX tidak lengkap. Simpan ulang sebagai .xlsx.');
  });

  test('missing sheet target', () {
    final parts = fixtureParts()..remove('xl/worksheets/sheet1.xml');
    expect(readXlsxRows(buildXlsx(parts)).error, 'Lembar pertama workbook tidak ditemukan.');
  });

  test('first sheet is chosen even when relationships are out of order', () {
    final parts = fixtureParts()
      ..['xl/workbook.xml'] =
          '<workbook xmlns:r="urn:r"><sheets><sheet name="A" sheetId="1" r:id="rId2"/><sheet name="B" sheetId="2" r:id="rId1"/></sheets></workbook>'
      ..['xl/_rels/workbook.xml.rels'] =
          '<Relationships><Relationship Id="rId1" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Target="/xl/worksheets/sheet2.xml"/></Relationships>'
      ..['xl/worksheets/sheet2.xml'] =
          '<worksheet><sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>revenue</t></is></c></row><row r="2"><c r="A2"><v>7</v></c></row></sheetData></worksheet>';
    final read = readXlsxRows(buildXlsx(parts));
    expect(read.rows, [
      ['revenue'],
      ['7'],
    ]);
  });

  test('empty worksheet', () {
    final parts = fixtureParts()..['xl/worksheets/sheet1.xml'] = '<worksheet><sheetData/></worksheet>';
    expect(readXlsxRows(buildXlsx(parts)).error, 'Worksheet tidak memiliki sel dekripsi yang bisa dibaca.');
  });

  test('date styles: builtin, custom numFmt and non-date cells', () {
    final parts = fixtureParts()
      ..remove('xl/sharedStrings.xml')
      ..['xl/styles.xml'] =
          '<styleSheet><numFmts><numFmt numFmtId="164" formatCode="dd/mm/yyyy"/><numFmt numFmtId="165" formatCode="#,##0"/></numFmts><cellXfs count="4"><xf numFmtId="0"/><xf numFmtId="14"/><xf numFmtId="164"/><xf numFmtId="165"/></cellXfs></styleSheet>'
      ..['xl/worksheets/sheet1.xml'] =
          '<worksheet><sheetData><row r="1"><c r="A1" s="1"><v>25569</v></c><c r="B1" s="2"><v>46023.5</v></c><c r="C1" s="3"><v>46023</v></c><c r="D1" s="1" t="s"><v>abc</v></c><c r="E1" s="9"><v>1</v></c></row></sheetData></worksheet>';
    final read = readXlsxRows(buildXlsx(parts));
    expect(read.rows, [
      ['1970-01-01', '2026-01-01', '46023', 'abc', '1'],
    ]);
  });

  test('gaps, sparse rows and entity decoding produce a rectangular grid', () {
    final parts = fixtureParts()
      ..['xl/sharedStrings.xml'] = '<sst><si><t>A &amp; B</t></si><si><r><t>ri</t></r><r><t>ch</t></r></si></sst>'
      ..['xl/worksheets/sheet1.xml'] =
          '<worksheet><sheetData><row r="1"><c r="A1" t="s"><v>0</v></c><c r="C1" t="s"><v>1</v></c></row><row r="3"><c r="B3"><v>5</v></c><c r="D3" t="s"><v>99</v></c><c r="E3"/></row></sheetData></worksheet>';
    final read = readXlsxRows(buildXlsx(parts));
    expect(read.rows, [
      ['A & B', '', 'rich', ''],
      ['', '', '', ''],
      ['', '5', '', ''],
    ]);
  });

  test('cells beyond row/column limits are ignored', () {
    final parts = fixtureParts()
      ..['xl/worksheets/sheet1.xml'] =
          '<worksheet><sheetData><row r="1"><c r="A1"><v>1</v></c><c r="SS1"><v>2</v></c><c r="A100002"><v>3</v></c></row></sheetData></worksheet>';
    final read = readXlsxRows(buildXlsx(parts));
    expect(read.rows, [
      ['1'],
    ]);
  });

  test('parseCellAddress', () {
    expect(parseCellAddress('A1'), (0, 0));
    expect(parseCellAddress('b3'), (2, 1));
    expect(parseCellAddress('AA10'), (9, 26));
    expect(parseCellAddress('ZZ1'), (0, 701));
    expect(parseCellAddress('A'), (-1, -1));
    expect(parseCellAddress(''), (-1, -1));
  });

  test('excelSerialToDate', () {
    expect(excelSerialToDate(25569), '1970-01-01');
    expect(excelSerialToDate(25569.9), '1970-01-01');
    expect(excelSerialToDate(46023), '2026-01-01');
    expect(excelSerialToDate(2), '1900-01-01');
  });
}
