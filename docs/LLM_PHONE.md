# LLM di Infinix GT 20 Pro

**Tidak diperlukan untuk memainkan demo Fase 1.** Langkah ini untuk benchmark runtime terpisah. Game belum terhubung ke endpoint LLM.

## Pilihan model

Mulai dengan Qwen3 1.7B quantization Q4_K_M untuk memeriksa kelancaran saat game terbuka. Setelah itu bandingkan Qwen3 4B Q4 sebagai target PRD. Ukuran model di disk bukan total RAM; context/KV cache dan runtime memakai RAM tambahan. Kecepatan, panas dan kapasitas belum diukur di HP ini.

Gunakan satu model untuk empat agent dengan satu inferensi aktif, bukan empat instance. Mulai pada context 2048 dan output 256 token. Gunakan mode non-thinking untuk interaksi pendek; bukan untuk mengubah fakta atau mengarang KPI.

Folax adalah fitur asisten bawaan. Belum ditemukan akses resmi yang memadai dalam investigasi proyek ini untuk memanggil inferensi offline Folax dari game. Keberadaan Folax tidak menjadi dependency dan tidak berarti perangkat sudah memiliki runtime GGUF untuk aplikasi pihak ketiga.

## Instalasi prototipe di HP

Pasang Termux dari [F-Droid](https://f-droid.org/packages/com.termux/) atau [rilis resmi GitHub](https://github.com/termux/termux-app/releases). Pilih satu sumber yang konsisten untuk Termux dan pluginnya.

Di Termux jalankan bertahap. Instalasi dan download perlu internet; setelah model tersimpan, inferensi lokal dapat berjalan offline.

```sh
pkg update
pkg upgrade
pkg install git cmake clang curl libandroid-spawn
git clone --depth 1 https://github.com/ggml-org/llama.cpp
cd llama.cpp
cmake -B build -DCMAKE_BUILD_TYPE=Release -DGGML_OPENMP=OFF -DLLAMA_CURL=OFF -DLLAMA_OPENSSL=OFF
cmake --build build --config Release -j 4 --target llama-server llama-cli
mkdir -p "$HOME/models"
curl -L --fail --retry 3 -C - \
  'https://huggingface.co/unsloth/Qwen3-1.7B-GGUF/resolve/main/Qwen3-1.7B-Q4_K_M.gguf' \
  -o "$HOME/models/Qwen3-1.7B-Q4_K_M.gguf"
./build/bin/llama-server \
  -m "$HOME/models/Qwen3-1.7B-Q4_K_M.gguf" \
  --host 127.0.0.1 --port 8080 \
  -c 2048 -t 4 -ngl 0 --parallel 1
```

Server hanya bind ke loopback HP. Jangan menggantinya ke `0.0.0.0` untuk kebutuhan ini. Uji lewat browser HP di `http://127.0.0.1:8080` atau terminal kedua:

```sh
curl --fail http://127.0.0.1:8080/health
curl --fail http://127.0.0.1:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"Jawab dalam bahasa Indonesia: apa tugas agent Data? /no_think"}],"max_tokens":256,"temperature":0.6}'
```

Perintah mengacu pada runtime upstream; belum dijalankan di HP pengguna. Bila opsi CMake berubah, ikuti dokumentasi upstream, jangan mengasumsikan akselerasi Mali/NPU tersedia. Baseline memakai CPU.

Android/XOS dapat menghentikan Termux saat berpindah aplikasi atau saat RAM tertekan. Untuk pengujian, periksa pengaturan baterai aplikasi. Server Termux adalah prototipe manual, bukan bagian APK standalone.

## Checklist benchmark nyata

Catat tanggal, OS/XOS, RAM fisik, sisa storage, versi/commit llama.cpp, model/quantization, context dan thread. Jalankan minimal 10 prompt berulang:

| Pengukuran | 1.7B Q4 | 4B Q4 |
|---|---|---|
| Waktu memuat model | Belum diuji | Belum diuji |
| Waktu token pertama | Belum diuji | Belum diuji |
| Generation tokens/s | Belum diuji | Belum diuji |
| RAM peak | Belum diuji | Belum diuji |
| Panas / throttling setelah 10 menit | Belum diuji | Belum diuji |
| Game tetap responsif | Belum diuji | Belum diuji |
| Stabil saat pause/resume | Belum diuji | Belum diuji |

Sumber: [llama.cpp Android](https://github.com/ggml-org/llama.cpp/blob/master/docs/android.md), [Qwen3 1.7B](https://huggingface.co/Qwen/Qwen3-1.7B), [GGUF quantized](https://huggingface.co/unsloth/Qwen3-1.7B-GGUF), [Termux](https://github.com/termux/termux-app).
