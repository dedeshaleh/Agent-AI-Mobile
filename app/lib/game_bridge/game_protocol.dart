/// Protokol JSON Flutter ⇄ Unity (PRD v1.1 §6.2, opsi G1 dengan Unity).
///
/// Flutter adalah sumber kebenaran untuk workflow; Unity hanya menggambar
/// kantor, menggerakkan robot, dan melaporkan sentuhan. Setiap pesan adalah
/// satu objek JSON dengan field `type`. Dokumen ini dicerminkan oleh
/// `unity/AgentHQ/Assets/AgentHQ/Scripts/FlutterBridge.cs`.
///
/// Flutter → Unity (`sendToUnity("FlutterBridge", "OnMessage", json)`):
/// ```json
/// {"type":"walkTo","agent":0,"target":"seat"}        // target: home | seat | room:<0-3>
/// {"type":"setState","agent":0,"state":"WORKING"}    // AgentState.wire
/// {"type":"speak","agent":2,"text":"..."}             // bubble bicara, "" untuk hapus
/// {"type":"meeting","active":true}                    // semua ke kursi / kembali ke meja
/// {"type":"pause","paused":true}
/// {"type":"speed","value":2}                          // 1 atau 2, hanya animasi
/// {"type":"select","agent":1}                         // sorot robot
/// {"type":"resetCamera"}
/// ```
/// Unity → Flutter (`SendToFlutter.Send(json)`):
/// ```json
/// {"type":"ready","version":1}
/// {"type":"arrived","agent":0,"room":2}
/// {"type":"agentTapped","agent":0}
/// {"type":"roomTapped","room":1}
/// {"type":"meetingSeated"}                            // keempat robot sudah duduk
/// {"type":"stats","fps":29.8,"frameMs":33.5,"gpu":"Mali-G610"}   // tiap detik
/// {"type":"error","message":"..."}
/// ```
library;

import 'dart:convert';

import '../agents/agent_role.dart';

sealed class GameCommand {
  const GameCommand();
  Map<String, Object?> toJson();
  String encode() => jsonEncode(toJson());
}

class WalkTo extends GameCommand {
  const WalkTo(this.agent, this.target);
  const WalkTo.home(AgentRole agent) : this(agent, 'home');
  const WalkTo.seat(AgentRole agent) : this(agent, 'seat');
  WalkTo.room(AgentRole agent, OfficeRoom room) : this(agent, 'room:${room.index}');
  final AgentRole agent;
  final String target;
  @override
  Map<String, Object?> toJson() => {'type': 'walkTo', 'agent': agent.index, 'target': target};
}

class SetState extends GameCommand {
  const SetState(this.agent, this.state);
  final AgentRole agent;
  final AgentState state;
  @override
  Map<String, Object?> toJson() => {'type': 'setState', 'agent': agent.index, 'state': state.wire};
}

class Speak extends GameCommand {
  const Speak(this.agent, this.text);
  final AgentRole agent;
  final String text;
  @override
  Map<String, Object?> toJson() => {'type': 'speak', 'agent': agent.index, 'text': text};
}

class SetMeeting extends GameCommand {
  const SetMeeting(this.active);
  final bool active;
  @override
  Map<String, Object?> toJson() => {'type': 'meeting', 'active': active};
}

class SetPaused extends GameCommand {
  const SetPaused(this.paused);
  final bool paused;
  @override
  Map<String, Object?> toJson() => {'type': 'pause', 'paused': paused};
}

class SetSpeed extends GameCommand {
  const SetSpeed(this.value);
  final int value;
  @override
  Map<String, Object?> toJson() => {'type': 'speed', 'value': value};
}

class SelectAgent extends GameCommand {
  const SelectAgent(this.agent);
  final AgentRole? agent;
  @override
  Map<String, Object?> toJson() => {'type': 'select', 'agent': agent?.index ?? -1};
}

class ResetCamera extends GameCommand {
  const ResetCamera();
  @override
  Map<String, Object?> toJson() => const {'type': 'resetCamera'};
}

sealed class GameEvent {
  const GameEvent();

  static GameEvent? decode(String raw) {
    final Object? parsed;
    try {
      parsed = jsonDecode(raw);
    } on FormatException {
      return GameError('Pesan Unity bukan JSON: $raw');
    }
    if (parsed is! Map<String, Object?>) return GameError('Pesan Unity tidak dikenal: $raw');
    final map = parsed;
    final type = map['type'];
    int intOf(String key) => (map[key] as num?)?.toInt() ?? -1;
    switch (type) {
      case 'ready':
        return GameReady(intOf('version'));
      case 'arrived':
        return AgentArrived(AgentRole.fromIndex(intOf('agent')), intOf('room'));
      case 'agentTapped':
        return AgentTapped(AgentRole.fromIndex(intOf('agent')));
      case 'roomTapped':
        return RoomTapped(OfficeRoom.fromIndex(intOf('room')));
      case 'meetingSeated':
        return const MeetingSeated();
      case 'stats':
        return GameStats(
          fps: (map['fps'] as num?)?.toDouble() ?? 0,
          frameMs: (map['frameMs'] as num?)?.toDouble() ?? 0,
          gpu: map['gpu'] as String?,
        );
      case 'error':
        return GameError((parsed['message'] as String?) ?? 'Kesalahan Unity');
      default:
        return GameError('Tipe pesan Unity tidak dikenal: $type');
    }
  }
}

class GameReady extends GameEvent {
  const GameReady(this.version);
  final int version;
}

class AgentArrived extends GameEvent {
  const AgentArrived(this.agent, this.roomIndex);
  final AgentRole agent;

  /// `-1` berarti koridor.
  final int roomIndex;
}

class AgentTapped extends GameEvent {
  const AgentTapped(this.agent);
  final AgentRole agent;
}

class RoomTapped extends GameEvent {
  const RoomTapped(this.room);
  final OfficeRoom room;
}

class MeetingSeated extends GameEvent {
  const MeetingSeated();
}

class GameStats extends GameEvent {
  const GameStats({required this.fps, required this.frameMs, this.gpu});
  final double fps;
  final double frameMs;
  final String? gpu;
}

class GameError extends GameEvent {
  const GameError(this.message);
  final String message;
}

/// Abstraksi tampilan game. `UnityGameBridge` memakai `flutter_embed_unity`;
/// `SimulatedGameBridge` dipakai saat `unityLibrary` belum diekspor sehingga
/// alur misi tetap bisa diuji.
abstract class GameBridge {
  Stream<GameEvent> get events;
  bool get isReady;
  void send(GameCommand command);
  void dispose();
}
