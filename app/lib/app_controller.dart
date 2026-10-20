import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart' show databaseFactory;

import 'agents/agent_profile.dart';
import 'agents/agent_role.dart';
import 'agents/mission_orchestrator.dart';
import 'perf/perf_monitor.dart';
import 'ai/ai_provider.dart';
import 'ai/ai_router.dart';
import 'ai/ai_settings.dart';
import 'ai/api_key_store.dart';
import 'ai/local/llama_ffi_engine.dart';
import 'ai/local/local_engine.dart';
import 'ai/model_manager.dart';
import 'ai/usage_log.dart';
import 'data/analysis_result.dart';
import 'data/data_advisor.dart';
import 'data/dataset_import.dart';
import 'data/dataset_store.dart';
import 'game_bridge/game_protocol.dart';
import 'ui/game_view.dart';

/// Komposisi seluruh layanan aplikasi. Satu instance per proses.
class AppController extends ChangeNotifier {
  AppController();

  late final LocalEngine engine;
  late final AiSettingsStore settingsStore;
  late final ApiKeyStore keyStore;
  late final UsageLog usage;
  late final AiRouter router;
  late final ModelManager models;
  late final GameBridge game;
  late final MissionOrchestrator mission;
  late final AgentProfileStore profiles;
  late final PerfMonitor perf;

  /// Overlay FPS/CPU/RAM di atas game; diingat antar sesi.
  bool get showPerf => _prefs.getBool('ui.show_perf') ?? true;
  Future<void> setShowPerf(bool v) async {
    await _prefs.setBool('ui.show_perf', v);
    notifyListeners();
  }
  late final DatasetStore datasets;
  late final SharedPreferences _prefs;
  late final Directory _supportDir;

  bool ready = false;
  String? startupError;

  AnalysisResult? analysis;
  bool analyzing = false;

  /// Dataset tersimpan di SQLite dan pilihan yang akan dianalisis bersama.
  List<DatasetInfo> datasetList = const [];
  final Set<int> selectedDatasets = {};
  bool importing = false;
  ImportProgress? importProgress;

  String question = '';
  String? answer;
  String? answerSource;
  bool answering = false;
  CancelToken? _answerCancel;

  final history = <MissionRecord>[];

  /// Dipasang oleh UI untuk menampilkan pratinjau payload sebelum panggilan
  /// cloud pertama (PRD §6.5). Mengembalikan true bila pengguna setuju.
  Future<bool> Function(String providerName, String payloadPreview)? consentPrompt;

  Future<void> init() async {
    try {
      _prefs = await SharedPreferences.getInstance();
      _supportDir = await getApplicationSupportDirectory();
      engine = LlamaFfiEngine();
      settingsStore = AiSettingsStore(_prefs);
      keyStore = SecureApiKeyStore();
      usage = UsageLog.file(p.join(_supportDir.path, 'usage_log.json'));
      await usage.load();
      router = AiRouter(
        settingsStore: settingsStore,
        keyStore: keyStore,
        localEngine: engine,
        httpClient: http.Client(),
        usageLog: usage,
      );
      models = ModelManager(modelsDir: p.join(_supportDir.path, 'models'), prefs: _prefs);
      await models.refresh();
      datasets = DatasetStore(databaseFactory, p.join(_supportDir.path, 'agenthq.db'));
      await datasets.open();
      datasetList = await datasets.list();
      game = createGameBridge();
      profiles = AgentProfileStore(_prefs);
      perf = PerfMonitor();
      mission = MissionOrchestrator(game: game, ai: router, profiles: profiles, perf: perf, onPersist: _persistMission);
      profiles.addListener(notifyListeners);
      mission.addListener(notifyListeners);
      settingsStore.addListener(notifyListeners);
      models.addListener(notifyListeners);
      engine.stateChanges.listen((_) => notifyListeners());
      await _loadHistory();
      ready = true;
      notifyListeners();
      // Model aktif dimuat di latar; tidak menunda UI.
      unawaited(loadActiveModel());
    } catch (e, st) {
      startupError = '$e';
      debugPrintStack(stackTrace: st, label: 'init');
      notifyListeners();
    }
  }

  AiSettings get settings => settingsStore.settings;

  String providerName(String? id) {
    if (id == null) return 'Template';
    if (id == ProviderConfig.localId) return 'Model lokal';
    return settings.providers.where((c) => c.id == id).map((c) => c.name).firstOrNull ?? id;
  }

