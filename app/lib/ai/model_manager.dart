/// Pengelola model GGUF lokal: katalog, unduh dengan resume, impor, hapus,
/// dan pemilihan model aktif (PRD §6.3).
library;

// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'ai_provider.dart';

@immutable
class ModelCatalogEntry {
  const ModelCatalogEntry({
    required this.id,
    required this.name,
    required this.sizeBytes,
    required this.url,
    this.sha256,
    this.contextDefault = 2048,
    this.note = '',
  });
  final String id;
  final String name;

  /// Perkiraan; ukuran pasti diambil dari header `Content-Length`.
  final int sizeBytes;
  final String url;
  final String? sha256;
  final int contextDefault;
  final String note;

  String get fileName => p.basename(Uri.parse(url).path);
}

@immutable
class InstalledModel {
  const InstalledModel({required this.path, required this.name, required this.sizeBytes});
  final String path;
  final String name;
  final int sizeBytes;
}

enum DownloadStatus { checking, downloading, verifying, done, cancelled }

@immutable
class DownloadProgress {
  const DownloadProgress({required this.status, this.received = 0, this.total, this.path});
  final DownloadStatus status;
  final int received;

  /// `null` bila server tidak memberi ukuran.
  final int? total;
  final String? path;
  double? get fraction => total == null || total == 0 ? null : received / total!;
  bool get done => status == DownloadStatus.done;
}

const kModelCatalog = [
  ModelCatalogEntry(
    id: 'qwen3-1.7b-q4_k_m',
    name: 'Qwen3 1.7B (Q4_K_M)',
    sizeBytes: 1110000000,
    url: 'https://huggingface.co/unsloth/Qwen3-1.7B-GGUF/resolve/main/Qwen3-1.7B-Q4_K_M.gguf',
    contextDefault: 2048,
    note: 'Default. Ringan dan cepat untuk ponsel 8 GB.',
  ),
  ModelCatalogEntry(
    id: 'qwen3.5-2b-q4_k_m',
    name: 'Qwen3.5 2B (Q4_K_M)',
    sizeBytes: 1280835840,
    url: 'https://huggingface.co/unsloth/Qwen3.5-2B-GGUF/resolve/main/Qwen3.5-2B-Q4_K_M.gguf',
    contextDefault: 2048,
    note: 'Generasi baru; kualitas mendekati 4B dengan RAM ±1,3 GB. Teks saja (mmproj tidak dipakai).',
  ),
  ModelCatalogEntry(
    id: 'qwen3-4b-q4_k_m',
    name: 'Qwen3 4B (Q4_K_M)',
    sizeBytes: 2500000000,
    url: 'https://huggingface.co/unsloth/Qwen3-4B-GGUF/resolve/main/Qwen3-4B-Q4_K_M.gguf',
    contextDefault: 2048,
    note: 'Lebih pintar, butuh RAM ~3.5 GB dan lebih lambat.',
  ),
];

typedef FreeSpaceProbe = Future<int> Function(String dir);
typedef PickFileFn = Future<String?> Function();

class ModelManager extends ChangeNotifier {
  ModelManager({
    required this.modelsDir,
    http.Client? client,
    required SharedPreferences prefs,
    this.catalog = kModelCatalog,
    this.freeSpaceProbe,
    PickFileFn? pickFile,
    this.safetyMarginBytes = 200 * 1024 * 1024,
  })  : _client = client ?? http.Client(),
        _prefs = prefs,
        _pickFile = pickFile ?? _defaultPickFile;

  static const activeModelPrefsKey = 'agenthq.active_model_path';
  static const _partSuffix = '.part';

  final String modelsDir;
  final http.Client _client;
  final SharedPreferences _prefs;
  final List<ModelCatalogEntry> catalog;

  /// Null = lewati pemeriksaan ruang kosong (belum ada implementasi platform).
  final FreeSpaceProbe? freeSpaceProbe;
  final PickFileFn _pickFile;
  final int safetyMarginBytes;

  List<InstalledModel> _installed = const [];
  List<InstalledModel> get installed => _installed;

  String? get activeModelPath => _prefs.getString(activeModelPrefsKey);

  InstalledModel? get activeModel {
    final path = activeModelPath;
    return _installed.where((m) => m.path == path).firstOrNull;
  }

  Future<void> setActiveModel(String? path) async {
    if (path == null) {
      await _prefs.remove(activeModelPrefsKey);
    } else {
      await _prefs.setString(activeModelPrefsKey, path);
    }
    notifyListeners();
  }

