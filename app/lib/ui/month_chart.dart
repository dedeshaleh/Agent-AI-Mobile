import 'package:flutter/material.dart';

import 'theme.dart';

/// Grafik batang omzet per bulan, digambar langsung (tanpa paket chart).
class MonthChart extends StatelessWidget {
  const MonthChart({super.key, required this.months, this.color = HqColors.accent});
  final Map<String, double> months;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final keys = months.keys.toList()..sort();
    if (keys.length < 2) {
      return const SizedBox(
        height: 80,
        child: Center(child: Text('Tren bulanan butuh minimal dua periode tanggal.', style: TextStyle(color: HqColors.muted, fontSize: 12))),
      );
    }
    return SizedBox(
      height: 150,
      child: CustomPaint(painter: _Painter(keys, months, color)),
    );
  }
}

class _Painter extends CustomPainter {
  _Painter(this.keys, this.values, this.color);
  final List<String> keys;
  final Map<String, double> values;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const bottom = 22.0;
    final maxValue = keys.map((k) => values[k]!).fold<double>(0, (a, b) => a > b ? a : b);
    if (maxValue <= 0) return;
    final slot = size.width / keys.length;
    final barWidth = slot * 0.6;
    final paint = Paint()..color = color;
    final axis = Paint()
      ..color = HqColors.border
      ..strokeWidth = 1;
    canvas.drawLine(Offset(0, size.height - bottom), Offset(size.width, size.height - bottom), axis);
    for (var i = 0; i < keys.length; i++) {
      final v = values[keys[i]]!;
      final h = (v / maxValue) * (size.height - bottom - 6);
      final x = i * slot + (slot - barWidth) / 2;
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, size.height - bottom - h, barWidth, h),
        const Radius.circular(3),
      );
      canvas.drawRRect(rect, paint..color = i == keys.length - 1 ? color : color.withValues(alpha: 0.55));
      final label = TextPainter(
        text: TextSpan(text: keys[i].length >= 7 ? keys[i].substring(2) : keys[i], style: const TextStyle(fontSize: 9, color: HqColors.muted)),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: slot);
      label.paint(canvas, Offset(i * slot + (slot - label.width) / 2, size.height - bottom + 4));
    }
  }

  @override
  bool shouldRepaint(covariant _Painter old) => old.values != values || old.keys != keys;
}
