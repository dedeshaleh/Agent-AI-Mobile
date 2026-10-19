# PRD & Technical Blueprint — AI Agent HQ Android Offline

**Versi:** 1.2 (2026-10-19 — host Flutter, AI embedded full lokal, provider AI eksternal via API key, game layer **Unity** menggantikan Godot)  
**Target:** Infinix X6871, Android 15 / XOS 15.1.2, Dimensity 8200 Ultimate, RAM fisik 12 GB, storage 256 GB  
**Tujuan:** Game simulasi kantor AI 2D isometric dengan 4–8 karakter agent yang bergerak, meeting, menganalisis file pengguna, dan menghasilkan laporan secara lokal.

> Dokumen ini adalah spesifikasi implementasi. **Perubahan v1.1:** aplikasi host menjadi **Flutter**; LLM lokal di-embed langsung di APK Flutter (tanpa Termux/server terpisah) dan pengguna dapat menambahkan AI lain melalui API key (lihat §6). **Perubahan v1.2:** game layer dibuat dengan **Unity 6.3 LTS** yang ditanam ke Flutter lewat `flutter_embed_unity`; proyek Godot (`game/`) menjadi referensi Fase 1–2 saja. Jangan mengganti game interaktif dengan gambar statis atau mockup. Semua pekerjaan harus dapat diuji pada perangkat Android nyata.

## 1. Prinsip produk

- **Offline-first:** seluruh fungsi inti dapat berjalan tanpa internet setelah model dan dependensi dipasang.
- **Game sungguhan:** robot bergerak mengikuti path, masuk ruangan, duduk, mengetik, berbicara, dan kembali bekerja.
- **Satu model, banyak agent:** 4 agent memiliki identitas, prompt, tools, memori tugas, dan state berbeda; semua memakai satu instance LLM dengan antrean inferensi.
- **Deterministik untuk angka:** perhitungan KPI dilakukan oleh kode/SQL, bukan dikarang oleh LLM.
- **Keamanan lokal:** file pengguna diproses dalam sandbox aplikasi; tool sensitif membutuhkan persetujuan.
- **Skalabilitas:** 4 agent MVP; 8 agent setelah profiling.
- **AI embedded:** LLM lokal berjalan di dalam APK Flutter (llama.cpp via FFI), bukan proses/server eksternal. Mode default **Offline Only**.
- **Bring-your-own AI:** pengguna boleh menambah provider AI lain (OpenAI-compatible, Claude, Gemini, endpoint kustom) dengan API key miliknya sendiri; selalu opt-in dan bisa dimatikan total.

## 2. Spesifikasi perangkat & batasan

| Sumber daya | Kondisi | Keputusan |
|---|---|---|
| CPU | Dimensity 8200 Ultimate | Inferensi CPU baseline; ukur kecepatan nyata |
| GPU | Mali-G610 | Prioritas render 2D isometric; jangan asumsikan akselerasi LLM |
| RAM | 12 GB fisik | Anggaran ketat, hindari 4 model terpisah |
| MemFusion | 12 GB virtual | **Bukan** RAM fisik/VRAM tambahan; tidak dijadikan syarat |
| Storage | 256 GB total; sisa dari screenshot sebelumnya ~55 GB | Model GGUF dan cache dibatasi, pantau ruang bebas |
| OS | Android 15 | Validasi izin file, lifecycle, background restriction, ABI arm64-v8a |

**Target awal (hipotesis yang wajib dibenchmark):** Godot 2D 30 FPS, satu Qwen3 4B quantized Q4, context 2k–4k token, 4 agent yang dijadwalkan secara serial, pemrosesan dataset ukuran kecil-menengah. Tidak menjamin latency, FPS, atau pemakaian RAM sebelum uji perangkat.

## 3. Fitur game dan ruangan

### 3.1 Peta kantor isometric

Empat ruangan yang tersambung dengan koridor dan pintu:

1. **Ruang Data:** upload file, validasi, cleaning, metadata dataset.
2. **Ruang Analisis:** query, agregasi, grafik, KPI, deteksi anomali sederhana.
3. **Ruang Meeting:** meja rapat, kursi, antrean giliran bicara, notulen, keputusan.
4. **Ruang Laporan:** membuat dan meninjau laporan PDF/Excel serta ekspor.

