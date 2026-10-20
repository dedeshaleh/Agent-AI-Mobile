# AI di Agent HQ: model lokal tertanam + provider dengan API key

Mengikuti PRD v1.1 §6. Semua AI diakses lewat `AiProvider` dan `AiRouter` (`app/lib/ai/`); agent tidak pernah memanggil HTTP atau FFI langsung.

## Model lokal (default)

- Runtime: llama.cpp tag `b11727` di-compile menjadi `libagenthq_llama.so` (arm64-v8a, `-march=armv8.2-a+dotprod+fp16`, 16 KB page) dari `app/android/app/src/main/cpp/`. Dipanggil lewat `dart:ffi` dari satu Isolate pekerja (`LlamaFfiEngine`); UI tidak pernah memblokir.
- Satu model dimuat, satu inferensi aktif; agent lokal mengantre.
- Prompt memakai format ChatML Qwen3 dengan `/no_think`; blok `<think>` dibuang.
- Model **tidak** dibundel di APK. Menu **Model** di aplikasi mengunduh (resume + verifikasi) atau mengimpor `.gguf` lewat SAF. Model tersimpan di direktori privat aplikasi (`files/models/`).
- Parameter awal: context 2048, 4 thread, output 256 token. Ubah di **Pengaturan AI**; berlaku saat model dimuat ulang.

Rekomendasi: `Qwen3-1.7B-Q4_K_M` (≈1,1 GB) untuk uji awal, `Qwen3-4B-Q4_K_M` (≈2,5 GB) sebagai target PRD setelah benchmark.

### GPU (Vulkan)

- `libagenthq_llama.so` memuat dua backend ggml sekaligus: CPU (selalu) dan Vulkan (`GGML_VULKAN=ON`, opsi CMake `AGENTHQ_GPU_VULKAN`, default ON). Satu `.so`; `NEEDED` bertambah `libvulkan.so` (loader bawaan Android ≥ 7, ada di semua perangkat; driver GPU-lah yang mungkin tidak ada). Ukuran `.so` setelah strip: 4,0 MB (CPU saja) → 23,1 MB (CPU+Vulkan; 18 MB di antaranya blob shader SPIR-V). Bila ukuran APK jadi masalah, build dengan `-DAGENTHQ_GPU_VULKAN=OFF`.
- **Default CPU.** Di **Pengaturan AI → Parameter model lokal** pengguna memilih backend `CPU` / `GPU (Vulkan, eksperimental)` dan slider **Layer di GPU** (1–99; 99 = semua layer). Baris "Terdeteksi: Mali-G610 MC6, VRAM bersama" / "Tidak ada GPU Vulkan" berasal dari `agenthq_gpu_info()` yang membaca registry perangkat ggml (`ggml_backend_dev_*`) tanpa memuat model. Berlaku saat model dimuat ulang.
- Setelan disimpan di `AiSettings.useGpu` / `gpuLayers` (`use_gpu`, `gpu_layers` di JSON prefs). `AppController.loadActiveModel` mengirim `gpuLayers: useGpu ? gpuLayers : 0`.
- **Fallback otomatis.** Jika GPU diminta tetapi tidak ada perangkat Vulkan ≥ 1.2 (atau load/konteks GPU gagal), native mengembalikan `AGENTHQ_ERR_GPU_UNAVAILABLE` (-11), `LocalEngineException.isGpuUnavailable` menjadi true, dan controller memuat ulang dengan `gpuLayers: 0` lalu menampilkan "GPU tidak tersedia, memakai CPU". Setelan GPU tetap tersimpan. Exception Vulkan saat decode (device lost / OOM) dipetakan ke `AGENTHQ_ERR_DECODE`, bukan crash.
- Layar **Model** menampilkan `Backend: CPU 4 thread` atau `Backend: GPU Vulkan · 37 layer` (jumlah layer yang benar-benar di-offload = min(diminta, n_layer + 1), dari `agenthq_gpu_layers()` / `lastStats['gpu_layers']`). Pakai **Benchmark singkat** di CPU lalu GPU dan catat ke `docs/BENCHMARK.md`; keputusan default per perangkat mengikuti angka itu, bukan asumsi.
- Build: butuh compiler host untuk `vulkan-shaders-gen` (di PC ini WinLibs MinGW-w64 GCC via winget) dan `glslc` dari NDK; detail di `app/android/app/src/main/cpp/README.md`. Mali-G610 adalah GPU terintegrasi (`GGML_BACKEND_DEVICE_TYPE_IGPU`): memori "VRAM" adalah RAM bersama, jadi model 4B Q4 + KV cache tetap bersaing dengan Unity.
- Belum diverifikasi di perangkat: kecepatan token/s GPU vs CPU di Infinix X6871, suhu, dan dampak ke FPS game view.

## Provider eksternal (opsional)

| Jenis | Isi | Catatan |
|---|---|---|
| OpenAI-compatible | Base URL, API key, model id | OpenAI, OpenRouter, Groq, DeepSeek, LM Studio, Ollama (`/v1/chat/completions`) |
| Anthropic Claude | API key, model id | Messages API streaming; saran model dari skill `claude-api` |
| Google Gemini | API key, model id | `streamGenerateContent?alt=sse` |
| Custom / LAN | Base URL (+ key opsional) | HTTP hanya untuk loopback/LAN dan harus diizinkan di Pengaturan |

Model id tidak di-hardcode; disimpan di `ProviderConfig.modelId`. **Tes Koneksi** wajib berhasil sebelum provider dipakai.

### Mode

- `Offline Only` (default): tidak ada panggilan jaringan sama sekali. `AiRouter` tidak pernah membangun provider remote.
- `Hybrid`: remote hanya untuk agent yang ditugaskan; gagal → retry terbatas → fallback ke lokal (jika model dimuat) dan toast.
- `Cloud Preferred`: remote dulu, lokal sebagai cadangan.

### Keamanan

- API key hanya di `flutter_secure_storage` (Android Keystore), kunci `agenthq.apikey.<providerId>`. Tidak masuk SQLite/prefs/log/ekspor; `allowBackup=false` + `data_extraction_rules.xml` mengecualikan semua data dari backup.
- Ke cloud hanya dikirim **agregat** (`AnalysisResult.toFacts()`: jumlah baris, total, rata-rata, 5 produk teratas, ≤8 bulan terakhir), bukan baris mentah. Opsi "kirim baris mentah" per provider ada tetapi mati secara default.
- Sebelum panggilan cloud pertama per provider, aplikasi menampilkan pratinjau payload dan meminta persetujuan (bisa dicabut di Pengaturan AI).
- Setiap jawaban memakai lencana sumber: model lokal / nama provider / template.
- KPI tidak pernah dihasilkan model; model hanya merangkai narasi dari angka yang dihitung kode (`app/lib/data/`).

## Pemakaian

`UsageLog` mencatat token masuk/keluar per provider dan per misi ke `usage_log.json` di direktori privat; lihat dan hapus di Pengaturan AI.

## Belum diverifikasi

- Format wire Anthropic/Gemini/OpenAI diuji dengan MockClient, belum dengan panggilan nyata.
- Pemeriksaan ruang kosong sebelum unduh belum diimplementasikan di Android (dilewati).
