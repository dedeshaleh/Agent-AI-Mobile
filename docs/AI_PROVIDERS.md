# AI di Agent HQ: model lokal tertanam + provider dengan API key

Mengikuti PRD v1.1 §6. Semua AI diakses lewat `AiProvider` dan `AiRouter` (`app/lib/ai/`); agent tidak pernah memanggil HTTP atau FFI langsung.

## Model lokal (default)

- Runtime: llama.cpp tag `b11727` di-compile menjadi `libagenthq_llama.so` (arm64-v8a, `-march=armv8.2-a+dotprod+fp16`, 16 KB page) dari `app/android/app/src/main/cpp/`. Dipanggil lewat `dart:ffi` dari satu Isolate pekerja (`LlamaFfiEngine`); UI tidak pernah memblokir.
- Satu model dimuat, satu inferensi aktif; agent lokal mengantre.
- Prompt memakai format ChatML Qwen3 dengan `/no_think`; blok `<think>` dibuang.
- Model **tidak** dibundel di APK. Menu **Model** di aplikasi mengunduh (resume + verifikasi) atau mengimpor `.gguf` lewat SAF. Model tersimpan di direktori privat aplikasi (`files/models/`).
- Parameter awal: context 2048, 4 thread, output 256 token. Ubah di **Pengaturan AI**; berlaku saat model dimuat ulang.

Rekomendasi: `Qwen3-1.7B-Q4_K_M` (≈1,1 GB) untuk uji awal, `Qwen3-4B-Q4_K_M` (≈2,5 GB) sebagai target PRD setelah benchmark.

### GPU (Vulkan dan OpenCL) + pembagian beban GPU/CPU