Peta dibuat dengan TileMapLayer, AnimatedSprite2D, NavigationRegion2D/NavigationAgent2D atau AStarGrid2D yang cocok dengan tile isometric. Atur Y-sorting, collision, door waypoint, dan seat reservation agar robot tidak saling menumpuk.

### 3.2 Karakter agent

| Agent | Warna | Fungsi utama | Ruang kerja |
|---|---|---|---|
| Data | Biru | Baca, validasi, bersihkan CSV/Excel | Data |
| Analyst | Hijau | KPI, agregasi, tren, grafik | Analisis |
| Strategist | Oranye | Interpretasi hasil, risiko, rekomendasi | Meeting/Analisis |
| Reporter | Pink | Ringkasan, notulen, PDF/Excel | Laporan |

Animasi minimal: `idle`, `walk_up`, `walk_down`, `walk_left`, `walk_right`, `sit`, `typing`, `talk`, `thinking`, `meeting`, `celebrate`, `error`. Tidak perlu memanggil LLM untuk animasi.

### 3.3 Interaksi pemain

- Tap robot: detail identitas, pekerjaan, status, log, tombol instruksi.
- Tap ruangan: fokus kamera dan daftar agent di dalamnya.
- Tombol **Upload Data**, **Mulai Misi**, **Panggil Meeting**, **Pause/Resume**, **Lihat Laporan**.
- Pengaturan kecepatan animasi x1/x2 hanya memengaruhi animasi/simulasi, **bukan** kecepatan inferensi model.
- Toast dan dialog kesalahan jelas jika model belum terpasang atau file tidak valid.

## 4. Contoh alur misi end-to-end

1. Pemain memilih `penjualan_2025.xlsx` lewat Android Storage Access Framework.
2. File disalin ke direktori privat aplikasi, diperiksa tipe, ukuran, sheet, kolom, dan jumlah baris.
3. Agent Data berjalan ke Ruang Data, memvalidasi schema dan membuat dataset terstruktur.
4. Agent Analyst berjalan ke Ruang Analisis; mesin data menghitung revenue, qty, produk, tren, dan grafik.
5. Agent Strategist menyusun interpretasi berdasarkan **hasil angka yang sudah dihitung**.
6. Tombol Meeting atau auto-meeting setelah tahap analisis: 4 robot berjalan ke Ruang Meeting, duduk, berbicara bergantian. Tampilkan chat bubble dan transkrip rapat.
7. Meeting menghasilkan action items, keputusan, dan daftar keterbatasan data.
8. Agent Reporter kembali ke Ruang Laporan, menyusun PDF/Excel dari hasil tervalidasi.
9. Pemain melihat preview dan menyimpan/berbagi file melalui Android share sheet / SAF.

**Contoh KPI:** total revenue = `SUM(qty * harga - diskon)` jika kolom sesuai; total qty, produk unik, penjualan per periode, top/bottom produk. Jika file sudah memiliki kolom revenue, tentukan aturan prioritas dan tampilkan mapping agar tidak double-count.

## 5. Arsitektur teknis

```text
Flutter Android APK (host app: navigasi, panel, chat, pengaturan AI, file picker)
  |
  +--> Game View: Unity 6.3 embedded (flutter_embed_unity, §6.2) <-- JSON --+
  |                                                                         |
  v                                                                         |
Agent Orchestrator (Dart: queue, workflow, tools, approvals) ---------------+
  |                       |
  |                       +--> Dataset Engine (CSV/Excel, SQL, chart data)
  |                       +--> Report Engine (PDF/Excel)
  |                       +--> SQLite (missions, agent states, logs, usage)
  v
AI Router (pilih provider per agent, fallback, mode Offline/Hybrid)
  |
  +--> LocalLlamaProvider: llama.cpp arm64 (.so di APK) via dart:ffi, Isolate terpisah
  |        +--> Qwen3 4B / 1.7B GGUF Q4 (satu model dimuat)
  |
  +--> Remote providers (opsional, API key pengguna, HTTPS)
           +--> OpenAI-compatible | Anthropic Claude | Google Gemini | Custom base URL
```

