import 'package:flutter/material.dart';

import '../agents/agent_chat.dart';
import '../agents/agent_profile.dart';
import '../agents/agent_role.dart';
import '../ai/ai_provider.dart';
import '../app_controller.dart';
import 'theme.dart';

/// Pengaturan perilaku per agent: identitas, gaya, perilaku tim, model.
class AgentSettingsScreen extends StatefulWidget {
  const AgentSettingsScreen({super.key, required this.controller, this.initial = AgentRole.data});
  final AppController controller;
  final AgentRole initial;

  @override
  State<AgentSettingsScreen> createState() => _AgentSettingsScreenState();
}

class _AgentSettingsScreenState extends State<AgentSettingsScreen> {
  AppController get c => widget.controller;
  late AgentRole role = widget.initial;
  late final _nick = TextEditingController();
  late final _instr = TextEditingController();
  bool _testing = false;
  String? _testReply;

  AgentProfile get profile => c.profiles.of(role);

  @override
  void initState() {
    super.initState();
    _syncFields();
  }

  void _syncFields() {
    _nick.text = profile.nickname;
    _instr.text = profile.instructions;
    _testReply = null;
  }

  @override
  void dispose() {
    _nick.dispose();
    _instr.dispose();
    super.dispose();
  }

  Future<void> _save(AgentProfile p) => c.profiles.save(p);

