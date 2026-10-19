import 'package:flutter/material.dart';

/// Palet gelap yang sama dengan demo Godot agar transisi terasa konsisten.
abstract final class HqColors {
  static const background = Color(0xFF0B1420);
  static const panel = Color(0xFF101D2D);
  static const panelAlt = Color(0xFF162638);
  static const border = Color(0xFF22374D);
  static const text = Color(0xFFD1DFEF);
  static const muted = Color(0xFF8097AF);
  static const accent = Color(0xFF62DFB0);
  static const warning = Color(0xFFF6B95C);
  static const danger = Color(0xFFFF7A7A);
  static const local = Color(0xFF62DFB0);
  static const cloud = Color(0xFF48A9FF);
}

ThemeData buildHqTheme() {
  final base = ThemeData.dark(useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: HqColors.background,
    colorScheme: base.colorScheme.copyWith(
      primary: HqColors.accent,
      secondary: HqColors.cloud,
      surface: HqColors.panel,
      error: HqColors.danger,
    ),
    cardTheme: const CardThemeData(
      color: HqColors.panel,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(14)),
        side: BorderSide(color: HqColors.border),
      ),
    ),
    dialogTheme: const DialogThemeData(backgroundColor: HqColors.panel),
    bottomSheetTheme: const BottomSheetThemeData(backgroundColor: HqColors.panel),
    inputDecorationTheme: const InputDecorationTheme(
      border: OutlineInputBorder(),
      isDense: true,
      filled: true,
      fillColor: HqColors.panelAlt,
    ),
    textTheme: base.textTheme.apply(bodyColor: HqColors.text, displayColor: HqColors.text),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(minimumSize: const Size(0, 44), textStyle: const TextStyle(fontWeight: FontWeight.w600)),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44), side: const BorderSide(color: HqColors.border)),
    ),
  );
}

/// Lencana sumber jawaban: lokal (📱) atau nama provider cloud (☁).
class SourceBadge extends StatelessWidget {
  const SourceBadge({super.key, required this.providerId, this.providerName});
  final String? providerId;
  final String? providerName;

  @override
  Widget build(BuildContext context) {
    final isLocal = providerId == null || providerId == 'local-llama';
    final label = providerId == null
        ? 'Template lokal'
        : isLocal
            ? 'Model lokal'
            : 'Cloud: ${providerName ?? providerId}';
    final color = providerId == null ? HqColors.muted : (isLocal ? HqColors.local : HqColors.cloud);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.6)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(isLocal ? Icons.phone_android : Icons.cloud_outlined, size: 13, color: color),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(fontSize: 11, color: color)),
        ],
      ),
    );
  }
}