**Keputusan v1.1:** target produksi adalah **satu APK Flutter standalone** yang memuat runtime llama.cpp sendiri. Python/FastAPI dan Termux tidak dipakai di produksi.

- **Target produksi:** Flutter + llama.cpp (library native arm64-v8a) dipanggil lewat `dart:ffi` dari Isolate terpisah. Detail di §6.
- **Prototipe developer (lama):** Godot + Termux `llama-server` di `127.0.0.1` (lihat `docs/LLM_PHONE.md`). Tetap boleh dipakai untuk benchmark awal, tetapi **bukan** jalur rilis.

**Keputusan milestone:** buktikan dulu inferensi Qwen3 4B Q4 **di dalam aplikasi Flutter** di HP dengan benchmark RAM, tokens/s, thermal, dan stabilitas, termasuk saat game view terbuka. Jangan menjanjikan APK offline penuh sebelum spike ini lulus.

## 6. AI embedded di Flutter & provider AI eksternal

### 6.1 Tujuan

1. AI berjalan **full lokal di HP**: tidak butuh internet, Termux, PC, atau server setelah model terpasang.
2. AI tertanam di aplikasi Flutter: load/unload model, streaming token, dan pembatalan dikendalikan dari aplikasi.
3. Pengguna dapat **menambahkan AI lain dengan API key** dan memilih model mana yang dipakai tiap agent, tanpa mengubah alur misi atau kontrak tools.

### 6.2 Flutter sebagai host & posisi game

Flutter memegang UI aplikasi, chat advisor, pengaturan AI, manajer model, file picker (SAF), dan orchestrator. Untuk layer game ada dua opsi yang diputuskan lewat spike:

| Opsi | Cara | Kelebihan | Risiko |
|---|---|---|---|
| **G1 — Unity embedded** (**dipilih, v1.2**) | Proyek Unity 6.3 LTS (`unity/AgentHQ`, URP, IL2CPP, ARM64) diekspor sebagai `unityLibrary` dan ditampilkan lewat widget `EmbedUnity` dari plugin `flutter_embed_unity` (MIT). Flutter mengirim perintah JSON (`walkTo`, `setState`, `speak`, `meeting`, …) ke GameObject `FlutterBridge`; Unity mengirim event (`ready`, `arrived`, `agentTapped`, `roomTapped`, `meetingSeated`). Grid, ruangan, kursi, dan A* diport 1:1 dari `game/scripts/office_map.gd`. | Engine matang, tooling kuat, aset 3D/2D mudah ditambah; logika game teruji dengan EditMode test. | Dua engine dalam satu proses (RAM bersaing dengan LLM); plugin memakai API Unity tak terdokumentasi sehingga versi Unity/Flutter/AGP harus dipin; hanya satu widget Unity per layar; Unity tetap di memori setelah dimuat. |
| **G2 — Flame (cadangan)** | Peta isometric, agent, dan meeting ditulis ulang dengan Flame (Dart). | Satu engine, tanpa bridge, APK lebih kecil. | Menulis ulang game; pathfinding/collision perlu diverifikasi ulang. |

**Kriteria tetap dipantau:** dengan Qwen3 4B Q4 dimuat, game view stabil ≥30 FPS, tidak OOM, dan pause/resume aman. Bila G1 gagal, pindah ke G2. Logika data GDScript (`csv_analyzer`, `xlsx_reader`, `data_advisor`) **sudah diport ke Dart** (`app/lib/data`) dengan fixture tes yang sama. Tanpa export Unity, aplikasi memakai `SimulatedGameBridge` (papan status) agar alur misi tetap dapat diuji; itu bukan pengganti game.

### 6.3 Runtime LLM lokal (embedded)

