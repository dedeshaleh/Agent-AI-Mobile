import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

/// Statistik performa untuk overlay: FPS Flutter, FPS/frame-time Unity
/// (dikirim lewat bridge), CPU % proses, RSS, nama GPU, tokens/s terakhir.
///
/// Android tidak membuka beban GPU ke aplikasi biasa; yang ditampilkan adalah
/// nama GPU dan waktu render per frame dari Unity.
class PerfMonitor extends ChangeNotifier {
  PerfMonitor() {
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _sample());
  }

  late final Timer _ticker;
  int _frames = 0;

  double flutterFps = 0;
  double unityFps = 0;
  double unityFrameMs = 0;
  String gpuName = '';
  double cpuPercent = 0;
  int rssBytes = 0;
  double tokensPerSecond = 0;
  double? uiFrameMs;

  int _lastCpuTicks = -1;
  DateTime _lastCpuAt = DateTime.now();
  static final int _cores = Platform.numberOfProcessors;
  static const _clockTicksPerSecond = 100; // Linux/Android default (CLK_TCK)

  bool get hasUnity => unityFps > 0;
  String get rssLabel => rssBytes >= 1 << 30 ? '${(rssBytes / (1 << 30)).toStringAsFixed(1)} GB' : '${rssBytes ~/ (1 << 20)} MB';

  void _onTimings(List<FrameTiming> timings) {
    _frames += timings.length;
    double total = 0;
    for (final t in timings) {
      total += t.totalSpan.inMicroseconds / 1000;
    }
    uiFrameMs = timings.isEmpty ? uiFrameMs : total / timings.length;
  }

  /// Dipanggil dari bridge Unity (`{"type":"stats",...}`).
  void updateUnity({required double fps, required double frameMs, String? gpu}) {
    unityFps = fps;
    unityFrameMs = frameMs;
    if (gpu != null && gpu.isNotEmpty) gpuName = gpu;
  }

  void updateTokensPerSecond(double value) {
    if (value > 0) tokensPerSecond = value;
  }

  void _sample() {
    flutterFps = _frames.toDouble();
    _frames = 0;
    rssBytes = ProcessInfo.currentRss;
    _sampleCpu();
    notifyListeners();
  }

  void _sampleCpu() {
    if (!Platform.isAndroid && !Platform.isLinux) return;
    try {
      final stat = File('/proc/self/stat').readAsStringSync();
      // Field 14 (utime) dan 15 (stime) setelah ")" nama proses.
      final rest = stat.substring(stat.lastIndexOf(')') + 2).split(' ');
      final ticks = int.parse(rest[11]) + int.parse(rest[12]);
      final now = DateTime.now();
      if (_lastCpuTicks >= 0) {
        final seconds = now.difference(_lastCpuAt).inMilliseconds / 1000;
        if (seconds > 0) {
          final used = (ticks - _lastCpuTicks) / _clockTicksPerSecond;
          cpuPercent = (used / seconds / _cores * 100).clamp(0, 100);
        }
      }
      _lastCpuTicks = ticks;
      _lastCpuAt = now;
    } on FileSystemException {
      // /proc tidak terbaca: biarkan nilai lama.
    } on FormatException {
      // Format tak terduga: abaikan sampel ini.
    }
  }

  @override
  void dispose() {
    _ticker.cancel();
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    super.dispose();
  }
}
