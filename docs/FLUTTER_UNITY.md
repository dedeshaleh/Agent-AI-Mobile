# Aplikasi Flutter + game Unity

Sejak PRD v1.1 aplikasi utama adalah Flutter (`app/`). Game kantor isometric dibuat dengan **Unity 6.3 LTS** (`unity/AgentHQ/`) dan ditanam sebagai widget lewat `flutter_embed_unity`. Proyek Godot lama (`game/`) tetap ada sebagai referensi Fase 1–2 dan tidak dipakai lagi oleh aplikasi.

## Pembagian tanggung jawab

| Flutter (Dart) | Unity (C#) |
|---|---|
| UI, chat, pengaturan AI, manajer model | Menggambar kantor, robot, meja, kursi |
| Parsing CSV/XLSX dan KPI (`lib/data`) | Pathfinding A* 4 arah + reservasi tile |
| Orchestrator misi dan meeting (`lib/agents`) | Animasi jalan/duduk/mengetik, bubble bicara |
| Semua pemanggilan model (`lib/ai`) | Tap robot/ruangan, pan, pinch zoom |

Protokol JSON Flutter ⇄ Unity didefinisikan di `app/lib/game_bridge/game_protocol.dart` dan dicerminkan oleh `unity/AgentHQ/Assets/AgentHQ/Scripts/FlutterBridge.cs`.

Tanpa export Unity, aplikasi memakai `SimulatedGameBridge` + papan status (bukan game) agar alur misi tetap bisa diuji.

## Alur build di PC ini

Toolchain: `D:\MobileDeveloper\{flutter, android-sdk, jdk-21, Unity\Editors\6000.3.26f1}`. Skill Claude Code `flutter-mobile`, `unity-android`, `android-device`, `on-device-ai` di `.claude/skills/` berisi perintah dan jebakan yang sudah ditemui.

1. Tes Dart: `cd app; flutter analyze; flutter test` (129 tes).
2. Setup + tes Unity (sekali, atau setelah mengubah C#):
   `Unity.exe -batchmode -nographics -quit -projectPath unity\AgentHQ -buildTarget Android -executeMethod AgentHQSetup.Configure`
   lalu `-runTests -testPlatform EditMode`.
3. Export Unity ke `app/android/unityLibrary`: `powershell -ExecutionPolicy Bypass -File scripts\Export-Unity.ps1 -SkipSetup`. Folder ini ~650 MB dan tidak di-commit.
4. Salin properti `unity.*` dari `app/android/unityLibrary/gradle.properties` ke `app/android/gradle.properties` bila versi Unity berubah (sudah dilakukan untuk 6000.3.26f1).
5. Build: `cd app; flutter build apk --debug --target-platform android-arm64 --dart-define=UNITY_EMBED=true`. Build pertama mengkloning llama.cpp dan menjalankan IL2CPP; tunggu 10–20 menit.
6. Pasang ke HP lewat Wireless debugging (`adb connect <ip:port>`), lalu `adb install -r app\build\app\outputs\flutter-apk\app-debug.apk`.

Catatan Gradle: `unityLibrary` hanya di-include bila foldernya ada; `minSdk` 25 mengikuti export Unity; `kotlin.incremental=false` karena cache Kotlin gagal ditutup di host Windows ini.

## Keterbatasan yang diketahui

- `flutter_embed_unity` memakai API Unity yang tidak didokumentasikan; pembaruan Unity/Flutter/AGP dapat merusaknya. Hanya satu widget Unity per layar; Unity tetap di memori setelah dimuat.
- Dua engine dalam satu proses: pantau RAM saat model 4B dimuat (PRD risiko #7). Fallback: model 1.7B.
- Ekspor PDF/Excel (Fase 4) belum ada; notulen bisa dibagikan sebagai teks.