- **Engine:** llama.cpp di-build sebagai shared library `arm64-v8a` dan dibundel di APK; dipanggil via `dart:ffi` (boleh memakai paket binding yang ada setelah dievaluasi lisensi dan versinya, atau binding tipis buatan sendiri). Alternatif yang boleh dibandingkan di spike: MediaPipe / LiteRT LLM Inference (format model berbeda).
- **Isolate terpisah:** load model, prompt processing, dan generate tidak pernah di UI isolate. Token di-stream ke UI lewat `Stream` dan di-batch (mis. tiap 50–100 ms), bukan per frame.
- **Satu model, satu inferensi aktif:** model dimuat sekali dan dipakai bergantian oleh semua agent lokal via antrean prioritas (§7). Mendukung cancel, timeout, dan unload saat memori tertekan (`onTrimMemory`).
- **Parameter awal:** context 2048 (naik ke 4096 setelah benchmark), output 256–512 token, 4 thread, CPU-only. GPU/NPU hanya setelah profiling.
- **Structured output:** gunakan grammar/JSON schema llama.cpp untuk output agent agar valid secara struktur.
- **Model tidak dibundel di APK.** Manajer model di aplikasi:
  - Unduh dari daftar URL yang dikurasi (mis. Hugging Face) dengan resume, verifikasi SHA-256, dan cek sisa storage sebelum unduh.
  - Atau impor file `.gguf` lokal lewat SAF (sepenuhnya offline).
  - Daftar model terpasang, ukuran, model aktif, hapus model.
  - Rekomendasi default: Qwen3 1.7B Q4_K_M (aman), Qwen3 4B Q4_K_M (target PRD).
- **Offline penuh:** setelah model ada di storage privat aplikasi, seluruh fitur AI lokal berjalan dalam mode pesawat.

### 6.4 Provider AI eksternal via API key

Semua AI diakses lewat satu antarmuka sehingga orchestrator tidak perlu tahu apakah model lokal atau cloud:

```dart
abstract class AiProvider {
  String get id;            // "local-llama", "openai", "anthropic", ...
  bool get isLocal;
  AiCapabilities get caps;  // streaming, jsonSchema, contextWindow
  Stream<AiChunk> chat(AiRequest req, {CancelToken? cancel});
  Future<HealthResult> healthCheck();
}
```

| Jenis provider | Konfigurasi pengguna | Catatan |
|---|---|---|
| Lokal (llama.cpp) | Pilih model GGUF | Default, selalu tersedia bila model terpasang |
| OpenAI-compatible | Base URL, API key, model id | Mencakup OpenAI, OpenRouter, Groq, DeepSeek, dsb. yang kompatibel `/v1/chat/completions` |
| Anthropic Claude | API key, model id | Messages API |
| Google Gemini | API key, model id | Gemini API |
| Custom / LAN | Base URL (+ key opsional) | Mis. Ollama/LM Studio di PC dalam jaringan yang sama; HTTP hanya untuk alamat LAN/loopback dan harus dikonfirmasi pengguna |

Model id **tidak di-hardcode** di kode; disimpan di konfigurasi provider dan bisa diubah tanpa rilis baru. **Tes Koneksi** wajib berhasil sebelum provider bisa dipakai.

**Layar Pengaturan AI:**

- Daftar provider (lokal + yang ditambahkan) dengan status: siap / key invalid / offline / kuota habis.
- **Tambah Provider:** pilih jenis → isi base URL / API key / model → Tes Koneksi → simpan.
- **Penugasan per agent:** contoh Data = Lokal, Analyst = Lokal, Strategist = Claude, Reporter = Lokal. Default semua Lokal.
- **Mode global:** `Offline Only` (default; semua provider remote nonaktif, tanpa panggilan jaringan) · `Hybrid` (remote hanya untuk agent yang ditugaskan, fallback ke lokal) · `Cloud Preferred` (remote dulu, lokal sebagai fallback).
- **Fallback:** bila remote gagal (timeout, 401, 429, tanpa jaringan) → retry terbatas lalu pindah ke provider lokal dan tampilkan toast; misi tidak gagal hanya karena cloud.
- **Pemakaian:** log token masuk/keluar per provider dan per misi, estimasi biaya bila tarif diisi pengguna, batas harian opsional.

### 6.5 Keamanan API key & data

