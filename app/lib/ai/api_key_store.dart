/// Penyimpanan API key (PRD §6.5): hanya di secure storage, tidak pernah
/// di-log atau diserialisasi bersama konfigurasi provider.
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract class ApiKeyStore {
  static const keyPrefix = 'agenthq.apikey.';

  Future<String?> read(String providerId);
  Future<void> write(String providerId, String key);
  Future<void> delete(String providerId);

  Future<bool> has(String providerId) async {
    final k = await read(providerId);
    return k != null && k.isNotEmpty;
  }

  /// `sk-…abcd`: 3 karakter awal + 4 akhir. Key pendek dimasking penuh.
  static String masked(String key) {
    final k = key.trim();
    if (k.isEmpty) return '';
    if (k.length <= 8) return '•' * k.length;
    return '${k.substring(0, 3)}…${k.substring(k.length - 4)}';
  }

  static String storageKey(String providerId) => '$keyPrefix$providerId';
}

class SecureApiKeyStore extends ApiKeyStore {
  SecureApiKeyStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String providerId) => _storage.read(key: ApiKeyStore.storageKey(providerId));

  @override
  Future<void> write(String providerId, String key) =>
      _storage.write(key: ApiKeyStore.storageKey(providerId), value: key);

  @override
  Future<void> delete(String providerId) => _storage.delete(key: ApiKeyStore.storageKey(providerId));
}

/// Untuk unit test dan preview; tidak persisten.
class InMemoryApiKeyStore extends ApiKeyStore {
  final _keys = <String, String>{};

  @override
  Future<String?> read(String providerId) async => _keys[ApiKeyStore.storageKey(providerId)];

  @override
  Future<void> write(String providerId, String key) async => _keys[ApiKeyStore.storageKey(providerId)] = key;

  @override
  Future<void> delete(String providerId) async => _keys.remove(ApiKeyStore.storageKey(providerId));
}
