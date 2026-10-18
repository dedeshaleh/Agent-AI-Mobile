# PRD & Technical Blueprint — AI Agent HQ Android Offline

**Versi:** 1.0  
**Target:** Infinix X6871, Android 15 / XOS 15.1.2, Dimensity 8200 Ultimate, RAM fisik 12 GB, storage 256 GB  
**Tujuan:** Game simulasi kantor AI 2D isometric dengan 4–8 karakter agent yang bergerak, meeting, menganalisis file pengguna, dan menghasilkan laporan secara lokal.

> Dokumen ini adalah spesifikasi implementasi untuk Codex. Jangan mengganti game interaktif dengan gambar statis atau mockup. Semua pekerjaan harus dapat diuji pada perangkat Android nyata.

## 1. Prinsip produk

- **Offline-first:** seluruh fungsi inti dapat berjalan tanpa internet setelah model dan dependensi dipasang.
- **Game sungguhan:** robot bergerak mengikuti path, masuk ruangan, duduk, mengetik, berbicara, dan kembali bekerja.
- **Satu model, banyak agent:** 4 agent memiliki identitas, prompt, tools, memori tugas, dan state berbeda; semua memakai satu instance LLM dengan antrean inferensi.
- **Deterministik untuk angka:** perhitungan KPI dilakukan oleh kode/SQL, bukan dikarang oleh LLM.
- **Keamanan lokal:** file pengguna diproses dalam sandbox aplikasi; tool sensitif membutuhkan persetujuan.
- **Skalabilitas:** 4 agent MVP; 8 agent setelah profiling.

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
Godot 4 Android APK (UI, map, sprites, state machine, navigation)
       |
       | typed local bridge / loopback API
       v
Agent Orchestrator (queue, workflow, tools, approvals)
       |                       |
       |                       +--> Dataset Engine (CSV/Excel, SQL, chart data)
       |                       +--> Report Engine (PDF/Excel)
       |                       +--> SQLite (missions, agent states, logs)
       v
Shared Local LLM Runtime (llama.cpp / compatible Android arm64)
       |
       +--> Qwen3 4B GGUF Q4 (one loaded model)