- API key disimpan dengan `flutter_secure_storage` (Android Keystore). **Tidak** disimpan di SQLite, SharedPreferences biasa, log, laporan, ekspor, atau backup (`allowBackup=false` atau aturan exclude).
- Key ditampilkan termasking (`sk-…abcd`), bisa diganti dan dihapus; menghapus provider ikut menghapus key-nya.
- Hanya HTTPS untuk provider internet; validasi sertifikat tidak boleh di-bypass.
- **Data minimum ke cloud:** default hanya ringkasan/agregat hasil tool (KPI, top produk, agregat periode), bukan baris mentah atau file. Mengirim baris mentah memerlukan opsi terpisah yang dinyalakan eksplisit.
- Sebelum panggilan remote pertama per misi, tampilkan **pratinjau payload** (provider tujuan + data yang akan dikirim) dan minta persetujuan; persetujuan bisa diingat per provider.
- Penanda sumber di bubble chat/agent: ikon lokal atau nama provider cloud, agar pengguna tahu asal jawaban.
- Aturan anti-halusinasi angka tetap berlaku untuk semua provider: KPI hanya dari tool, output divalidasi dengan schema yang sama.

## 7. Desain multi-agent

### State agent

`IDLE -> ASSIGNED -> WALKING -> WORKING -> WAITING_TOOL/WAITING_LLM -> MEETING -> REVIEW -> DONE`  
Error path: `FAILED -> RETRY/NEEDS_USER_ACTION`; pause: `PAUSED`.

### Shared LLM scheduler

- Maksimal **1 inferensi aktif** pada MVP; request lain masuk antrean prioritas.
- Masing-masing agent memiliki system prompt, tools allowlist, konteks tugas yang diringkas, token budget, dan **provider yang ditugaskan** (default lokal).
- Antrean satu inferensi berlaku untuk provider lokal; agent yang ditugaskan ke provider remote boleh berjalan paralel dengan batas konkurensi dan rate limit per provider.
- Batasi context awal 2k–4k dan output 256–512 token per giliran; parameter harus bisa diubah setelah benchmark.
- Gunakan structured JSON output dengan validasi schema; jika invalid, retry terbatas dan fallback ke template.
- Meeting diatur oleh turn manager (Data → Analyst → Strategist → Reporter), bukan empat model berjalan paralel.
- LLM tidak boleh mengarang KPI; semua angka berasal dari tool hasil perhitungan yang menyertakan metadata sumber.

### Tool awal

`inspect_dataset`, `map_columns`, `validate_rows`, `compute_kpi`, `aggregate_by_period`, `rank_products`, `generate_chart_data`, `write_meeting_minutes`, `export_pdf`, `export_xlsx`.

Tools baca-only sebagai default. Tidak ada shell execution, akses SSH, eksekusi kode arbitrer, atau akses internet **oleh tools** pada MVP (koneksi ke provider AI remote hanya lewat AI Router, bukan tool). Jika ditambah nanti, harus sandbox dan memerlukan persetujuan pengguna.

## 8. Kontrak data

```json
{
  "mission_id": "uuid",
  "source_file": "penjualan_2025.xlsx",
  "schema_mapping": {
    "date": "Tanggal",
    "product": "Produk",
    "qty": "Qty",
    "unit_price": "Harga",
    "discount": "Diskon"
  },
  "kpis": {
    "total_revenue": 0,
    "total_qty": 0,
    "unique_products": 0
  },
  "validation": {
    "rows_read": 0,
    "rows_valid": 0,
    "rows_rejected": 0,
    "warnings": []
  }
}
```

Nilai `0` di atas placeholder, bukan hasil analisis. Tambahkan mata uang, timezone, periode, formula, lineage file/sheet, dan error handling dalam implementasi nyata.

## 9. UI/UX & performa

- Tampilan landscape utama; portrait boleh menampilkan pesan rotasi.
- Canvas game isometric 2D, panel overlay minimal, zoom/pan kamera, tombol besar untuk layar sentuh.
- Animasi sprite atlas kecil, pooling efek visual, lazy loading panel grafik.
- Batasi frame rate ke 30 FPS awal; hindari shadow/post-processing berat.
- Parsing dataset dan inferensi **di luar main thread** agar animasi tidak macet.
- Streaming status/progress ke Godot via signal/event queue; jangan mengirim token ke UI setiap frame.
- Saat aplikasi di-background, simpan state misi dan lakukan pause/resume aman. Jangan mengasumsikan background execution tanpa batas di Android.

## 10. Data, privasi, dan keselamatan

