import 'dart:io';

/// Memori sistem dari `/proc/meminfo` (kB → byte). Null bila tidak terbaca.
class SystemMemory {
  const SystemMemory({required this.totalBytes, required this.availableBytes, required this.swapUsedBytes});
  final int totalBytes;

  /// `MemAvailable`: perkiraan RAM yang bisa dipakai tanpa swap.
  final int availableBytes;
  final int swapUsedBytes;

  static SystemMemory? read() {
    try {
      final lines = File('/proc/meminfo').readAsLinesSync();
      int kb(String key) {
        final line = lines.firstWhere((l) => l.startsWith('$key:'), orElse: () => '');
        if (line.isEmpty) return 0;
        return int.tryParse(RegExp(r'\d+').firstMatch(line)?.group(0) ?? '') ?? 0;
      }

      return SystemMemory(
        totalBytes: kb('MemTotal') * 1024,
        availableBytes: kb('MemAvailable') * 1024,
        swapUsedBytes: (kb('SwapTotal') - kb('SwapFree')) * 1024,
      );
    } on FileSystemException {
      return null;
    }
  }

  /// Model butuh ruang untuk bobot (mmap) + KV cache/buffer ≈ 1 GB.
  bool fitsModel(int modelBytes) => availableBytes >= modelBytes + (1 << 30);

  String get availableLabel => '${(availableBytes / (1 << 30)).toStringAsFixed(1)} GB';
}

/// Informasi CPU perangkat untuk menyetel thread inferensi.
///
/// SoC ponsel umumnya big.LITTLE: llama.cpp membagi kerja rata ke semua
/// thread dan menunggu yang paling lambat, jadi thread > jumlah core besar
/// justru memperlambat (Dimensity 8200: 4×A78 + 4×A55 → pakai 4).
class DeviceCpuInfo {
  DeviceCpuInfo._(this.totalCores, this.bigCores, this.maxFreqKhz);

  final int totalCores;

  /// Core dengan frekuensi maksimum ≥ 80% dari core tercepat.
  final int bigCores;
  final List<int> maxFreqKhz;

  /// Thread yang disarankan untuk llama.cpp.
  int get recommendedThreads => bigCores.clamp(2, 8);

  static DeviceCpuInfo? _cached;

  static DeviceCpuInfo detect() {
    if (_cached != null) return _cached!;
    final total = Platform.numberOfProcessors;
    final freqs = <int>[];
    for (var i = 0; i < total; i++) {
      try {
        final raw = File('/sys/devices/system/cpu/cpu$i/cpufreq/cpuinfo_max_freq').readAsStringSync().trim();
        freqs.add(int.parse(raw));
      } on FileSystemException {
        break;
      } on FormatException {
        break;
      }
    }
    int big;
    if (freqs.length == total && freqs.isNotEmpty) {
      final fastest = freqs.reduce((a, b) => a > b ? a : b);
      big = freqs.where((f) => f >= fastest * 0.8).length;
    } else {
      // Tanpa info frekuensi (mis. Windows saat tes): anggap separuh core besar.
      big = (total / 2).ceil().clamp(2, total);
    }
    return _cached = DeviceCpuInfo._(total, big, freqs);
  }
}
