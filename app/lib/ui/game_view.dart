import 'package:flutter/material.dart';
import 'package:flutter_embed_unity/flutter_embed_unity.dart';

import '../game_bridge/game_protocol.dart';
import '../game_bridge/simulated_game_bridge.dart';
import '../game_bridge/unity_game_bridge.dart';
import 'office_board.dart';

/// `--dart-define=UNITY_EMBED=true` setelah `scripts/Export-Unity.ps1`
/// menghasilkan `app/android/unityLibrary`. Tanpa itu, papan status dipakai.
const bool kUnityEmbed = bool.fromEnvironment('UNITY_EMBED', defaultValue: false);

GameBridge createGameBridge() => kUnityEmbed ? UnityGameBridge() : SimulatedGameBridge();

class GameView extends StatefulWidget {
  const GameView({super.key, required this.bridge});
  final GameBridge bridge;

  @override
  State<GameView> createState() => _GameViewState();
}

class _GameViewState extends State<GameView> {
  @override
  void dispose() {
    if (widget.bridge case final UnityGameBridge unity) unity.markDetached();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return switch (widget.bridge) {
      final UnityGameBridge unity => EmbedUnity(onMessageFromUnity: unity.onMessageFromUnity),
      final SimulatedGameBridge sim => OfficeBoard(bridge: sim),
      _ => const Center(child: Text('Tampilan game tidak tersedia')),
    };
  }
}