- Semua file lokal dan laporan berada di penyimpanan privat aplikasi hingga pengguna memilih ekspor.
- Gunakan SAF untuk pemilihan file dan penyimpanan hasil; hindari izin akses seluruh storage.
- Batas ukuran file awal 20 MB (konfigurabel); batas baris dan memory pressure ditentukan hasil profiling.
- Validasi MIME/ekstensi, schema, nilai kosong, tanggal, duplikat, encoding, formula Excel dan input berbahaya.
- Perlakukan isi file sebagai **data tak tepercaya**, bukan instruksi untuk agent.
- Hindari mengirim data ke layanan cloud tanpa opt-in eksplisit; aturan provider remote dan API key mengikuti §6.5.
- Mode `Offline Only` harus benar-benar tanpa panggilan jaringan (diverifikasi dengan mode pesawat dan log jaringan).
- Sediakan hapus dataset, riwayat misi, cache, model yang tidak dipakai, log pemakaian, dan semua API key.

## 11. Struktur repositori yang disarankan

```text
ai-agent-hq/
├── README.md
├── PRD_AI_Agent_HQ_Android_Offline_Infinix_X6871.md
├── app/                  # Flutter host app (baru di v1.1)
│   ├── pubspec.yaml
│   ├── lib/
│   │   ├── ai/
│   │   │   ├── ai_provider.dart
│   │   │   ├── ai_router.dart
│   │   │   ├── local_llama_provider.dart   # dart:ffi + Isolate
│   │   │   ├── openai_compatible_provider.dart
│   │   │   ├── anthropic_provider.dart
│   │   │   ├── gemini_provider.dart
│   │   │   └── model_manager.dart          # unduh/impor/verifikasi GGUF
│   │   ├── agents/       # orchestrator, prompts, tool contracts
│   │   ├── data/         # parser CSV/XLSX, KPI (port dari GDScript)
│   │   ├── reports/
│   │   ├── game_bridge/  # protokol JSON, UnityGameBridge, SimulatedGameBridge
│   │   └── ui/           # chat, pengaturan AI, manajer model
│   ├── android/          # llama.cpp .so arm64-v8a, plugin Kotlin
│   └── test/
├── unity/AgentHQ/        # Unity 6.3 LTS: OfficeGrid, AgentController, OfficeDirector, FlutterBridge, Editor setup, tests
├── game/                 # Godot Fase 1–2 (referensi; tidak dipakai aplikasi Flutter)
│   ├── project.godot
│   ├── scenes/
│   │   ├── Main.tscn
│   │   ├── OfficeMap.tscn
│   │   ├── Agent.tscn
│   │   ├── MeetingRoom.tscn
│   │   └── UI/
│   ├── scripts/
│   │   ├── agent_state_machine.gd
│   │   ├── navigation_controller.gd
│   │   ├── meeting_manager.gd
│   │   ├── mission_manager.gd
│   │   └── local_bridge.gd
│   └── assets/
│       ├── tiles/
│       ├── sprites/
│       └── ui/
├── runtime/              # script build llama.cpp Android; model binary tidak di-commit
├── tests/
└── docs/
    ├── BENCHMARK.md
    ├── ARCHITECTURE.md
    ├── AI_PROVIDERS.md
    ├── FLUTTER_UNITY.md
    └── ANDROID_BUILD.md
```

## 12. Roadmap implementasi

### Fase 0 — Validasi hardware dan model

- Jalankan Qwen3 4B GGUF Q4 di Android menggunakan runtime yang kompatibel (Termux boleh untuk angka awal).
- **Spike Flutter:** aplikasi Flutter minimal yang memuat llama.cpp via FFI di Isolate, streaming token, cancel, dan unload; uji bersama game view Unity embedded (G1), Flame (G2) bila perlu.
- Catat RAM peak, prompt processing, generation tokens/s, suhu/throttling, crash, penggunaan baterai.
- Uji saat game Godot sederhana terbuka. Jika tidak stabil, fallback ke model 1.7B–3B quantized.
- **Lulus:** model menjawab prompt berulang **dari dalam APK Flutter** tanpa OOM dan tanpa Termux, game tetap responsif; keputusan G1/G2 tercatat di `docs/ARCHITECTURE.md`.