  // ---------------------------------------------------------------- model

  Future<String?> loadActiveModel() async {
    final path = models.activeModelPath;
    if (path == null || !File(path).existsSync()) return 'Belum ada model aktif. Buka menu Model.';
    try {
      await engine.load(path, contextLength: settings.contextLength, threads: settings.threads);
      return null;
    } on LocalEngineException catch (e) {
      return e.message;
    } catch (e) {
      return '$e';
    }
  }

  Future<void> unloadModel() => engine.unload();

  // ---------------------------------------------------------------- data

  /// Jalur lama satu berkas: tetap disimpan ke SQLite lalu dianalisis.
  /// Mengembalikan pesan error, atau null bila sukses / dibatalkan.
  Future<String?> pickAndAnalyze() async {
    final file = await FilePicker.pickFile(
      dialogTitle: 'Pilih file CSV atau Excel',
      type: FileType.custom,
      allowedExtensions: const ['csv', 'xlsx'],
    );
    if (file == null) return null;
    final outcome = await _import([file]);
    if (outcome.okCount == 0) return outcome.files.first.error;
    return analyzeSelectedDatasets();
  }

  /// Memilih banyak berkas, menyimpan masing-masing ke SQLite. Null bila
  /// pengguna membatalkan. Berkas yang berhasil menjadi pilihan aktif.
  Future<ImportOutcome?> importDatasets() async {
    if (importing) return null;
    final files = await FilePicker.pickFiles(
      dialogTitle: 'Pilih file CSV atau Excel (bisa lebih dari satu)',
      type: FileType.custom,
      allowedExtensions: const ['csv', 'xlsx'],
    );
    if (files.isEmpty) return null;
    return _import(files);
  }

  Future<ImportOutcome> _import(List<PlatformFile> files) async {
    importing = true;
    importProgress = null;
    notifyListeners();
    try {
      // SAF biasanya memberi content:// URI tanpa path; XFile membaca keduanya.
      final sources = <PickedSource>[
        for (final f in files) (name: f.name, readBytes: () => f.xFile.readAsBytes()),
      ];
      final outcome = await importFiles(datasets, sources, onProgress: (progress) {
        importProgress = progress;
        notifyListeners();
      });
      datasetList = await datasets.list();
      if (outcome.okCount > 0) {
        selectedDatasets
          ..clear()
          ..addAll(outcome.datasetIds);
      }
      return outcome;
    } finally {
      importing = false;
      importProgress = null;
      notifyListeners();
    }
  }

  /// Menghitung [analysis] dari dataset terpilih lewat SQL. Mengembalikan
  /// pesan error, atau null bila sukses.
  Future<String?> analyzeSelectedDatasets() async {
    final ids = datasetList.map((d) => d.id).where(selectedDatasets.contains).toList();
    if (ids.isEmpty) return 'Pilih minimal satu dataset.';
    analyzing = true;
    answer = null;
    answerSource = null;
    notifyListeners();
    try {
      final result = await datasets.analyze(ids);
      analysis = result;
      return result.ok ? null : result.error;
    } catch (e) {
      analysis = null;
      return 'Analisis gagal: $e';
    } finally {
      analyzing = false;
      notifyListeners();
    }
  }

  void toggleDataset(int id, bool selected) {
    if (selected) {
      selectedDatasets.add(id);
    } else {
      selectedDatasets.remove(id);
    }
    notifyListeners();
  }

  void selectAllDatasets() {
    selectedDatasets.addAll(datasetList.map((d) => d.id));
    notifyListeners();
  }

  Future<void> deleteDataset(int id) async {
    await datasets.delete(id);
    selectedDatasets.remove(id);
    datasetList = await datasets.list();
    notifyListeners();
  }

  Future<void> deleteAllDatasets() async {
    await datasets.deleteAll();
    selectedDatasets.clear();
    datasetList = const [];
    notifyListeners();
  }

  void clearAnalysis() {
    analysis = null;
    answer = null;
    notifyListeners();
  }

  // ---------------------------------------------------------------- Q&A

