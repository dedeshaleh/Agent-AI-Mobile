/// Utilitas bersama provider remote: kirim request streaming, petakan
/// status HTTP ke [AiProviderException], hormati [CancelToken].
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../ai_provider.dart';

const kDefaultRequestTimeout = Duration(seconds: 60);
const kHealthTimeout = Duration(seconds: 10);

/// Pesan Indonesia untuk status HTTP umum; `retriable` sesuai PRD §6.4.
AiProviderException exceptionForStatus(int status, String body) {
  final detail = _extractErrorMessage(body);
  final suffix = detail.isEmpty ? '' : ': $detail';
  switch (status) {
    case 401:
    case 403:
      return AiProviderException('API key tidak valid atau tidak berizin$suffix', statusCode: status);
    case 404:
      return AiProviderException('Endpoint atau model tidak ditemukan$suffix', statusCode: status);
    case 408:
      return AiProviderException('Waktu permintaan habis$suffix', statusCode: status, retriable: true);
    case 429:
      return AiProviderException('Kuota atau batas permintaan tercapai$suffix', statusCode: status, retriable: true);
    default:
      if (status >= 500) {
        return AiProviderException('Server provider bermasalah ($status)$suffix', statusCode: status, retriable: true);
      }
      return AiProviderException('Permintaan ditolak ($status)$suffix', statusCode: status);
  }
}

String _extractErrorMessage(String body) {
  if (body.isEmpty) return '';
  try {
    final json = jsonDecode(body);
    if (json is Map) {
      final err = json['error'];
      if (err is Map && err['message'] is String) return err['message'] as String;
      if (err is String) return err;
      if (json['message'] is String) return json['message'] as String;
    }
  } catch (_) {}
  return body.length > 200 ? '${body.substring(0, 200)}…' : body;
}

/// Mengirim request dan mengembalikan body sebagai stream byte. Melempar
/// [AiProviderException] untuk status non-2xx, timeout, atau error jaringan.
/// Stream berhenti bila [cancel] dibatalkan.
Future<Stream<List<int>>> sendStreaming(
  http.Client client,
  http.Request request, {
  CancelToken? cancel,
  Duration timeout = kDefaultRequestTimeout,
}) async {
  if (cancel?.isCancelled ?? false) throw const AiProviderException('Dibatalkan');
  final http.StreamedResponse response;
  try {
    response = await client.send(request).timeout(timeout);
  } on TimeoutException {
    throw const AiProviderException('Waktu koneksi habis', retriable: true);
  } on http.ClientException catch (e) {
    throw AiProviderException('Gagal terhubung: ${e.message}', retriable: true);
  }
  if (response.statusCode < 200 || response.statusCode >= 300) {
    final body = await response.stream.bytesToString();
    throw exceptionForStatus(response.statusCode, body);
  }
  if (cancel == null) return response.stream;

  // Berhenti mendengarkan begitu token dibatalkan; koneksi akan ditutup
  // saat subscription dibatalkan.
  final controller = StreamController<List<int>>();
  late final StreamSubscription<List<int>> sub;
  StreamSubscription<void>? cancelSub;
  sub = response.stream.listen(
    controller.add,
    onError: controller.addError,
    onDone: () {
      cancelSub?.cancel();
      controller.close();
    },
  );
  cancelSub = cancel.onCancel.listen((_) {
    sub.cancel();
    if (!controller.isClosed) controller.close();
  });
  if (cancel.isCancelled) {
    await sub.cancel();
    await controller.close();
  }
  controller.onCancel = () {
    cancelSub?.cancel();
    return sub.cancel();
  };
  return controller.stream;
}

/// Request JSON biasa (non-stream) untuk health check.
Future<http.Response> sendJson(
  http.Client client,
  String method,
  Uri uri, {
  Map<String, String> headers = const {},
  Object? body,
  Duration timeout = kHealthTimeout,
}) async {
  try {
    final req = http.Request(method, uri);
    req.headers.addAll(headers);
    if (body != null) {
      req.headers['content-type'] = 'application/json';
      req.body = jsonEncode(body);
    }
    final streamed = await client.send(req).timeout(timeout);
    return await http.Response.fromStream(streamed);
  } on TimeoutException {
    throw const AiProviderException('Waktu koneksi habis', retriable: true);
  } on http.ClientException catch (e) {
    throw AiProviderException('Gagal terhubung: ${e.message}', retriable: true);
  }
}

/// Ubah exception apa pun dari health check menjadi [HealthResult.fail].
HealthResult healthFailure(Object e) {
  if (e is AiProviderException) return HealthResult.fail(e.message);
  return HealthResult.fail('Gagal: $e');
}

int asInt(Object? v) => v is int ? v : (v is num ? v.toInt() : 0);