```

**Penting:** Python/FastAPI di Android tidak otomatis tersedia sebagai service di APK Godot. Pilih salah satu strategi setelah spike teknis:

- **Pilihan A, target produksi:** Godot Android + plugin Android native Kotlin/JNI untuk menjalankan llama.cpp, parser data, dan report engine native/embedded. Implementasi paling rapi, tetapi integrasi lebih kompleks.
- **Pilihan B, prototipe developer:** Godot + Termux yang menjalankan `llama-server` dan service analitik di `127.0.0.1`. Membutuhkan setup manual dan lifecycle Android dapat menghentikan service; **bukan** APK standalone.

**Keputusan milestone:** buktikan dulu inferensi Qwen3 4B Q4 di HP dengan benchmark RAM, tokens/s, thermal, dan stabilitas. Baru pilih A atau B. Jangan menjanjikan satu APK offline sebelum native bridge teruji.

## 6. Desain multi-agent

### State agent

`IDLE -> ASSIGNED -> WALKING -> WORKING -> WAITING_TOOL/WAITING_LLM -> MEETING -> REVIEW -> DONE`  
Error path: `FAILED -> RETRY/NEEDS_USER_ACTION`; pause: `PAUSED`.

### Shared LLM scheduler

- Maksimal **1 inferensi aktif** pada MVP; request lain masuk antrean prioritas.
- Masing-masing agent memiliki system prompt, tools allowlist, konteks tugas yang diringkas, dan token budget.
- Batasi context awal 2k–4k dan output 256–512 token per giliran; parameter harus bisa diubah setelah benchmark.
- Gunakan structured JSON output dengan validasi schema; jika invalid, retry terbatas dan fallback ke template.
- Meeting diatur oleh turn manager (Data → Analyst → Strategist → Reporter), bukan empat model berjalan paralel.
- LLM tidak boleh mengarang KPI; semua angka berasal dari tool hasil perhitungan yang menyertakan metadata sumber.

### Tool awal

`inspect_dataset`, `map_columns`, `validate_rows`, `compute_kpi`, `aggregate_by_period`, `rank_products`, `generate_chart_data`, `write_meeting_minutes`, `export_pdf`, `export_xlsx`.

Tools baca-only sebagai default. Tidak ada shell execution, akses SSH, internet, atau eksekusi kode arbitrer pada MVP. Jika ditambah nanti, harus sandbox dan memerlukan persetujuan pengguna.

## 7. Kontrak data

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

## 8. UI/UX & performa

- Tampilan landscape utama; portrait boleh menampilkan pesan rotasi.
- Canvas game isometric 2D, panel overlay minimal, zoom/pan kamera, tombol besar untuk layar sentuh.
- Animasi sprite atlas kecil, pooling efek visual, lazy loading panel grafik.
- Batasi frame rate ke 30 FPS awal; hindari shadow/post-processing berat.
- Parsing dataset dan inferensi **di luar main thread** agar animasi tidak macet.
- Streaming status/progress ke Godot via signal/event queue; jangan mengirim token ke UI setiap frame.
- Saat aplikasi di-background, simpan state misi dan lakukan pause/resume aman. Jangan mengasumsikan background execution tanpa batas di Android.

## 9. Data, privasi, dan keselamatan

- Semua file lokal dan laporan berada di penyimpanan privat aplikasi hingga pengguna memilih ekspor.
- Gunakan SAF untuk pemilihan file dan penyimpanan hasil; hindari izin akses seluruh storage.
- Batas ukuran file awal 20 MB (konfigurabel); batas baris dan memory pressure ditentukan hasil profiling.
- Validasi MIME/ekstensi, schema, nilai kosong, tanggal, duplikat, encoding, formula Excel dan input berbahaya.
- Perlakukan isi file sebagai **data tak tepercaya**, bukan instruksi untuk agent.
- Hindari mengirim data ke layanan cloud tanpa opt-in eksplisit.
- Sediakan hapus dataset, riwayat misi, cache, dan model yang tidak dipakai.

## 10. Struktur repositori yang disarankan

```text
ai-agent-hq/
├── README.md
├── PRD_AI_Agent_HQ_Android_Offline_Infinix_X6871.md
├── game/
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
├── android_bridge/       # Kotlin/JNI setelah spike
├── runtime/              # integrasi llama.cpp; model binary tidak di-commit
├── agent_core/           # workflow, tool contracts, prompts
├── data_engine/          # parsing & agregasi
├── report_engine/        # PDF/Excel
├── tests/
└── docs/
    ├── BENCHMARK.md
    ├── ARCHITECTURE.md
    └── ANDROID_BUILD.md
