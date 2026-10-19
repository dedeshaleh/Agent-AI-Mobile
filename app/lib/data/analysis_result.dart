/// Hasil analisis deterministik satu berkas CSV/XLSX.
///
/// Semua angka di sini dihitung oleh kode Dart, bukan oleh LLM. Objek ini
/// adalah satu-satunya sumber KPI untuk agent, meeting, dan laporan.
library;

class ProductTotal {
  const ProductTotal(this.name, this.value);
  final String name;
  final double value;

  Map<String, Object?> toJson() => {'name': name, 'value': value};
  factory ProductTotal.fromJson(Map<String, Object?> json) =>
      ProductTotal(json['name'] as String, (json['value'] as num).toDouble());
}

class PreviewRow {
  const PreviewRow({required this.product, required this.month, required this.value});
  final String product;
  final String month;
  final double value;

  Map<String, Object?> toJson() => {'product': product, 'month': month, 'value': value};
}

/// Kolom yang dikenali. Nilai `-1` berarti kolom tidak ditemukan.
class ColumnMapping {
  const ColumnMapping({
    this.date = -1,
    this.product = -1,
    this.quantity = -1,
    this.price = -1,
    this.revenue = -1,
  });
  final int date;
  final int product;
  final int quantity;
  final int price;
  final int revenue;

  bool get hasRevenue => revenue >= 0;
  bool get hasQuantityAndPrice => quantity >= 0 && price >= 0;

  Map<String, int> toJson() =>
      {'date': date, 'product': product, 'quantity': quantity, 'price': price, 'revenue': revenue};

  factory ColumnMapping.fromJson(Map<String, Object?> json) => ColumnMapping(
        date: (json['date'] as num?)?.toInt() ?? -1,
        product: (json['product'] as num?)?.toInt() ?? -1,
        quantity: (json['quantity'] as num?)?.toInt() ?? -1,
        price: (json['price'] as num?)?.toInt() ?? -1,
        revenue: (json['revenue'] as num?)?.toInt() ?? -1,
      );
}

class AnalysisResult {
  const AnalysisResult({
    required this.ok,
    this.error,
    this.sourceName = '',
    this.headers = const [],
    this.mapping = const ColumnMapping(),
    this.hasDate = false,
    this.rows = 0,
    this.skipped = 0,
    this.total = 0,
    this.average = 0,
    this.months = const {},
    this.products = const [],
    this.preview = const [],
    this.warnings = const [],
  });

  factory AnalysisResult.failure(String error, {List<String> headers = const []}) =>
      AnalysisResult(ok: false, error: error, headers: headers);

  final bool ok;
  final String? error;
  final String sourceName;
  final List<String> headers;
  final ColumnMapping mapping;
  final bool hasDate;

  /// Baris dengan angka omzet valid.
  final int rows;

  /// Baris yang dilewati karena angka tidak valid / kolom kurang.
  final int skipped;
  final double total;
  final double average;

  /// Omzet per periode `YYYY-MM` (atau "Tanpa tanggal"). Urutan tidak dijamin.
  final Map<String, double> months;

  /// Maksimal 5 produk teratas, urut menurun.
  final List<ProductTotal> products;
  final List<PreviewRow> preview;
  final List<String> warnings;

  /// Kunci bulan terurut naik.
  List<String> get sortedMonths => months.keys.toList()..sort();

  AnalysisResult copyWith({String? sourceName}) => AnalysisResult(
        ok: ok,
        error: error,
        sourceName: sourceName ?? this.sourceName,
        headers: headers,
        mapping: mapping,
        hasDate: hasDate,
        rows: rows,
        skipped: skipped,
        total: total,
        average: average,
        months: months,
        products: products,
        preview: preview,
        warnings: warnings,
      );

  /// Ringkasan agregat yang boleh dikirim ke model (lokal maupun cloud).
  /// Tidak pernah berisi baris mentah. Maksimal [maxMonths] bulan terakhir.
  Map<String, Object?> toFacts({int maxMonths = 8}) {
    final keys = sortedMonths;
    final recent = keys.length > maxMonths ? keys.sublist(keys.length - maxMonths) : keys;
    return {
      'source_file': sourceName,
      'valid_rows': rows,
      'skipped_rows': skipped,
      'total_revenue': total,
      'average_per_row': average,
      'has_date': hasDate,
      'top_products': products.map((p) => p.toJson()).toList(),
      'monthly_revenue': {for (final m in recent) m: months[m]},
      'warnings': warnings,
    };
  }

  Map<String, Object?> toJson() => {
        'ok': ok,
        'error': error,
        'source_name': sourceName,
        'headers': headers,
        'mapping': mapping.toJson(),
        'has_date': hasDate,
        'rows': rows,
        'skipped': skipped,
        'total': total,
        'average': average,
        'months': months,
        'products': products.map((p) => p.toJson()).toList(),
        'preview': preview.map((p) => p.toJson()).toList(),
        'warnings': warnings,
      };
}