- `libagenthq_llama.so` memuat tiga backend ggml sekaligus: CPU (selalu), Vulkan (`GGML_VULKAN=ON`, opsi CMake `AGENTHQ_GPU_VULKAN`, default ON) dan OpenCL (`GGML_OPENCL=ON`, opsi `AGENTHQ_GPU_OPENCL`, default ON). Satu `.so`; `NEEDED` hanya bertambah `libvulkan.so` (loader bawaan Android ≥ 7; **tidak ada** `NEEDED libOpenCL.so`, lihat di bawah). Ukuran `.so` setelah strip: 4,0 MB (CPU saja) → 23,1 MB (CPU+Vulkan) → 25,9 MB (CPU+Vulkan+OpenCL; tambahan ≈2,7 MB = sumber kernel OpenCL yang di-embed + ICD loader). Bila ukuran APK jadi masalah, build dengan `-DAGENTHQ_GPU_VULKAN=OFF` dan/atau `-DAGENTHQ_GPU_OPENCL=OFF`.
- **Kenapa OpenCL.** Driver Vulkan Mali-G610 di Infinix X6871 melapor apiVersion 1.1.219; ggml-vulkan butuh Vulkan 1.2, jadi backend Vulkan ditolak di perangkat ini. Driver OpenCL vendor (`/vendor/lib64/libOpenCL.so`, tercantum di `/vendor/etc/public.libraries.txt` sehingga boleh di-dlopen aplikasi) adalah OpenCL 3.0 dan menjadi jalur GPU yang realistis.
- **Cara OpenCL ditemukan saat runtime.** Tidak ada SDK OpenCL di NDK. Header diambil dari `KhronosGroup/OpenCL-Headers` dan pustaka dari `KhronosGroup/OpenCL-ICD-Loader` (keduanya tag `v2026.05.29`, FetchContent), loader di-link **statis** ke dalam `libagenthq_llama.so` (simbol `cl*` disembunyikan oleh `--exclude-libs,ALL`). Loader Khronos mencari driver lewat berkas `.icd` di `/system/vendor/Khronos/OpenCL/vendors` (tidak ada di kebanyakan HP) atau lewat variabel lingkungan `OCL_ICD_FILENAMES` (daftar pustaka dipisah `:`, di-`dlopen` langsung; dicek di `loader/icd.c`). `agenthq_llama.cpp` men-set `OCL_ICD_FILENAMES=libOpenCL.so` saat `llama_backend_init` pertama, sebelum panggilan CL apa pun (loader hanya mengenumerasi vendor sekali). Dipakai **soname polos**, bukan `/vendor/lib64/libOpenCL.so`: path absolut ke `/vendor` ditolak linker namespace aplikasi, sedangkan soname diselesaikan lewat namespace vendor karena ada di `public.libraries.txt`. Tidak perlu berkas `.icd`. Di perangkat tanpa driver, `dlopen` gagal → loader tidak punya platform → `clGetPlatformIDs` gagal → ggml-opencl tidak mendaftarkan perangkat dan `agenthq_gpu_info(2)` menjawab `reason:"Driver OpenCL tidak ditemukan"`; `.so` tetap bisa dimuat dan CPU tetap jalan. Syarat yang belum diverifikasi: driver Mali harus mendukung `cl_khr_icd` (mengekspor `clIcdGetPlatformIDsKHR`); driver ARM umumnya mendukungnya.
- **Patch ggml-opencl** (`cmake/patch-ggml-opencl.cmake`, diterapkan FetchContent seperti patch Vulkan). ggml-opencl b11727 ditulis untuk Adreno/Intel: (1) `ggml_opencl_is_device_supported` membuang GPU lain → diubah menjadi menerima dengan `GPU_FAMILY::UNKNOWN` (kernel generik); (2) `exit(1)` saat memuat kernel `gated_delta_net` di keluarga tak dikenal → dilewati dengan peringatan (kernel itu hanya untuk model Qwen3-Next); (3) `exit(1)` bila ada kernel yang gagal dikompilasi driver → menjadi `std::runtime_error` yang merambat keluar `llama_model_load_from_file` dan ditangkap shim → `AGENTHQ_ERR_GPU_UNAVAILABLE`, bukan proses mati. Build memakai `GGML_OPENCL_EMBED_KERNELS=ON` (tidak ada berkas `.cl` saat runtime) dan `GGML_OPENCL_USE_ADRENO_KERNELS=OFF`.
- **Cache kernel.** ggml mengompilasi ≈200 program OpenCL saat backend diinisialisasi (beberapa detik per load). Binary hasil kompilasi di-cache di `GGML_OPENCL_KERNEL_CACHE_DIR`; `LlamaFfiEngine(cacheDir:)` meneruskan `<files>/cl-cache` lewat `agenthq_set_cache_dir()` sebelum load pertama (tanpa itu ggml mencoba `/tmp` yang tidak ada di Bionic dan cache mati).
- **Pemilihan backend.** `agenthq_load(path, n_ctx, n_threads, n_batch, n_gpu_layers, backend)` dengan `backend` 0 = CPU, 1 = Vulkan, 2 = OpenCL. Shim tidak pernah mengenumerasi registry global ggml (itu akan menginisialisasi *semua* backend, dan ggml-vulkan di driver 1.1 crash); ia memanggil `ggml_backend_vk_reg()` / `ggml_backend_opencl_reg()` langsung dan memberi `llama_model_params.devices = {dev, NULL}` sehingga hanya backend terpilih yang hidup. Probe apiVersion Vulkan hanya untuk backend 1. `agenthq_gpu_info(backend, ...)` melaporkan per backend (`available/device/vram_mb/integrated/api_version/reason`); untuk OpenCL `api_version` = "OpenCL 3.0" dari `CL_DEVICE_VERSION`.
- **Default CPU.** Di **Pengaturan AI → Parameter model lokal**: SegmentedButton **CPU / Vulkan / OpenCL**, dua baris deteksi di bawahnya (mis. "Vulkan: GPU tidak bisa dipakai: Vulkan 1.1 (ggml butuh 1.2)" dan "OpenCL: Terdeteksi: Mali-G610 MC6, OpenCL 3.0, VRAM bersama") dari `LocalEngine.gpuInfo()` → `LocalGpuReport{vulkan, opencl}`. Lalu **Pembagian beban**: `CPU` (gpuLayers 0) · `Seimbang (GPU+CPU)` (setengah `n_layer` model yang dimuat, `LocalModelInfo.layerCount` dari `agenthq_model_layers()`; 18 bila belum diketahui) · `GPU penuh` (99), plus slider **Layer di GPU** (0–99) sebagai kontrol halus. `AiSettings.gpuLayers` tetap satu-satunya sumber kebenaran; `AiSettings.presetFor(gpuLayers)` / `layersForPreset(preset, layerCount:)` / `withGpuPreset()` memetakannya. Layer yang tidak di-offload tetap dihitung CPU dengan `n_threads` dari setelan (perilaku llama.cpp biasa) — GPU dan CPU bekerja bersama.
- Setelan disimpan di `AiSettings.gpuBackend` (`gpu_backend`: `cpu|vulkan|opencl`) dan `gpuLayers`. Prefs lama yang hanya punya `use_gpu: true` dimigrasi ke `vulkan`; `use_gpu` masih ditulis untuk kompatibilitas. `AppController.loadActiveModel` mengirim `gpuLayers` + `backend`.
- **Fallback otomatis.** Jika GPU diminta tetapi backend terpilih tidak punya perangkat (driver tidak ada, Vulkan < 1.2, ggml menolak perangkat, kernel gagal dikompilasi, load/konteks GPU gagal), native mengembalikan `AGENTHQ_ERR_GPU_UNAVAILABLE` (-11), `LocalEngineException.isGpuUnavailable` true, dan controller memuat ulang di CPU lalu menampilkan "GPU OpenCL tidak tersedia, memakai CPU" (menyebut backend). Setelan GPU tetap tersimpan. Exception backend saat decode dipetakan ke `AGENTHQ_ERR_DECODE`, bukan crash.
- Layar **Model** menampilkan `Backend: CPU 4 thread`, `Backend: OpenCL 37 layer` atau `Backend: OpenCL 18/36 layer + CPU 4 thread` (`LocalModelInfo.backendLabel`; layer yang benar-benar di-offload = min(diminta, n_layer + 1) dari `agenthq_gpu_layers()`, backend dari `agenthq_gpu_backend()`).
- **Uji otomatis** (tombol di layar Model, `GpuAutoTuner` di `lib/ai/local/gpu_auto_tuner.dart`, dipanggil `AppController.autoTune`): untuk backend GPU di setelan (atau GPU pertama yang terdeteksi bila setelan masih CPU) model aktif dimuat tiga kali — CPU, seimbang, GPU penuh — masing-masing menjalankan benchmark singkat yang sama dengan tombol **Benchmark singkat** (`AppController.runBenchmark`, 96 token), mencatat `gen_tokens_per_s`, memilih yang tercepat (seri → lebih sedikit layer GPU), menyimpannya ke `AiSettings` (backend + gpuLayers) dan memuat ulang dengan pilihan itu; tabel 3 baris (preset · tok/s · waktu) ditampilkan. Percobaan yang gagal (termasuk -11) dicatat "gagal" dan uji berlanjut; bisa dibatalkan; dialog RAM (`memoryWarningForActiveModel`) ditanya dulu. Catat hasilnya ke `docs/BENCHMARK.md`.
- Build: Vulkan butuh compiler host untuk `vulkan-shaders-gen` dan `glslc` dari NDK; OpenCL butuh `python3` di host (skrip embed kernel ggml). Detail di `app/android/app/src/main/cpp/README.md`. Mali-G610 adalah GPU terintegrasi: memori "VRAM" adalah RAM bersama, jadi model 4B Q4 + KV cache tetap bersaing dengan Unity.
- **Catatan Mali / belum diverifikasi di perangkat:** kernel ggml-opencl dioptimalkan untuk Adreno (subgroup 64) dan Intel (32); di Mali (subgroup 16, Valhall) jalur generiknya belum pernah diuji oleh upstream, jadi (a) ada kemungkinan satu-dua kernel gagal dikompilasi driver ARM → sekarang berujung fallback CPU, bukan crash, (b) kecepatan token/s OpenCL vs CPU vs hybrid di Infinix X6871 **belum diukur** — bisa saja lebih lambat dari CPU; pakai Uji otomatis dan jangan mengubah default sebelum ada angka, (c) suhu, FPS game view, dan waktu kompilasi kernel pertama (sebelum cache terisi) belum diukur, (d) dukungan `cl_khr_icd` driver Mali untuk ICD loader belum dikonfirmasi di perangkat.

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