### Fase 1 — Game playable tanpa LLM

- Peta 4 ruangan, koridor, pintu, meja, kursi, 4 robot berbeda.
- Navigation/pathfinding, animasi berjalan/duduk/mengetik, tap robot, panel status.
- Tombol **Panggil Meeting**: keempat robot berjalan menuju kursi berbeda dan bergiliran berbicara dengan dialog mock.
- **Lulus:** build APK Android arm64, robot bergerak sungguhan, tidak teleport, tidak menembus dinding, target 30 FPS di perangkat.

### Fase 2 — Upload dan analisis data deterministik

- File picker CSV lalu XLSX; validasi dan mapping kolom.
- KPI, tren, top produk, grafik, hasil tersimpan SQLite.
- **Lulus:** angka cocok dengan fixture pengujian; input buruk ditolak secara jelas.

### Fase 3 — LLM lokal embedded dan multi-agent

- Satu runtime lokal di APK Flutter, manajer model (unduh/impor/verifikasi), queue inferensi, prompt agent, JSON schema, progress events.
- Meeting menggunakan insight yang bersumber dari tool hasil analisis.
- **Lulus:** 4 agent menyelesaikan satu misi **dalam mode pesawat** tanpa angka fiktif; tidak crash ketika antrean penuh.

### Fase 3B — Provider AI eksternal (API key)

- Antarmuka `AiProvider`, AI Router, provider OpenAI-compatible, Claude, Gemini, dan custom base URL.
- Layar Pengaturan AI, Tes Koneksi, penugasan per agent, mode Offline Only/Hybrid/Cloud Preferred, fallback ke lokal, log token/biaya.
- Penyimpanan key aman, pratinjau payload, penanda sumber lokal/cloud.
- **Lulus:** pengguna menambah minimal satu provider dengan API key sendiri, menugaskannya ke satu agent, dan misi selesai; saat jaringan diputus misi tetap selesai lewat fallback lokal; key tidak muncul di log, SQLite, atau ekspor.

### Fase 4 — Laporan dan kualitas

- Ekspor PDF/Excel, notulen rapat, grafik, sumber data, keterbatasan analisis.
- Recovery setelah app pause/resume, penghapusan data, profiling baterai dan memori.
- **Lulus:** file terbuka dengan benar, data sesuai KPI, hasil dapat dibagikan dari Android.

### Fase 5 — Ekspansi opsional

- Tambah 8 agent, penjadwalan misi, personalisasi avatar, suara lokal, fitur prediksi stok.
- Fitur prediksi wajib memiliki dataset temporal, train/test split berbasis waktu, metrik MAE/RMSE/sMAPE, dan label estimasi; jangan menyamakan narasi LLM dengan forecasting statistik.

## 13. Acceptance criteria utama

- [ ] APK benar-benar dapat diinstal di Infinix X6871.
- [ ] Semua ruangan terlihat dan dapat dijelajahi di landscape.
- [ ] Keempat robot dapat berjalan secara animasi dan menghindari collision.
- [ ] Tombol meeting membuat keempat robot menuju kursi, duduk, dan berdialog bergantian.
- [ ] Game tetap bisa dijalankan tanpa LLM (demo mode).
- [ ] LLM offline memakai satu model bersama, bukan 4 model di RAM.
- [ ] LLM lokal berjalan di dalam APK Flutter (tanpa Termux/PC/server) dan berfungsi dalam mode pesawat.
- [ ] Model GGUF dapat diunduh atau diimpor dari aplikasi, diverifikasi, dan dihapus.
- [ ] Pengguna dapat menambah, menguji, dan menghapus provider AI lain dengan API key; key tersimpan aman dan tidak bocor ke log/ekspor.
- [ ] Mode Offline Only tidak membuat panggilan jaringan; Hybrid melakukan fallback ke lokal saat cloud gagal.
- [ ] Setiap jawaban AI menampilkan sumbernya (lokal atau nama provider).
- [ ] CSV dan XLSX dapat dipilih melalui file picker Android.
- [ ] KPI dihitung dari data, bukan dihasilkan bebas oleh LLM.
- [ ] Hasil meeting dan laporan dapat ditelusuri ke sumber perhitungan.
- [ ] PDF/Excel bisa diekspor dan dibuka di HP.
- [ ] Error/OOM/file rusak tidak menghapus misi lain.
- [ ] Benchmark perangkat nyata didokumentasikan.

