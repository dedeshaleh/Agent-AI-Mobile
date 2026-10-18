# Status verifikasi Fase 1

## Teruji di laptop Windows

- Godot 4.5.1 Standard: import proyek dan peluncuran tanpa script error.
- Grafik dirender memakai OpenGL Compatibility pada NVIDIA GeForce MX550; screenshot dihasilkan dari viewport game yang berjalan.
- Semua kombinasi meja awal ke empat kursi meeting memiliki jalur.
- Jalur tidak melewati furniture/wall dan hanya berpindah ke tile yang bersebelahan.
- Input koordinat invalid dan tujuan furniture ditolak.
- Tiga siklus meeting lengkap: berjalan ke kursi, empat giliran dialog, kembali ke meja, tanpa deadlock dan overlap posisi pada simulasi.
- Misi demo terhubung ke meeting otomatis.
- Pause membekukan waktu simulasi.
- Notulen dapat ditampilkan, disimpan dan dipulihkan.
- Batas zoom diuji; UI smoke test lulus.

Perintah yang digunakan tersedia pada `scripts/Test.ps1`. Uji simulasi tidak membuktikan performa atau kontrol sentuh pada HP.

## Belum diverifikasi pada perangkat nyata

- Instalasi dan peluncuran APK di GT 20 Pro.
- Sentuhan, pinch, cutout/insets, orientasi landscape dan readable text pada layar HP.
- FPS 30, RAM, panas, baterai dan lifecycle Android/XOS.
- LLM 1.7B/4B bersamaan dengan game.
- Integrasi native Android, upload file, analisis data dan ekspor laporan.

Checklist penerimaan perangkat ada di `docs/ANDROID_BUILD.md`. Demo harus diuji di HP sebelum Fase 1 dinyatakan selesai untuk target Android. Tidak ada hasil benchmark yang diisi dengan perkiraan.
