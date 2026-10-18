# Arsitektur Fase 1

Godot 4.5.1 Standard + GDScript + renderer Compatibility, target awal 30 FPS. Landscape 1440×810 dengan canvas scaling. Visual dibuat secara prosedural, tanpa bitmap statis sebagai pengganti game.

- `office_map.gd`: floor grid, furniture collision, proyeksi isometric, konversi tap ke grid dan pencarian jalur AStarGrid2D.
- `agent.gd`: state agent, movement antar tile, animasi, log aktivitas dan reservasi ruang gerak. Saat tile berikutnya terisi, jalur dihitung ulang dengan tile agent lain diblokir sementara. Perpindahan tidak memakai teleport.
- `meeting_manager.gd`: reservasi kursi berdasarkan identitas, barrier kedatangan, empat giliran dialog, transkrip dan perintah kembali ke meja.
- `main.gd`: UI, demo mission, pause/resume, input, kamera, penyimpanan ringkasan dan integrasi scene.

Semua movement dan meeting memakai waktu simulasi yang sama. Pause menghentikan keduanya. Saat aplikasi masuk background, simulasi dijeda dan ringkasan disimpan. Pengguna melanjutkan melalui tombol Lanjutkan; tidak ada background service.

Collision memakai logical grid yang sama dengan navigasi, bukan physics body. Robot memesan tile asal dan tile tujuan selama perpindahan. Collision fisik Godot bukan ketergantungan Fase 1.

## Tahap berikutnya

1. Benchmark model 1.7B/4B di HP bersamaan dengan game; catat panas, RAM dan latency.
2. CSV terlebih dahulu, parsing pada worker thread, mapping kolom dan KPI deterministik.
3. Bridge ke satu runtime llama.cpp lokal. Antrean satu inferensi, context awal 2048, output maksimal 256 token, JSON tervalidasi dan timeout.
4. XLSX, laporan PDF/Excel dan Android Storage Access Framework.
5. Bila prototipe stabil, migrasikan runtime Termux ke plugin Kotlin/JNI agar menjadi APK standalone.

Tidak ada auto-detection Folax, panggilan model cloud, atau pengiriman file pengguna pada demo ini.
