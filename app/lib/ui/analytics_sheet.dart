import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../data/data_advisor.dart';
import 'month_chart.dart';
import 'theme.dart';

/// Dashboard hasil analisis + kotak tanya-jawab (Fase 2 dari versi Godot).
class AnalyticsSheet extends StatefulWidget {
  const AnalyticsSheet({super.key, required this.controller, required this.onStartMission});
  final AppController controller;
  final VoidCallback onStartMission;

  @override
  State<AnalyticsSheet> createState() => _AnalyticsSheetState();
}

class _AnalyticsSheetState extends State<AnalyticsSheet> {
  final _question = TextEditingController();

  @override
  void dispose() {
    _question.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return AnimatedBuilder(
      animation: c,
      builder: (context, _) {
        final r = c.analysis;
        if (r == null || !r.ok) return const SizedBox(height: 120, child: Center(child: Text('Belum ada data yang dianalisis.')));
        final size = MediaQuery.sizeOf(context);
        return SizedBox(
          height: size.height * 0.92,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
                child: Row(
                  children: [
                    Expanded(child: Text(r.sourceName, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700), overflow: TextOverflow.ellipsis)),
                    FilledButton.icon(
                      onPressed: c.mission.busy
                          ? null
                          : () {
                              Navigator.pop(context);
                              widget.onStartMission();
                            },
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('Mulai Misi dengan data ini'),
                    ),
                    IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
                  ],
                ),
              ),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 3,
                      child: ListView(
                        padding: const EdgeInsets.all(16),
                        children: [
                          Row(
                            children: [
                              _Kpi('TOTAL OMZET', 'Rp ${DataAdvisor.formatRupiah(r.total)}', HqColors.accent),
                              const SizedBox(width: 8),
                              _Kpi('RATA-RATA / BARIS', 'Rp ${DataAdvisor.formatRupiah(r.average)}', HqColors.cloud),
                              const SizedBox(width: 8),
                              _Kpi('BARIS VALID', '${r.rows}', HqColors.text),
                              const SizedBox(width: 8),
                              _Kpi('DILEWATI', '${r.skipped}', r.skipped > 0 ? HqColors.warning : HqColors.muted),
                            ],
                          ),
                          const SizedBox(height: 14),
                          const _Section('OMZET PER BULAN'),
                          MonthChart(months: r.months),
                          const SizedBox(height: 14),
                          const _Section('5 PRODUK TERATAS'),
                          for (final (i, p) in r.products.indexed)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 3),
                              child: Row(
                                children: [
                                  SizedBox(width: 22, child: Text('${i + 1}.', style: const TextStyle(color: HqColors.muted))),
                                  Expanded(child: Text(p.name, overflow: TextOverflow.ellipsis)),
                                  Text('Rp ${DataAdvisor.formatRupiah(p.value)}', style: const TextStyle(fontWeight: FontWeight.w600)),
                                ],
                              ),
                            ),
                          const SizedBox(height: 14),
                          const _Section('PEMETAAN KOLOM'),
                          Text(_mappingText(r), style: const TextStyle(fontSize: 12, color: HqColors.muted)),
                          for (final w in r.warnings)
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text('⚠ $w', style: const TextStyle(fontSize: 12, color: HqColors.warning)),
                            ),
                          const SizedBox(height: 14),
                          const _Section('PRATINJAU 5 BARIS'),
                          for (final row in r.preview)
                            Text('${row.month}  ·  ${row.product}  ·  Rp ${DataAdvisor.formatRupiah(row.value)}', style: const TextStyle(fontSize: 12)),
                          const SizedBox(height: 14),
                          const _Section('SARAN OTOMATIS (KODE)'),
                          Text(DataAdvisor.suggestions(r), style: const TextStyle(fontSize: 13)),
                        ],
                      ),
                    ),
                    Container(width: 1, color: HqColors.border),
                    Expanded(
                      flex: 2,
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const _Section('TANYA AGENT DATA'),
                            const Text(
                              'Pertanyaan total, rata-rata, tren, dan ranking dijawab langsung oleh kode. Pertanyaan bebas memakai model lokal, atau provider cloud bila kamu mengaktifkannya; hanya agregat yang dikirim.',
                              style: TextStyle(fontSize: 11.5, color: HqColors.muted),
                            ),
                            const SizedBox(height: 10),
                            TextField(
                              controller: _question,
                              textInputAction: TextInputAction.send,
                              onSubmitted: c.ask,
                              decoration: InputDecoration(
                                hintText: 'Contoh: produk terlaris? atau: apa risiko bulan ini?',
                                suffixIcon: IconButton(
                                  icon: c.answering ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.send),
                                  onPressed: c.answering ? null : () => c.ask(_question.text),
                                ),
                              ),
                            ),
                            const SizedBox(height: 10),
                            if (c.answer != null) SourceBadge(providerId: c.answerSource, providerName: c.providerName(c.answerSource)),
                            const SizedBox(height: 6),
                            Expanded(
                              child: Container(
                                width: double.infinity,
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(color: HqColors.background, borderRadius: BorderRadius.circular(10)),
                                child: SingleChildScrollView(
                                  child: Text(c.answer ?? 'Jawaban akan muncul di sini.', style: TextStyle(fontSize: 13, color: c.answer == null ? HqColors.muted : HqColors.text)),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  String _mappingText(dynamic r) {
    final m = r.mapping;
    String col(int i) => i >= 0 && i < r.headers.length ? '"${r.headers[i]}"' : '—';
    return 'Tanggal: ${col(m.date)}  ·  Produk: ${col(m.product)}  ·  Qty: ${col(m.quantity)}  ·  Harga: ${col(m.price)}  ·  Omzet: ${col(m.revenue)}';
  }
}

class _Kpi extends StatelessWidget {
  const _Kpi(this.label, this.value, this.color);
  final String label;
  final String value;
  final Color color;
  @override
  Widget build(BuildContext context) => Expanded(
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: HqColors.panelAlt, borderRadius: BorderRadius.circular(10)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: const TextStyle(fontSize: 10, color: HqColors.muted, letterSpacing: 1)),
              const SizedBox(height: 4),
              FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: Text(value, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: color))),
            ],
          ),
        ),
      );
}

class _Section extends StatelessWidget {
  const _Section(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(text, style: const TextStyle(fontSize: 10.5, color: HqColors.muted, letterSpacing: 1.2, fontWeight: FontWeight.w700)),
      );
}
