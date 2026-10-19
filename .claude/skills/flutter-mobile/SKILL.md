---
name: flutter-mobile
description: Build, run, test, and debug the Flutter host app (app/) for Agent HQ on this Windows PC and the Infinix X6871. Use when creating Flutter code, running flutter doctor/pub/analyze/test, building an APK, or when a flutter command fails with PowerShell policy, PATH, or Android SDK errors.
---

# Flutter mobile workflow (Agent HQ)

## Toolchain on this PC

| Item | Location |
|---|---|
| Flutter SDK (stable) | `D:\MobileDeveloper\flutter` (bin is on the user PATH; old terminals may need `$env:Path += ';D:\MobileDeveloper\flutter\bin'`) |
| Android SDK (`ANDROID_HOME`, set in `flutter config`) | `D:\MobileDeveloper\android-sdk` (cmdline-tools/latest, platform-tools, platforms;android-36, build-tools;36.1.0) |
| JDK (`JAVA_HOME`, set in `flutter config --jdk-dir`) | `D:\MobileDeveloper\jdk-21` (Temurin 21) |
| Unity editors | `D:\MobileDeveloper\Unity\Editors\<version>` |

Adding SDK packages: set `$env:JAVA_HOME` first. Quote every package id, because `sdkmanager.bat` runs through cmd, which splits on `;`. For example: `& $sm '--sdk_root=D:\MobileDeveloper\android-sdk' '"platforms;android-35"'`. Updating `platform-tools` fails while adb is running; run `adb kill-server` first, then reconnect the phone (android-device skill). For downloads, use `curl.exe -L --fail`; `Invoke-WebRequest` in PowerShell 5.1 crawls at ~0.1 MB/s.
| Flutter app (per PRD v1.1 §11) | `app/` |

Always call Flutter through `cmd /c "flutter ... 2>&1"` from PowerShell so stderr is captured without NativeCommandError noise.

## First check

```powershell
cmd /c "flutter doctor -v 2>&1"
```

Known failures and fixes:

- **`'pub upgrade' still failing` / `.ps1 cannot be loaded because running scripts is disabled`**: the domain GPO (`bhi.hospitals.local`) reset `HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell` `EnableScripts` to 0. Check with `Get-ExecutionPolicy -List`. Do not change the policy yourself; tell the user. They have local admin and know the fix (elevated registry edit), and it is an IT security control. The Dart SDK already in `bin\cache` keeps most commands working; `flutter upgrade` and channel switches will fail.
- **`Unable to locate Android SDK`**: re-point Flutter at the SDK and JDK above:
  `cmd /c "flutter config --android-sdk D:\MobileDeveloper\android-sdk --jdk-dir D:\MobileDeveloper\jdk-21 2>&1"`
- **Visual Studio C++ missing**: only needed for Windows desktop builds; ignore for Android.

## Everyday commands (run inside `app/`)

```powershell
cmd /c "flutter pub get 2>&1"
cmd /c "flutter analyze 2>&1"
cmd /c "flutter test 2>&1"
cmd /c "flutter devices 2>&1"
cmd /c "flutter run -d <deviceId> 2>&1"                       # needs the phone (see android-device skill)
cmd /c "flutter build apk --release --target-platform android-arm64 --split-per-abi 2>&1"
```

Output: `app\build\app\outputs\flutter-apk\app-arm64-v8a-release.apk`. Report the real path and size; never claim the APK works on the phone until it was installed and launched.

## Project rules from the PRD (do not break)

- Target ABI is `arm64-v8a` only; minimum target device is the Infinix X6871 (Android 15, 12 GB RAM).
- LLM inference, model loading, CSV/XLSX parsing never run on the UI isolate. Use a long-lived `Isolate` and stream results; batch UI updates (50–100 ms), not per token.
- KPIs are computed by Dart code/SQL, never by the LLM. Keep fixture tests that check numbers.
- API keys only in `flutter_secure_storage`. Never log them, store them in SQLite/SharedPreferences, or include them in exports. `android:allowBackup="false"` (or backup exclusion rules) must stay.
- Default AI mode is `Offline Only`: no network calls. Any remote provider goes through the AI Router, with HTTPS and user opt-in.
- Don't bundle GGUF models in the APK or commit them to git.
- UI text is Indonesian.
