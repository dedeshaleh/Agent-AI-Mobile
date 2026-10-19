# AI di Agent HQ: model lokal tertanam + provider dengan API key

Mengikuti PRD v1.1 §6. Semua AI diakses lewat `AiProvider` dan `AiRouter` (`app/lib/ai/`); agent tidak pernah memanggil HTTP atau FFI langsung.

## Model lokal (default)

- Runtime: llama.cpp tag `b11727` di-compile menjadi `libagenthq_llama.so` (arm64-v8a, `-march=armv8.2-a+dotprod+fp16`, 16 KB page) dari `app/android/app/src/main/cpp/`. Dipanggil lewat `dart:ffi` dari satu Isolate pekerja (`LlamaFfiEngine`); UI tidak pernah memblokir.
- Satu model dimuat, satu inferensi aktif; agent lokal mengantre.
- Prompt memakai format ChatML Qwen3 dengan `/no_think`; blok `<think>` dibuang.
- Model **tidak** dibundel di APK. Menu **Model** di aplikasi mengunduh (resume + verifikasi) atau mengimpor `.gguf` lewat SAF. Model tersimpan di direktori privat aplikasi (`files/models/`).
- Parameter awal: context 2048, 4 thread, output 256 token. Ubah di **Pengaturan AI**; berlaku saat model dimuat ulang.

Rekomendasi: `Qwen3-1.7B-Q4_K_M` (≈1,1 GB) untuk uji awal, `Qwen3-4B-Q4_K_M` (≈2,5 GB) sebagai target PRD setelah benchmark.

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