  Future<void> _test() async {
    if (c.mission.busy) return;
    setState(() {
      _testing = true;
      _testReply = null;
    });
    final before = c.mission.chat.length;
    await c.mission.command(ChatTarget.agent(role), 'Perkenalkan dirimu dalam satu kalimat dan sapa pengguna sesuai gayamu.');
    if (!mounted) return;
    final reply = c.mission.chat.skip(before).where((m) => m.author == ChatAuthor.agent && m.agent == role).lastOrNull;
    setState(() {
      _testing = false;
      _testReply = reply?.text ?? 'Tidak ada jawaban.';
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([c.profiles, c.settingsStore]),
      builder: (context, _) {
        final p = profile;
        final s = c.settings;
        return Scaffold(
          appBar: AppBar(
            backgroundColor: HqColors.panel,
            title: const Text('Pengaturan Agent'),
            actions: [
              TextButton(
                onPressed: () async {
                  await c.profiles.resetAll();
                  _syncFields();
                },
                child: const Text('Kembalikan semua'),
              ),
            ],
          ),
          body: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 230,
                color: HqColors.panel,
                padding: const EdgeInsets.all(10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('PILIH AGENT', style: TextStyle(fontSize: 10, color: HqColors.muted, letterSpacing: 1)),
                    const SizedBox(height: 6),
                    for (final r in AgentRole.values)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(10),
                          onTap: () => setState(() {
                            role = r;
                            _syncFields();
                          }),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
                            decoration: BoxDecoration(
                              color: r == role ? r.color.withValues(alpha: 0.16) : HqColors.panelAlt,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: r == role ? r.color.withValues(alpha: 0.5) : Colors.transparent),
                            ),
                            child: Row(
                              children: [
                                Container(width: 10, height: 10, decoration: BoxDecoration(color: r.color, shape: BoxShape.circle)),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(c.profiles.of(r).displayName, style: TextStyle(color: r.color, fontWeight: FontWeight.w600)),
                                      Text(
                                        '${c.profiles.of(r).tone.label} · ${c.profiles.of(r).verbosity.label} · ${c.providerName(s.assignedProviderId(r))}',
                                        style: const TextStyle(fontSize: 10, color: HqColors.muted),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                  children: [
                    Row(
                      children: [
                        Text('${role.title} · ${role.duty}', style: TextStyle(color: role.color, fontWeight: FontWeight.w700, fontSize: 15)),
                        const Spacer(),
                        if (!p.isDefault) TextButton(onPressed: () async {
                          await c.profiles.reset(role);
                          _syncFields();
                        }, child: const Text('Bawaan')),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 16,
                      runSpacing: 16,
                      children: [
                        SizedBox(
                          width: 420,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const _Section('IDENTITAS & GAYA'),
                              TextField(
                                controller: _nick,
                                decoration: InputDecoration(labelText: 'Nama panggilan', hintText: role.title),
                                onChanged: (v) => _save(p.copyWith(nickname: v)),
                              ),
                              const SizedBox(height: 10),
                              const Text('Gaya bahasa', style: TextStyle(fontSize: 12, color: HqColors.muted)),
                              const SizedBox(height: 4),
                              SegmentedButton<AgentTone>(
                                segments: [for (final t in AgentTone.values) ButtonSegment(value: t, label: Text(t.label))],
                                selected: {p.tone},
                                onSelectionChanged: (v) => _save(p.copyWith(tone: v.first)),
                              ),
                              const SizedBox(height: 10),
                              const Text('Panjang jawaban', style: TextStyle(fontSize: 12, color: HqColors.muted)),
                              const SizedBox(height: 4),
                              SegmentedButton<AgentVerbosity>(
                                segments: [for (final v in AgentVerbosity.values) ButtonSegment(value: v, label: Text(v.label))],
                                selected: {p.verbosity},
                                onSelectionChanged: (v) => _save(p.copyWith(verbosity: v.first, resetMaxTokens: true)),
                              ),
                              const SizedBox(height: 10),
                              TextField(
                                controller: _instr,
                                maxLines: 4,
                                decoration: const InputDecoration(
                                  labelText: 'Instruksi khusus (ditambahkan ke system prompt)',
                                  hintText: 'Contoh: selalu sebutkan periode pembanding saat membahas tren.',
                                  alignLabelWithHint: true,
                                ),
                                onChanged: (v) => _save(p.copyWith(instructions: v)),
                              ),
                              const SizedBox(height: 6),
                              const Text(
                                'Aturan tetap yang tidak bisa dimatikan: tidak mengarang angka; KPI hanya dari hasil perhitungan kode.',
                                style: TextStyle(fontSize: 11, color: HqColors.muted),
                              ),
                            ],
                          ),
                        ),
                        SizedBox(
                          width: 420,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const _Section('PERILAKU'),
                              _toggle('Boleh mendelegasikan ke rekan', p.canDelegate, (v) => _save(p.copyWith(canDelegate: v))),
                              _toggle('Menerima tugas dari rekan', p.acceptsDelegation, (v) => _save(p.copyWith(acceptsDelegation: v))),
                              _toggle('Ikut menyapa saat aplikasi dibuka', p.greets, (v) => _save(p.copyWith(greets: v))),
                              _toggle('Ikut menjawab saat perintah ke "Tim"', p.joinsTeam, (v) => _save(p.copyWith(joinsTeam: v))),
                              const SizedBox(height: 12),
                              const _Section('MODEL'),
                              DropdownButtonFormField<String>(
                                initialValue: s.assignedProviderId(role),
                                decoration: const InputDecoration(labelText: 'Provider'),
                                items: [
                                  for (final cfg in s.allProviders)
                                    DropdownMenuItem(value: cfg.id, child: Text(cfg.id == ProviderConfig.localId ? 'Model lokal' : cfg.name)),
                                ],
                                onChanged: (v) => v == null ? null : c.settingsStore.update((cur) => cur.assign(role, v)),
                              ),
                              const SizedBox(height: 6),
                              _slider('Kreativitas (suhu)', p.temperature, 0, 1, 10, (v) => _save(p.copyWith(temperature: double.parse(v.toStringAsFixed(1)))), p.temperature.toStringAsFixed(1)),
                              _slider('Token maks', p.maxTokens.toDouble(), 96, 640, 17, (v) => _save(p.copyWith(maxTokens: v.round())), '${p.maxTokens}'),
                              const SizedBox(height: 10),
                              Row(
                                children: [
                                  FilledButton.icon(
                                    onPressed: _testing || c.mission.busy ? null : _test,
                                    icon: _testing ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.play_arrow),
                                    label: Text(_testing ? 'Menguji…' : 'Uji perilaku'),
                                  ),
                                  const SizedBox(width: 10),
                                  const Expanded(child: Text('Agent memperkenalkan diri dengan gaya yang dipilih; bubble juga muncul di game.', style: TextStyle(fontSize: 11, color: HqColors.muted))),
                                ],
                              ),
                              if (_testReply != null) ...[
                                const SizedBox(height: 8),
                                Container(
                                  padding: const EdgeInsets.all(10),
                                  decoration: BoxDecoration(color: HqColors.background, borderRadius: BorderRadius.circular(8)),
                                  child: Row(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(p.displayName, style: TextStyle(color: role.color, fontWeight: FontWeight.w600)),
                                      const SizedBox(width: 8),
                                      Expanded(child: Text(_testReply!)),
                                    ],
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
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

  Widget _toggle(String label, bool value, ValueChanged<bool> onChanged) => SwitchListTile(
        contentPadding: EdgeInsets.zero,
        dense: true,
        title: Text(label, style: const TextStyle(fontSize: 13)),
        value: value,
        onChanged: onChanged,
      );

  Widget _slider(String label, double value, double min, double max, int divisions, ValueChanged<double> onChanged, String display) => Row(
        children: [
          SizedBox(width: 130, child: Text(label, style: const TextStyle(fontSize: 12))),
          Expanded(child: Slider(value: value.clamp(min, max), min: min, max: max, divisions: divisions, onChanged: onChanged)),
          SizedBox(width: 40, child: Text(display, textAlign: TextAlign.right)),
        ],
      );
}

class _Section extends StatelessWidget {
  const _Section(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text, style: const TextStyle(fontSize: 10.5, color: HqColors.muted, letterSpacing: 1.2, fontWeight: FontWeight.w700)),
      );
}