  Future<void> ask(String text) async {
    final data = analysis;
    if (data == null || !data.ok || text.trim().isEmpty) return;
    question = text.trim();
    answering = true;
    answer = null;
    answerSource = null;
    notifyListeners();
    if (DataAdvisor.canAnswerLocally(question)) {
      answer = DataAdvisor.answer(question, data);
      answerSource = null;
      answering = false;
      notifyListeners();
      return;
    }
    final facts = jsonEncode(data.toFacts());
    if (!await _consentFor(AgentRole.data, facts)) {
      answer = 'Pengiriman ke provider cloud dibatalkan. ${DataAdvisor.answer(question, data)}';
      answering = false;
      notifyListeners();
      return;
    }
    _answerCancel?.cancel();
    final cancel = _answerCancel = CancelToken();
    final buffer = StringBuffer();
    try {
      answerSource = router.providerIdFor(AgentRole.data);
      await for (final chunk in router.chat(
        AgentRole.data,
        AiRequest(
          messages: [
            const AiMessage.system(
              'Kamu Agent Data. Jawab dalam bahasa Indonesia berdasarkan fakta ringkas workbook yang diberikan. '
              'Jangan mengarang angka atau mengklaim ada kolom yang tidak tersedia. Jika fakta tidak cukup, katakan apa yang kurang. '
              'Berikan masukan analisis yang spesifik dan singkat.',
            ),
            AiMessage.user('Ringkasan data (agregat lokal): $facts\nPertanyaan/perintah: $question'),
          ],
          maxTokens: settings.maxTokens,
          temperature: 0.2,
        ),
        cancel: cancel,
        onFallback: (id, _) => answerSource = id,
      )) {
        if (cancel.isCancelled) return;
        buffer.write(chunk.text);
        answer = buffer.toString();
        notifyListeners();
      }
      if (buffer.isEmpty) {
        answer = 'Model tidak memberi jawaban. ${DataAdvisor.answer(question, data)}';
        answerSource = null;
      }
    } catch (e) {
      answer = 'Model belum tersedia (${_short('$e')}). ${DataAdvisor.answer(question, data)}';
      answerSource = null;
    } finally {
      if (identical(cancel, _answerCancel)) {
        answering = false;
        notifyListeners();
      }
    }
  }

  // ---------------------------------------------------------------- missions

  Future<bool> startMission() async {
    final data = analysis;
    if (data == null || !data.ok || mission.busy) return false;
    final facts = jsonEncode(data.toFacts());
    for (final role in [AgentRole.strategist, AgentRole.reporter]) {
      if (!await _consentFor(role, facts)) return false;
    }
    unawaited(mission.startMission(data));
    return true;
  }

  Future<void> startDemoMeeting() => mission.startDemoMeeting();

  /// Pratinjau + persetujuan untuk provider cloud; diingat per provider.
  Future<bool> _consentFor(AgentRole role, String payload) async {
    if (settings.mode == AiMode.offlineOnly) return true;
    final id = router.providerIdFor(role);
    if (id == ProviderConfig.localId) return true;
    if (_prefs.getBool('consent.$id') == true) return true;
    final prompt = consentPrompt;
    if (prompt == null) return false;
    final ok = await prompt(providerName(id), payload);
    if (ok) await _prefs.setBool('consent.$id', true);
    return ok;
  }

  Future<void> forgetConsents() async {
    for (final key in _prefs.getKeys().where((k) => k.startsWith('consent.'))) {
      await _prefs.remove(key);
    }
  }

  File get _historyFile => File(p.join(_supportDir.path, 'missions.json'));

  Future<void> _persistMission(MissionRecord record) async {
    history.insert(0, record);
    if (history.length > 20) history.removeRange(20, history.length);
    await _historyFile.writeAsString(jsonEncode(history.map((m) => m.toJson()).toList()));
    notifyListeners();
  }

  Future<void> _loadHistory() async {
    if (!_historyFile.existsSync()) return;
    try {
      final list = jsonDecode(await _historyFile.readAsString()) as List;
      history
        ..clear()
        ..addAll(list.cast<Map<String, Object?>>().map(MissionRecord.fromJson));
    } catch (_) {
      // Riwayat rusak tidak boleh menghalangi aplikasi.
    }
  }

  Future<void> clearHistory() async {
    history.clear();
    if (_historyFile.existsSync()) await _historyFile.delete();
    notifyListeners();
  }

  static String _short(String s) => s.length > 100 ? '${s.substring(0, 97)}…' : s;

  @override
  void dispose() {
    mission.dispose();
    game.dispose();
    unawaited(datasets.close());
    super.dispose();
  }
}

void unawaited(Future<void> f) {}
