/// Parser Server-Sent Events minimal (dipakai semua provider remote).
library;

import 'dart:async';
import 'dart:convert';

class SseEvent {
  const SseEvent({this.event, required this.data});
  final String? event;
  final String data;
}

/// Mengubah stream byte HTTP menjadi event SSE. Baris `data:` berurutan
/// digabung dengan `\n`; event dipisahkan baris kosong. Komentar (`:`)
/// dan field lain diabaikan.
Stream<SseEvent> parseSse(Stream<List<int>> bytes) async* {
  String? event;
  final data = <String>[];
  final lines = bytes.transform(utf8.decoder).transform(const LineSplitter());
  await for (final raw in lines) {
    final line = raw.endsWith('\r') ? raw.substring(0, raw.length - 1) : raw;
    if (line.isEmpty) {
      if (data.isNotEmpty) yield SseEvent(event: event, data: data.join('\n'));
      event = null;
      data.clear();
      continue;
    }
    if (line.startsWith(':')) continue;
    final colon = line.indexOf(':');
    final field = colon < 0 ? line : line.substring(0, colon);
    var value = colon < 0 ? '' : line.substring(colon + 1);
    if (value.startsWith(' ')) value = value.substring(1);
    switch (field) {
      case 'event':
        event = value;
      case 'data':
        data.add(value);
    }
  }
  if (data.isNotEmpty) yield SseEvent(event: event, data: data.join('\n'));
}