  /// Memindai direktori model (hanya `.gguf`, bukan `.part`).
  Future<void> refresh() async {
    final dir = Directory(modelsDir);
    if (!await dir.exists()) {
      _installed = const [];
    } else {
      final list = <InstalledModel>[];
      await for (final e in dir.list()) {
        if (e is File && e.path.toLowerCase().endsWith('.gguf')) {
          list.add(InstalledModel(path: e.path, name: p.basename(e.path), sizeBytes: await e.length()));
        }
      }
      list.sort((a, b) => a.name.compareTo(b.name));
      _installed = list;
    }
    // Model aktif yang sudah dihapus dilepas.
    final active = activeModelPath;
    if (active != null && !_installed.any((m) => m.path == active)) await _prefs.remove(activeModelPrefsKey);
    notifyListeners();
  }

  String pathForCatalog(String catalogId) => p.join(modelsDir, _entry(catalogId).fileName);

  bool isInstalled(String catalogId) => File(pathForCatalog(catalogId)).existsSync();

  ModelCatalogEntry _entry(String id) => catalog.firstWhere(
        (c) => c.id == id,
        orElse: () => throw AiProviderException('Model "$id" tidak ada di katalog'),
      );

  /// Mengunduh dengan resume (HTTP Range ke file `.part`), verifikasi SHA-256
  /// bila tersedia, lalu rename ke nama final.
  Stream<DownloadProgress> download(String catalogId, {CancelToken? cancel}) async* {
    final entry = _entry(catalogId);
    final finalFile = File(pathForCatalog(catalogId));
    final partFile = File('${finalFile.path}$_partSuffix');
    await Directory(modelsDir).create(recursive: true);

    if (await finalFile.exists()) {
      yield DownloadProgress(status: DownloadStatus.done, received: await finalFile.length(), total: await finalFile.length(), path: finalFile.path);
      await refresh();
      return;
    }

    var offset = await partFile.exists() ? await partFile.length() : 0;
    yield DownloadProgress(status: DownloadStatus.checking, received: offset, total: entry.sizeBytes);

    final req = http.Request('GET', Uri.parse(entry.url));
    if (offset > 0) req.headers['range'] = 'bytes=$offset-';
    final http.StreamedResponse res;
    try {
      res = await _client.send(req).timeout(const Duration(seconds: 30));
    } on TimeoutException {
      throw const AiProviderException('Waktu koneksi habis saat memulai unduhan', retriable: true);
    } on http.ClientException catch (e) {
      throw AiProviderException('Gagal terhubung: ${e.message}', retriable: true);
    }

    int? total;
    final contentLength = int.tryParse(res.headers['content-length'] ?? '') ?? res.contentLength;
    if (res.statusCode == 206) {
      total = _totalFromContentRange(res.headers['content-range']) ?? (contentLength == null ? null : offset + contentLength);
    } else if (res.statusCode == 200) {
      // Server mengabaikan Range: mulai dari awal.
      if (offset > 0) await partFile.writeAsBytes(const []);
      offset = 0;
      total = contentLength;
    } else if (res.statusCode == 416 && offset > 0) {
      // Range di luar ukuran: file .part kemungkinan sudah lengkap.
      await res.stream.drain<void>();
      yield* _finalize(entry, partFile, finalFile, offset);
      return;
    } else {
      final body = await res.stream.bytesToString();
      throw AiProviderException('Unduhan gagal (${res.statusCode}): ${body.length > 120 ? body.substring(0, 120) : body}',
          statusCode: res.statusCode, retriable: res.statusCode == 429 || res.statusCode >= 500);
    }

    if (freeSpaceProbe != null && total != null) {
      final free = await freeSpaceProbe!(modelsDir);
      final needed = (total - offset) + safetyMarginBytes;
      if (free < needed) {
        throw AiProviderException(
          'Ruang penyimpanan tidak cukup: butuh ${_fmtBytes(needed)}, tersedia ${_fmtBytes(free)}',
        );
      }
    }

    final sink = partFile.openWrite(mode: offset > 0 ? FileMode.append : FileMode.write);
    var received = offset;
    var cancelled = false;
    final controller = StreamController<List<int>>();
    final sub = res.stream.listen(controller.add, onError: controller.addError, onDone: controller.close);
    final cancelSub = cancel?.onCancel.listen((_) {
      cancelled = true;
      sub.cancel();
      if (!controller.isClosed) controller.close();
    });
    try {
      yield DownloadProgress(status: DownloadStatus.downloading, received: received, total: total);
      await for (final chunk in controller.stream) {
        sink.add(chunk);
        received += chunk.length;
        yield DownloadProgress(status: DownloadStatus.downloading, received: received, total: total);
      }
    } finally {
      await cancelSub?.cancel();
      await sink.flush();
      await sink.close();
    }
    if (cancelled || (cancel?.isCancelled ?? false)) {
      yield DownloadProgress(status: DownloadStatus.cancelled, received: received, total: total, path: partFile.path);
      return;
    }
    if (total != null && received < total) {
      throw AiProviderException('Koneksi terputus pada ${_fmtBytes(received)} dari ${_fmtBytes(total)}', retriable: true);
    }
    yield* _finalize(entry, partFile, finalFile, received);
  }