```

## 11. Roadmap implementasi

### Fase 0 — Validasi hardware dan model

- Jalankan Qwen3 4B GGUF Q4 di Android menggunakan runtime yang kompatibel.
- Catat RAM peak, prompt processing, generation tokens/s, suhu/throttling, crash, penggunaan baterai.
- Uji saat game Godot sederhana terbuka. Jika tidak stabil, fallback ke model 1.7B–3B quantized.
- **Lulus:** model menjawab prompt berulang tanpa OOM, game tetap responsif.

### Fase 1 — Game playable tanpa LLM

- Peta 4 ruangan, koridor, pintu, meja, kursi, 4 robot berbeda.
- Navigation/pathfinding, animasi berjalan/duduk/mengetik, tap robot, panel status.
- Tombol **Panggil Meeting**: keempat robot berjalan menuju kursi berbeda dan bergiliran berbicara dengan dialog mock.
- **Lulus:** build APK Android arm64, robot bergerak sungguhan, tidak teleport, tidak menembus dinding, target 30 FPS di perangkat.

### Fase 2 — Upload dan analisis data deterministik

- File picker CSV lalu XLSX; validasi dan mapping kolom.
- KPI, tren, top produk, grafik, hasil tersimpan SQLite.
- **Lulus:** angka cocok dengan fixture pengujian; input buruk ditolak secara jelas.

### Fase 3 — LLM dan multi-agent

- Satu runtime lokal, queue inferensi, prompt agent, JSON schema, progress events.
- Meeting menggunakan insight yang bersumber dari tool hasil analisis.
- **Lulus:** 4 agent menyelesaikan satu misi tanpa angka fiktif; tidak crash ketika antrean penuh.

### Fase 4 — Laporan dan kualitas

- Ekspor PDF/Excel, notulen rapat, grafik, sumber data, keterbatasan analisis.
- Recovery setelah app pause/resume, penghapusan data, profiling baterai dan memori.
- **Lulus:** file terbuka dengan benar, data sesuai KPI, hasil dapat dibagikan dari Android.

### Fase 5 — Ekspansi opsional

- Tambah 8 agent, penjadwalan misi, personalisasi avatar, suara lokal, fitur prediksi stok.
- Fitur prediksi wajib memiliki dataset temporal, train/test split berbasis waktu, metrik MAE/RMSE/sMAPE, dan label estimasi; jangan menyamakan narasi LLM dengan forecasting statistik.

## 12. Acceptance criteria utama

- [ ] APK benar-benar dapat diinstal di Infinix X6871.
- [ ] Semua ruangan terlihat dan dapat dijelajahi di landscape.
- [ ] Keempat robot dapat berjalan secara animasi dan menghindari collision.
- [ ] Tombol meeting membuat keempat robot menuju kursi, duduk, dan berdialog bergantian.
- [ ] Game tetap bisa dijalankan tanpa LLM (demo mode).
- [ ] LLM offline memakai satu model bersama, bukan 4 model di RAM.
- [ ] CSV dan XLSX dapat dipilih melalui file picker Android.
- [ ] KPI dihitung dari data, bukan dihasilkan bebas oleh LLM.
- [ ] Hasil meeting dan laporan dapat ditelusuri ke sumber perhitungan.
- [ ] PDF/Excel bisa diekspor dan dibuka di HP.
- [ ] Error/OOM/file rusak tidak menghapus misi lain.
- [ ] Benchmark perangkat nyata didokumentasikan.

## 13. Instruksi siap tempel ke Codex

> Implementasikan proyek **AI Agent HQ** sesuai PRD ini. Jangan membuat dashboard statis. Kerjakan **Fase 1 lebih dahulu** sebagai game Godot 4 2D isometric playable untuk Android landscape: empat ruangan (Data, Analisis, Meeting, Laporan), empat robot warna berbeda, animasi idle/walk/sit/typing/talk, pathfinding dan collision, interaksi tap, status pekerjaan, serta tombol Panggil Meeting yang membuat semua robot berjalan ke kursi meeting, duduk, dan berdialog bergantian. Buat kode modular, aset placeholder orisinal sederhana, scene Godot, README build Android, dan pengujian dasar. Jangan mengklaim APK atau fitur berjalan sebelum build dan pengujian nyata. Setelah Fase 1 lolos, lanjutkan Fase 0 benchmark LLM bila belum dilakukan, lalu Fase 2–4 bertahap. Setiap fase harus menghasilkan checklist acceptance criteria, instruksi menjalankan, dan daftar keterbatasan.

## 14. Catatan risiko & keputusan terbuka

1. Performa Qwen3 4B pada CPU perangkat belum dibenchmark; fallback model lebih kecil harus tersedia.
2. Godot + llama.cpp sebagai **APK standalone** membutuhkan integrasi Android native yang belum terbukti dalam proyek ini.
3. Android dapat menghentikan proses ketika background, panas, atau RAM tertekan.
4. Dukungan GPU/NPU untuk LLM tidak diasumsikan; optimasi dilakukan hanya setelah profiling.
5. Pengolahan Excel besar bisa membebani memori; gunakan streaming/batas ukuran atau konversi terkontrol.
6. Asset game harus dibuat sendiri atau memiliki lisensi yang sesuai.

---

**Prioritas pengembangan:** Game bergerak dan meeting berfungsi → analisis file akurat → integrasi LLM lokal → laporan → optimasi.  
**Definisi sukses:** pengguna dapat memainkan simulasi kantor AI di HP, memberikan misi berbasis file, menyaksikan robot menjalankan workflow dan meeting, lalu memperoleh laporan yang dapat diverifikasi.
