import 'package:flutter/material.dart';

import '../agents/agent_role.dart';
import '../game_bridge/simulated_game_bridge.dart';
import 'theme.dart';

/// Papan status empat ruangan untuk mode tanpa Unity. Menampilkan posisi,
/// state, dan ucapan robot dari [SimulatedGameBridge]; bukan pengganti game.
class OfficeBoard extends StatelessWidget {
  const OfficeBoard({super.key, required this.bridge});
  final SimulatedGameBridge bridge;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Map<AgentRole, SimAgent>>(
      valueListenable: bridge.agents,
      builder: (context, agents, _) {
        return Container(
          color: const Color(0xFF07101A),
          padding: const EdgeInsets.all(10),
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: HqColors.warning.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: HqColors.warning.withValues(alpha: 0.5)),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.videogame_asset_off_outlined, size: 16, color: HqColors.warning),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Tampilan Unity belum diekspor. Ini papan status simulasi; lihat unity/README.md.',
                        style: TextStyle(fontSize: 12, color: HqColors.warning),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: GridView.count(
                  crossAxisCount: 2,
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                  childAspectRatio: 1.6,
                  physics: const NeverScrollableScrollPhysics(),
                  children: [
                    for (final room in OfficeRoom.values) _RoomTile(room: room, agents: agents, bridge: bridge),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              _Corridor(agents: agents),
            ],
          ),
        );
      },
    );
  }
}

class _RoomTile extends StatelessWidget {
  const _RoomTile({required this.room, required this.agents, required this.bridge});
  final OfficeRoom room;
  final Map<AgentRole, SimAgent> agents;
  final SimulatedGameBridge bridge;

  @override
  Widget build(BuildContext context) {
    final inside = agents.entries.where((e) => e.value.roomIndex == room.index && !e.value.walking).toList();
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: room.color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: room.color.withValues(alpha: 0.45)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(room.label.toUpperCase(), style: TextStyle(color: room.color, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1)),
          const SizedBox(height: 4),
          Expanded(
            child: Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [for (final e in inside) _Robot(role: e.key, sim: e.value, onTap: () => bridge.tapAgent(e.key))],
            ),
          ),
        ],
      ),
    );
  }
}

class _Corridor extends StatelessWidget {
  const _Corridor({required this.agents});
  final Map<AgentRole, SimAgent> agents;

  @override
  Widget build(BuildContext context) {
    final walking = agents.entries.where((e) => e.value.walking).toList();
    return Container(
      height: 46,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(color: HqColors.panel, borderRadius: BorderRadius.circular(8)),
      child: Row(
        children: [
          const Text('KORIDOR', style: TextStyle(color: HqColors.muted, fontSize: 11, letterSpacing: 1)),
          const SizedBox(width: 10),
          for (final e in walking) ...[
            _Robot(role: e.key, sim: e.value),
            const SizedBox(width: 6),
          ],
          if (walking.isEmpty) const Text('—', style: TextStyle(color: HqColors.muted)),
        ],
      ),
    );
  }
}

class _Robot extends StatelessWidget {
  const _Robot({required this.role, required this.sim, this.onTap});
  final AgentRole role;
  final SimAgent sim;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final color = role.color;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: color.withValues(alpha: sim.selected ? 0.35 : 0.18),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: sim.selected ? Colors.white : color.withValues(alpha: 0.7)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  sim.walking
                      ? Icons.directions_walk
                      : sim.state == AgentState.talking
                          ? Icons.record_voice_over
                          : sim.state == AgentState.waitingLlm
                              ? Icons.psychology_alt
                              : Icons.smart_toy_outlined,
                  size: 15,
                  color: color,
                ),
                const SizedBox(width: 4),
                Text(role.title, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600)),
                const SizedBox(width: 6),
                Text(sim.state.wire, style: const TextStyle(color: HqColors.muted, fontSize: 10)),
              ],
            ),
            if (sim.speech.isNotEmpty)
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 220),
                child: Text(sim.speech, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11)),
              ),
          ],
        ),
      ),
    );
  }
}