## 14. Instruksi siap tempel ke Codex

> Implementasikan proyek **AI Agent HQ** sesuai PRD ini. Jangan membuat dashboard statis. Kerjakan **Fase 1 lebih dahulu** sebagai game Godot 4 2D isometric playable untuk Android landscape: empat ruangan (Data, Analisis, Meeting, Laporan), empat robot warna berbeda, animasi idle/walk/sit/typing/talk, pathfinding dan collision, interaksi tap, status pekerjaan, serta tombol Panggil Meeting yang membuat semua robot berjalan ke kursi meeting, duduk, dan berdialog bergantian. Buat kode modular, aset placeholder orisinal sederhana, scene Godot, README build Android, dan pengujian dasar. Jangan mengklaim APK atau fitur berjalan sebelum build dan pengujian nyata. Setelah Fase 1 lolos, lanjutkan Fase 0 benchmark LLM bila belum dilakukan, lalu Fase 2–4 bertahap. Setiap fase harus menghasilkan checklist acceptance criteria, instruksi menjalankan, dan daftar keterbatasan.
>
> **Tambahan v1.1:** aplikasi host dibuat dengan **Flutter**. LLM lokal di-embed di APK (llama.cpp via `dart:ffi` di Isolate terpisah, satu model, satu inferensi aktif) dan harus berjalan full offline di HP. Bangun antarmuka `AiProvider` + AI Router agar pengguna dapat menambahkan AI lain (OpenAI-compatible, Claude, Gemini, custom base URL) dengan API key sendiri, disimpan di `flutter_secure_storage`, default mode Offline Only, dengan fallback ke model lokal. Game layer memakai **Unity 6.3 LTS** yang ditanam lewat `flutter_embed_unity` (bukan Godot). Kerjakan spike Fase 0 (Flutter + llama.cpp + Unity embedded) dan catat RAM/FPS sebelum menaikkan model ke 4B.

## 15. Catatan risiko & keputusan terbuka

1. Performa Qwen3 4B pada CPU perangkat belum dibenchmark; fallback model lebih kecil harus tersedia.
2. Godot + llama.cpp sebagai **APK standalone** membutuhkan integrasi Android native yang belum terbukti dalam proyek ini.
3. Android dapat menghentikan proses ketika background, panas, atau RAM tertekan.
4. Dukungan GPU/NPU untuk LLM tidak diasumsikan; optimasi dilakukan hanya setelah profiling.
5. Pengolahan Excel besar bisa membebani memori; gunakan streaming/batas ukuran atau konversi terkontrol.
6. Asset game harus dibuat sendiri atau memiliki lisensi yang sesuai.
7. Unity embedded di Flutter (G1) berarti dua engine dalam satu proses; overhead RAM bisa menekan ruang untuk model 4B. Plugin `flutter_embed_unity` bergantung pada API internal Unity; pin versi Unity 6000.3.x, Flutter, dan AGP. Fallback: G2 (Flame) atau model 1.7B.
8. Model GGUF berukuran ~1–2,5 GB; unduhan pertama butuh internet dan storage cukup. APK tidak membundel model.
9. API key milik pengguna bisa bocor bila salah simpan atau tercatat di log; biaya dan kuota provider menjadi tanggung jawab pengguna dan harus terlihat jelas.
10. API dan nama model provider eksternal dapat berubah; model id harus bisa dikonfigurasi tanpa rilis ulang.
11. Lisensi llama.cpp, binding Flutter, dan model (mis. Qwen3) wajib dicek sebelum rilis.

---

**Prioritas pengembangan:** Game bergerak dan meeting berfungsi → spike Flutter + LLM embedded → analisis file akurat → integrasi LLM lokal → provider API key → laporan → optimasi.  
**Definisi sukses:** pengguna dapat memainkan simulasi kantor AI di HP, memberikan misi berbasis file, menyaksikan robot menjalankan workflow dan meeting, lalu memperoleh laporan yang dapat diverifikasi.
