# Build dan preview Android

## Cara ringan: build di GitHub

Workflow `.github/workflows/android.yml` menyiapkan Godot 4.5.1, JDK 17, Android SDK dan export templates pada runner GitHub. Ia menjalankan test lalu mengekspor APK debug arm64. Laptop tidak perlu Android Studio, SDK atau emulator untuk cara ini.

1. Push perubahan ke branch `main`, atau jalankan workflow manual dari tab Actions.
2. Tunggu run **Android demo** selesai dengan status hijau.
3. Unduh artifact **AgentHQ-Android** dari halaman run menggunakan akun GitHub yang punya akses repo.
4. Ekstrak ZIP di HP dan instal `AgentHQ-demo.apk`.

APK ditandatangani debug keystore persisten yang di-cache per repository agar pembaruan biasanya dapat dipasang tanpa uninstall. Jika cache hilang, kunci debug bisa berubah. Saat muncul signature mismatch, uninstall demo lama hanya setelah menyimpan notulen yang diperlukan; uninstall menghapus data aplikasi. Jangan gunakan debug keystore ini untuk Play Store.

## Build lokal

Workspace awal menempatkan tool di drive D dalam `.tools`. Folder itu tidak ikut Git:

```text
.tools/godot/Godot_v4.5.1-stable_win64_console.exe
.tools/godot/editor_data/export_templates/4.5.1.stable/android_debug.apk
.tools/java/jdk-17.../bin/java.exe
.tools/android/cmdline-tools/latest/bin/sdkmanager.bat
.tools/android/platform-tools/adb.exe
```

Untuk setup baru, unduh Godot 4.5.1 Standard dan export templates dengan versi sama dari situs resmi, OpenJDK 17, serta Android SDK Command-line Tools dari Google. Instal SDK platform-tools, platform 35 dan build-tools 35.0.1. Preset demo memakai ekspor APK standar tanpa Gradle custom build. Integrasi native LLM nanti membutuhkan NDK/CMake dan konfigurasi tambahan.

Set `Java SDK Path` dan `Android SDK Path` di Godot Editor Settings bila memakai instalasi Godot sendiri. Jika memakai struktur `.tools` yang disiapkan:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Build-Android.ps1
```

Hasil: `build/AgentHQ-demo.apk`. Periksa error export dan keberadaan file; jangan menganggap test headless membuktikan APK berjalan di Android.

## Deploy USB ke HP

1. Aktifkan Developer options dan USB debugging di HP.
2. Hubungkan kabel data, buka kunci layar, izinkan debugging dari laptop.
3. Jalankan:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Install-Phone.ps1
```

Alternatif: buka proyek Godot, aktifkan preset Android sebagai Runnable dan gunakan one-click deploy. Wireless ADB bisa dipakai setelah pairing; USB disarankan untuk setup pertama.

## Uji di HP

- [ ] APK dapat diinstal dan dibuka di GT 20 Pro.
- [ ] Layar landscape, semua kontrol terbaca dan tidak terpotong cutout.
- [ ] Empat robot terlihat dan dapat dipilih lewat sentuhan.
- [ ] Meeting: berjalan, duduk, empat giliran bicara, kembali bekerja.
- [ ] Lima meeting berulang tanpa macet/tumpang tindih.
- [ ] Jeda menghentikan simulasi; lanjutkan tidak melompati dialog.
- [ ] Pan, pinch dan reset kamera berfungsi.
- [ ] Background menjeda; notulen terakhir tetap ada setelah restart.
- [ ] Mode pesawat tidak memengaruhi demo.
- [ ] Ukur FPS, RAM dan panas; target 30 FPS belum menjadi klaim hasil.

Referensi: [Godot Android export](https://docs.godotengine.org/en/4.5/tutorials/export/exporting_for_android.html), [one-click deploy](https://docs.godotengine.org/en/stable/tutorials/export/one-click_deploy.html).
