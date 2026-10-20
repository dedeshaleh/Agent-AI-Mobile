/// Model percakapan antara pengguna, agent, dan sistem (log) untuk panel chat.
library;

import 'agent_role.dart';

enum ChatAuthor { user, agent, system }

class ChatMessage {
  ChatMessage.user(this.text, {this.target})
      : author = ChatAuthor.user,
        agent = null,
        source = null,
        at = DateTime.now();

  ChatMessage.agent(AgentRole this.agent, this.text, {this.source, this.durationMs, this.tokensPerSecond})
      : author = ChatAuthor.agent,
        target = null,
        at = DateTime.now();

  ChatMessage.system(this.text)
      : author = ChatAuthor.system,
        agent = null,
        target = null,
        source = null,
        at = DateTime.now();

  /// Lama proses jawaban (ms) dan kecepatan model; null untuk template/sapaan.
  int? durationMs;
  double? tokensPerSecond;

  String? get timingLabel {
    if (durationMs == null) return null;
    final secs = (durationMs! / 1000).toStringAsFixed(1).replaceAll('.', ',');
    final tps = tokensPerSecond;
    return tps == null || tps <= 0 ? '⏱ $secs s' : '⏱ $secs s · ${tps.toStringAsFixed(0)} tok/s';
  }

  final ChatAuthor author;
  final AgentRole? agent;
  final String text;

  /// Untuk pesan pengguna: tujuan perintah (null = seluruh tim).
  final ChatTarget? target;

  /// Provider yang menjawab (null = template/kode).
  final String? source;
  final DateTime at;

  String get stamp => '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';
}

/// Tujuan perintah: seluruh tim atau satu agent.
class ChatTarget {
  const ChatTarget.team() : role = null;
  const ChatTarget.agent(AgentRole this.role);
  final AgentRole? role;
  bool get isTeam => role == null;
  String get label => role?.title ?? 'Tim';

  @override
  bool operator ==(Object other) => other is ChatTarget && other.role == role;
  @override
  int get hashCode => role.hashCode;
}

/// Sapaan menurut jam perangkat (WIB mengikuti jam HP).
String greetingForHour(int hour) {
  if (hour >= 4 && hour < 10) return 'Selamat pagi';
  if (hour >= 10 && hour < 15) return 'Selamat siang';
  if (hour >= 15 && hour < 18) return 'Selamat sore';
  return 'Selamat malam';
}