  Stream<DownloadProgress> _finalize(ModelCatalogEntry entry, File partFile, File finalFile, int size) async* {
    if (entry.sha256 != null) {
      yield DownloadProgress(status: DownloadStatus.verifying, received: size, total: size);
      final digest = await sha256File(partFile);
      if (digest.toLowerCase() != entry.sha256!.toLowerCase()) {
        await partFile.delete();
        throw const AiProviderException('Checksum SHA-256 tidak cocok; file dihapus, silakan unduh ulang');
      }
    }
    if (!await _hasGgufMagic(partFile)) {
      await partFile.delete();
      throw const AiProviderException('File yang diunduh bukan GGUF yang valid; file dihapus');
    }
    await partFile.rename(finalFile.path);
    await refresh();
    yield DownloadProgress(status: DownloadStatus.done, received: size, total: size, path: finalFile.path);
  }

  /// Mengimpor file GGUF pilihan pengguna ke direktori model. [sourcePath]
  /// opsional untuk melewati file picker (tes).
  Future<String> importGguf({String? sourcePath}) async {
    final src = sourcePath ?? await _pickFile();
    if (src == null) throw const AiProviderException('Tidak ada file yang dipilih');
    final file = File(src);
    if (!src.toLowerCase().endsWith('.gguf')) {
      throw const AiProviderException('File harus berekstensi .gguf');
    }
    if (!await file.exists()) throw const AiProviderException('File tidak ditemukan');
    if (!await _hasGgufMagic(file)) {
      throw const AiProviderException('File bukan GGUF yang valid (magic bytes tidak cocok)');
    }
    await Directory(modelsDir).create(recursive: true);
    final dest = p.join(modelsDir, p.basename(src));
    if (p.equals(dest, src)) {
      await refresh();
      return dest;
    }
    if (freeSpaceProbe != null) {
      final free = await freeSpaceProbe!(modelsDir);
      final needed = await file.length() + safetyMarginBytes;
      if (free < needed) {
        throw AiProviderException('Ruang penyimpanan tidak cukup: butuh ${_fmtBytes(needed)}, tersedia ${_fmtBytes(free)}');
      }
    }
    await file.copy(dest);
    await refresh();
    return dest;
  }

  Future<void> delete(String path) async {
    final f = File(path);
    if (await f.exists()) await f.delete();
    final part = File('$path$_partSuffix');
    if (await part.exists()) await part.delete();
    await refresh();
  }

  /// Menghapus unduhan parsial (`.part`) milik [catalogId].
  Future<void> discardPartial(String catalogId) async {
    final part = File('${pathForCatalog(catalogId)}$_partSuffix');
    if (await part.exists()) await part.delete();
    notifyListeners();
  }

  Future<int> partialBytes(String catalogId) async {
    final part = File('${pathForCatalog(catalogId)}$_partSuffix');
    return await part.exists() ? part.length() : 0;
  }

  static Future<bool> _hasGgufMagic(File f) async {
    if (await f.length() < 4) return false;
    final raf = await f.open();
    try {
      final head = await raf.read(4);
      return head.length == 4 && utf8.decode(head, allowMalformed: true) == 'GGUF';
    } finally {
      await raf.close();
    }
  }

  static Future<String> sha256File(File f) async {
    final digest = await sha256.bind(f.openRead()).first;
    return digest.toString();
  }

  static int? _totalFromContentRange(String? header) {
    if (header == null) return null;
    final m = RegExp(r'/(\d+)\s*$').firstMatch(header);
    return m == null ? null : int.tryParse(m.group(1)!);
  }

  static String _fmtBytes(int b) {
    if (b >= 1 << 30) return '${(b / (1 << 30)).toStringAsFixed(2)} GB';
    if (b >= 1 << 20) return '${(b / (1 << 20)).toStringAsFixed(1)} MB';
    return '${(b / 1024).toStringAsFixed(0)} KB';
  }

  static Future<String?> _defaultPickFile() async {
    final picked = await FilePicker.pickFile(type: FileType.any);
    return picked?.path;
  }
}
