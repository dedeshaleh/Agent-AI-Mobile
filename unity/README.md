# Unity — Agent HQ (lapisan game)

Proyek Unity 6.3 LTS (`6000.3.26f1`) di `unity/AgentHQ` menggambar kantor isometrik,
menggerakkan empat robot, dan melaporkan sentuhan ke Flutter lewat plugin
[flutter_embed_unity](https://github.com/learntoflutter/flutter_embed_unity). Flutter tetap
menjadi sumber kebenaran untuk workflow; protokol pesannya ada di
`app/lib/game_bridge/game_protocol.dart` dan dicerminkan oleh
`Assets/AgentHQ/Scripts/FlutterBridge.cs`.

> Status: kode C# ditulis tanpa bisa dikompilasi (Unity belum punya lisensi di PC ini).
> Saat pertama kali dibuka, periksa Console untuk error kompilasi lalu jalankan tes.

## Isi proyek

| Lokasi | Fungsi |
| --- | --- |
| `Assets/AgentHQ/Scripts/OfficeGrid.cs` | Grid 20×16, ruangan, home, kursi, furnitur, A* 4 arah (port `game/scripts/office_map.gd`) |
| `Assets/AgentHQ/Scripts/OfficeBuilder.cs` | Membangun kantor dari primitif saat `Awake` |
| `Assets/AgentHQ/Scripts/AgentController.cs` | Robot: gerak per tile dengan peta reservasi, animasi, bubble bicara |
| `Assets/AgentHQ/Scripts/OfficeDirector.cs` | Singleton: 4 agent, reservasi, jeda/kecepatan, logika meeting |
| `Assets/AgentHQ/Scripts/FlutterBridge.cs` | GameObject `FlutterBridge`, metode `OnMessage(string)` |
| `Assets/AgentHQ/Scripts/CameraRig.cs` | Kamera ortografis (30°, 45°), geser, cubit, ketuk |
| `Assets/AgentHQ/Scripts/Bootstrap.cs` | Membuat semua objek di atas saat scene dimulai |
| `Assets/AgentHQ/Editor/AgentHQSetup.cs` | Menu `Agent HQ/Setup Project`: scene, URP, Player Settings |
| `Assets/AgentHQ/Tests/Editor/OfficeGridTests.cs` | Tes navigasi (port `tests/run_tests.gd`) |
| `Assets/FlutterEmbed/` | Skrip Unity dari plugin flutter_embed_unity (MIT, lihat `LICENSE.md`) |

## Langkah sekali saja

1. Buka **Unity Hub**, masuk (sign in) dengan akun Unity, lalu aktifkan lisensi
   **Personal** (Preferences → Licenses → Add → Get a free personal license).
2. Pastikan editor `6000.3.26f1` terpasang di `D:\MobileDeveloper\Unity\Editors\6000.3.26f1`
   beserta modul **Android Build Support** (OpenJDK, SDK & NDK Tools).
3. Konfigurasi proyek, pilih salah satu:
   - **Lewat editor**: Unity Hub → Add → pilih folder `unity/AgentHQ` → buka dengan
     `6000.3.26f1`. Tunggu impor paket selesai, lalu jalankan menu **Agent HQ → Setup Project**.
     Periksa Console: setiap langkah mencetak `[AgentHQSetup] OK: ...` atau `GAGAL: ...`.
   - **Lewat batchmode** (PowerShell):

     ```powershell
     & 'D:\MobileDeveloper\Unity\Editors\6000.3.26f1\Editor\Unity.exe' -batchmode -nographics -quit `
       -projectPath 'D:\Webserver\Mobile\Agent-AI-Mobile\unity\AgentHQ' -buildTarget Android `
       -executeMethod AgentHQSetup.Configure -logFile "$env:TEMP\agenthq-unity\unity_setup.log"
     ```

4. (Opsional) Jalankan tes: **Window → General → Test Runner → EditMode → Run All**, atau

   ```powershell
   & 'D:\MobileDeveloper\Unity\Editors\6000.3.26f1\Editor\Unity.exe' -batchmode -nographics `
     -projectPath 'D:\Webserver\Mobile\Agent-AI-Mobile\unity\AgentHQ' -runTests -testPlatform EditMode `
     -testResults "$env:TEMP\agenthq-unity\tests.xml" -logFile "$env:TEMP\agenthq-unity\unity_tests.log"
   ```

## Ekspor ke aplikasi Flutter

Pilih salah satu:

- **Lewat editor**: pastikan platform aktif adalah Android (File → Build Profiles → Android →
  Switch Platform), lalu menu **Flutter Embed → Export project to Flutter app** dan pilih folder
  `app/android/unityLibrary` (buat jika belum ada).
- **Lewat skrip** (menjalankan setup lalu ekspor, PowerShell 5.1):

  ```powershell
  powershell -ExecutionPolicy Bypass -File .\scripts\Export-Unity.ps1
  # atau tanpa langkah setup:
  powershell -ExecutionPolicy Bypass -File .\scripts\Export-Unity.ps1 -SkipSetup
  ```

  Log ada di `%TEMP%\agenthq-unity\unity_setup.log` dan `unity_export.log`.
  Skrip gagal jika exit code bukan 0 atau `app\android\unityLibrary\build.gradle` tidak terbentuk.

Setelah ekspor:

1. Cari baris `unityStreamingAssets=` di log ekspor (dicetak oleh plugin setelah
   "The following should be added to your project's android/gradle.properties") dan tambahkan ke
   `app/android/gradle.properties`. Biasanya nilainya kosong:

   ```properties
   unityStreamingAssets=
   ```

2. Build aplikasi Flutter dengan embed Unity aktif:

   ```powershell
   flutter build apk --dart-define=UNITY_EMBED=true
   ```

   Tanpa `--dart-define=UNITY_EMBED=true` aplikasi memakai `SimulatedGameBridge` sehingga tetap
   bisa diuji walau `unityLibrary` belum diekspor.

## Catatan pengaturan yang dipasang `AgentHQSetup`

- Scripting backend IL2CPP, arsitektur **ARM64 + ARMv7** (pre-check plugin menolak ekspor tanpa
  keduanya; filter ABI di aplikasi Flutter membuang lib 32-bit).
- Min SDK 23, target SDK otomatis, orientasi LandscapeLeft, izin Internet tidak dipaksa.
- Application Entry Point = Activity (wajib untuk plugin di Unity 6).
- `Export project` + build system Gradle, Graphics API OpenGLES3 lalu Vulkan (auto nonaktif).
- URP asset di `Assets/AgentHQ/Settings/URP.asset` dipasang ke Graphics dan semua level Quality.
- Active Input Handling: `Both` jika paket Input System terpasang, jika tidak `Input Manager (Old)`
  (CameraRig hanya memakai API `Input` lama).
