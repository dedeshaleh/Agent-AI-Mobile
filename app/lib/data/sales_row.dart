/// Satu baris penjualan yang sudah dinormalisasi; bentuk yang disimpan ke SQLite.
library;

class SalesRow {
  const SalesRow({
    required this.rowIndex,
    required this.period,
    this.date,
    required this.product,
    this.qty,
    this.price,
    required this.revenue,
  });

  /// Nomor baris di berkas sumber (1 = baris data pertama setelah judul).
  final int rowIndex;

  /// `YYYY-MM` (7 karakter pertama sel tanggal) atau `Tanpa tanggal`.
  final String period;

  /// Isi sel tanggal apa adanya; `null` bila kolom/sel tanggal kosong.
  final String? date;
  final String product;
  final double? qty;
  final double? price;
  final double revenue;

  Map<String, Object?> toMap() => {
        'row_index': rowIndex,
        'period': period,
        'date': date,
        'product': product,
        'qty': qty,
        'price': price,
        'revenue': revenue,
      };

  factory SalesRow.fromMap(Map<String, Object?> map) => SalesRow(
        rowIndex: map['row_index'] as int,
        period: map['period'] as String,
        date: map['date'] as String?,
        product: map['product'] as String,
        qty: (map['qty'] as num?)?.toDouble(),
        price: (map['price'] as num?)?.toDouble(),
        revenue: (map['revenue'] as num).toDouble(),
      );
}
