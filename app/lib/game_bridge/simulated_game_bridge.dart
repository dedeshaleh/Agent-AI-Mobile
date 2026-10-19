import 'dart:async';

import 'package:flutter/foundation.dart';

import '../agents/agent_role.dart';
import 'game_protocol.dart';

/// Posisi/keadaan satu robot untuk papan status saat Unity belum tersedia.
class SimAgent {
  const SimAgent({
    required this.state,
    required this.roomIndex,
    this.speech = '',
    this.walking = false,
    this.selected = false,
  });
  final AgentState state;

  /// `-1` = koridor.
  final int roomIndex;
  final String speech;
  final bool walking;
  final bool selected;

  SimAgent copyWith({AgentState? state, int? roomIndex, String? speech, bool? walking, bool? selected}) =>
      SimAgent(
        state: state ?? this.state,
        roomIndex: roomIndex ?? this.roomIndex,
        speech: speech ?? this.speech,
        walking: walking ?? this.walking,
        selected: selected ?? this.selected,
      );
}

/// Pengganti Unity selama `unityLibrary` belum diekspor. Meniru waktu jalan
/// robot supaya orchestrator tetap bisa diuji end-to-end; bukan game.
class SimulatedGameBridge implements GameBridge {
  SimulatedGameBridge({this.walkDuration = const Duration(milliseconds: 1800)}) {
    scheduleMicrotask(() => _events.add(const GameReady(0)));
  }

  final Duration walkDuration;
  final _events = StreamController<GameEvent>.broadcast();
  final agents = ValueNotifier<Map<AgentRole, SimAgent>>({
    for (final r in AgentRole.values) r: SimAgent(state: AgentState.idle, roomIndex: r.homeRoom.index),
  });
  final _timers = <AgentRole, Timer>{};
  bool _paused = false;
  int _speed = 1;
  bool _meeting = false;
  int _seated = 0;

  @override
  Stream<GameEvent> get events => _events.stream;

  @override
  bool get isReady => true;

  @override
  void send(GameCommand command) {
    switch (command) {
      case WalkTo(:final agent, :final target):
        _walk(agent, _roomFor(agent, target), seat: target == 'seat');
      case SetState(:final agent, :final state):
        _update(agent, (a) => a.copyWith(state: state));
      case Speak(:final agent, :final text):
        _update(agent, (a) => a.copyWith(speech: text));
      case SetMeeting(:final active):
        _meeting = active;
        _seated = 0;
        for (final r in AgentRole.values) {
          _walk(r, active ? OfficeRoom.meeting.index : r.homeRoom.index, seat: active);
        }
      case SetPaused(:final paused):
        _paused = paused;
      case SetSpeed(:final value):
        _speed = value.clamp(1, 4);
      case SelectAgent(:final agent):
        agents.value = {
          for (final e in agents.value.entries) e.key: e.value.copyWith(selected: e.key == agent),
        };
      case ResetCamera():
        break;
    }
  }

  int _roomFor(AgentRole agent, String target) {
    if (target == 'home') return agent.homeRoom.index;
    if (target == 'seat') return OfficeRoom.meeting.index;
    if (target.startsWith('room:')) return int.tryParse(target.substring(5)) ?? agent.homeRoom.index;
    return agent.homeRoom.index;
  }

  void _walk(AgentRole agent, int room, {required bool seat}) {
    _timers[agent]?.cancel();
    _update(agent, (a) => a.copyWith(walking: true, state: AgentState.walking, speech: ''));
    _timers[agent] = Timer.periodic(const Duration(milliseconds: 100), (timer) {
      if (_paused) return;
      final elapsed = (timer.tick * 100 * _speed);
      if (elapsed < walkDuration.inMilliseconds) return;
      timer.cancel();
      _update(agent, (a) => a.copyWith(walking: false, roomIndex: room));
      _events.add(AgentArrived(agent, room));
      if (seat && _meeting && ++_seated == AgentRole.values.length) {
        _events.add(const MeetingSeated());
      }
    });
  }

  void _update(AgentRole agent, SimAgent Function(SimAgent) change) {
    agents.value = {...agents.value, agent: change(agents.value[agent]!)};
  }

  /// Dipakai UI papan status untuk meniru tap robot.
  void tapAgent(AgentRole agent) => _events.add(AgentTapped(agent));

  @override
  void dispose() {
    for (final t in _timers.values) {
      t.cancel();
    }
    _events.close();
    agents.dispose();
  }
}
