import 'dart:convert';
import 'dart:io';

import 'package:agent_hq/ai/ai_provider.dart';
import 'package:agent_hq/ai/model_manager.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';

/// Server palsu yang menghormati header Range dan bisa memutus koneksi.
class _RangeServer {
  _RangeServer(this.bytes);
  final List<int> bytes;
  int? cutAfter;
  final rangesSeen = <String?>[];

  Future<http.Response> handle(http.Request req) async {
    rangesSeen.add(req.headers['range']);
    final range = req.headers['range'];
    var start = 0;
    if (range != null) {
      start = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
      if (start >= bytes.length) return http.Response('', 416);
    }
    var end = bytes.length;
    if (cutAfter != null && start + cutAfter! < end) end = start + cutAfter!;
    final body = bytes.sublist(start, end);
    return http.Response.bytes(
      body,
      range == null ? 200 : 206,
      headers: {
        'content-length': '${bytes.length - start}',
        if (range != null) 'content-range': 'bytes $start-${bytes.length - 1}/${bytes.length}',
      },
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;
  late SharedPreferences prefs;
  final payload = [...utf8.encode('GGUF'), ...List.generate(5000, (i) => i % 251)];

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    tmp = await Directory.systemTemp.createTemp('agenthq_models');
  });
  tearDown(() => tmp.delete(recursive: true));

  ModelManager manager(http.Client client, {Future<int> Function(String)? probe, String? sha}) => ModelManager(
        modelsDir: p.join(tmp.path, 'models'),
        client: client,
        prefs: prefs,
        freeSpaceProbe: probe,
        safetyMarginBytes: 0,
        catalog: [
          ModelCatalogEntry(id: 'tiny', name: 'Tiny', sizeBytes: 5004, url: 'https://files.example.com/tiny.gguf', sha256: sha),
        ],
      );

  test('download terputus lalu resume via Range, verifikasi sha256', () async {
    final server = _RangeServer(payload)..cutAfter = 2000;
    final client = CountingClient(server.handle);
    final mm = manager(client, sha: sha256.convert(payload).toString());

    await expectLater(
      mm.download('tiny').last,
      throwsA(isA<AiProviderException>().having((e) => e.retriable, 'retriable', true)),
    );
    expect(await mm.partialBytes('tiny'), 2000);
    expect(mm.isInstalled('tiny'), isFalse);

    server.cutAfter = null;
    final progress = await mm.download('tiny').toList();
    expect(server.rangesSeen.last, 'bytes=2000-');
    expect(progress.last.done, isTrue);
    expect(progress.last.received, payload.length);
    expect(progress.any((x) => x.status == DownloadStatus.verifying), isTrue);
    expect(mm.isInstalled('tiny'), isTrue);
    expect(mm.installed.single.sizeBytes, payload.length);
    expect(await File(mm.pathForCatalog('tiny')).readAsBytes(), payload);
    expect(await mm.partialBytes('tiny'), 0);
  });

  test('sha256 salah: file dihapus dan error jelas', () async {
    final mm = manager(CountingClient(_RangeServer(payload).handle), sha: 'deadbeef');
    await expectLater(mm.download('tiny').last, throwsA(isA<AiProviderException>().having((e) => e.message, 'msg', contains('SHA-256'))));
    expect(mm.isInstalled('tiny'), isFalse);
    expect(await mm.partialBytes('tiny'), 0);
  });

  test('ruang tidak cukup menolak sebelum menulis', () async {
    final mm = manager(CountingClient(_RangeServer(payload).handle), probe: (_) async => 10);
    await expectLater(mm.download('tiny').last, throwsA(isA<AiProviderException>().having((e) => e.message, 'msg', contains('Ruang'))));
    expect(await mm.partialBytes('tiny'), 0);
  });

  test('cancel menyimpan .part', () async {
    final mm = manager(CountingClient(_RangeServer(payload).handle));
    final cancel = CancelToken();
    final events = <DownloadProgress>[];
    await for (final e in mm.download('tiny', cancel: cancel)) {
      events.add(e);
      if (e.status == DownloadStatus.downloading && e.received > 0) cancel.cancel();
    }
    expect(events.last.status, DownloadStatus.cancelled);
    expect(mm.isInstalled('tiny'), isFalse);
  });

  test('importGguf memvalidasi ekstensi dan magic bytes, activeModelPath persisten', () async {
    final mm = manager(CountingClient((_) async => http.Response('', 404)));
    final good = File(p.join(tmp.path, 'good.gguf'))..writeAsBytesSync(payload);
    final badMagic = File(p.join(tmp.path, 'bad.gguf'))..writeAsBytesSync(utf8.encode('NOPE1234'));
    final badExt = File(p.join(tmp.path, 'x.bin'))..writeAsBytesSync(payload);

    expect(() => mm.importGguf(sourcePath: badExt.path), throwsA(isA<AiProviderException>()));
    expect(() => mm.importGguf(sourcePath: badMagic.path), throwsA(isA<AiProviderException>().having((e) => e.message, 'msg', contains('magic'))));
    final dest = await mm.importGguf(sourcePath: good.path);
    expect(p.basename(dest), 'good.gguf');
    expect(mm.installed.single.path, dest);

    await mm.setActiveModel(dest);
    expect(mm.activeModelPath, dest);
    expect(mm.activeModel?.name, 'good.gguf');
    await mm.delete(dest);
    expect(mm.installed, isEmpty);
    expect(mm.activeModelPath, isNull);
  });

  test('katalog bawaan berisi Qwen3 1.7B dan 4B', () {
    expect(kModelCatalog.map((c) => c.fileName), ['Qwen3-1.7B-Q4_K_M.gguf', 'Qwen3-4B-Q4_K_M.gguf']);
  });
}
