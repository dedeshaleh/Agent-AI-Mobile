import 'dart:async';

import 'package:flutter_embed_unity/flutter_embed_unity.dart';

import 'game_protocol.dart';

/// Jembatan ke scene Unity yang tertanam lewat `flutter_embed_unity`.
/// Perintah yang dikirim sebelum Unity mengirim `ready` diantrekan.
class UnityGameBridge implements GameBridge {
  static const gameObject = 'FlutterBridge';
  static const method = 'OnMessage';

  final _events = StreamController<GameEvent>.broadcast();
  final _pending = <GameCommand>[];
  bool _ready = false;

  @override
  Stream<GameEvent> get events => _events.stream;

  @override
  bool get isReady => _ready;

  /// Hubungkan ke `EmbedUnity(onMessageFromUnity: bridge.onMessageFromUnity)`.
  void onMessageFromUnity(String raw) {
    final event = GameEvent.decode(raw);
    if (event == null) return;
    if (event is GameReady) {
      _ready = true;
      for (final c in _pending) {
        _dispatch(c);
      }
      _pending.clear();
    }
    _events.add(event);
  }

  /// Dipanggil saat widget Unity dilepas (mis. pindah layar) agar perintah
  /// berikutnya diantrekan lagi sampai `ready` baru.
  void markDetached() => _ready = false;

  @override
  void send(GameCommand command) {
    if (!_ready) {
      _pending.add(command);
      return;
    }
    _dispatch(command);
  }

  void _dispatch(GameCommand command) => sendToUnity(gameObject, method, command.encode());

  @override
  void dispose() {
    _events.close();
  }
}
