/// Membangun [AiProvider] dari [ProviderConfig] + validasi keamanan URL.
library;

import 'package:http/http.dart' as http;

import 'ai_provider.dart';
import 'local/local_engine.dart';
import 'providers/anthropic_provider.dart';
import 'providers/gemini_provider.dart';
import 'providers/local_llama_provider.dart';
import 'providers/openai_compatible_provider.dart';

/// Loopback atau alamat privat (RFC 1918) — satu-satunya tempat HTTP polos
/// boleh dipakai, itu pun dengan konfirmasi `allowInsecureLan`.
bool isPrivateHost(String host) {
  final h = host.toLowerCase();
  if (h == 'localhost' || h == '127.0.0.1' || h == '::1' || h == '[::1]' || h == '10.0.2.2') return true;
  if (h.startsWith('127.') || h.startsWith('192.168.') || h.startsWith('10.')) return true;
  final m = RegExp(r'^172\.(\d+)\.').firstMatch(h);
  if (m != null) {
    final second = int.tryParse(m.group(1)!) ?? -1;
    return second >= 16 && second <= 31;
  }
  return false;
}

/// Melempar [AiProviderException] bila URL tidak boleh dipakai.
void validateBaseUrl(String baseUrl, {required bool allowInsecureLan}) {
  final uri = Uri.tryParse(baseUrl.trim());
  if (uri == null || uri.host.isEmpty || !uri.hasScheme) {
    throw const AiProviderException('Base URL tidak valid (contoh: https://api.openai.com)');
  }
  final scheme = uri.scheme.toLowerCase();
  if (scheme == 'https') return;
  if (scheme != 'http') {
    throw AiProviderException('Skema URL tidak didukung: ${uri.scheme}');
  }
  if (!isPrivateHost(uri.host)) {
    throw const AiProviderException('Provider internet wajib HTTPS. HTTP hanya untuk alamat LAN/loopback.');
  }
  if (!allowInsecureLan) {
    throw const AiProviderException(
      'Alamat LAN tanpa HTTPS perlu konfirmasi "Izinkan HTTP di jaringan lokal" di Pengaturan AI.',
    );
  }
}

AiProvider buildProvider(
  ProviderConfig cfg, {
  required String? apiKey,
  required http.Client client,
  required LocalEngine localEngine,
  required bool allowInsecureLan,
}) {
  switch (cfg.kind) {
    case AiProviderKind.local:
      return LocalLlamaProvider(localEngine);
    case AiProviderKind.openaiCompatible:
    case AiProviderKind.custom:
      validateBaseUrl(cfg.baseUrl, allowInsecureLan: allowInsecureLan);
      if (cfg.kind == AiProviderKind.openaiCompatible && (apiKey == null || apiKey.isEmpty)) {
        throw const AiProviderException('API key belum diisi');
      }
      return OpenAiCompatibleProvider(config: cfg, client: client, apiKey: apiKey);
    case AiProviderKind.anthropic:
      if (cfg.baseUrl.trim().isNotEmpty) validateBaseUrl(cfg.baseUrl, allowInsecureLan: allowInsecureLan);
      if (apiKey == null || apiKey.isEmpty) throw const AiProviderException('API key Anthropic belum diisi');
      return AnthropicProvider(config: cfg, client: client, apiKey: apiKey);
    case AiProviderKind.gemini:
      if (cfg.baseUrl.trim().isNotEmpty) validateBaseUrl(cfg.baseUrl, allowInsecureLan: allowInsecureLan);
      if (apiKey == null || apiKey.isEmpty) throw const AiProviderException('API key Gemini belum diisi');
      return GeminiProvider(config: cfg, client: client, apiKey: apiKey);
  }
}
