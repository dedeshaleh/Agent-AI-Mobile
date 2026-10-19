---
name: android-device
description: Install, launch, and inspect Agent HQ builds on the user's Android phone (Infinix X6871) over ADB, including logcat crashes, memory, thermal, and screenshots. Use when deploying an APK, when the app crashes or is killed on the phone, or when collecting benchmark numbers (RAM, temperature, FPS) for the PRD.
---

# Android device workflow

## Find adb

Use the first one that exists:

```powershell
$adb = @(
  'D:\Webserver\Mobile\Agent-AI-Mobile\.tools\android\platform-tools\adb.exe',
  (Get-ChildItem 'D:\MobileDeveloper\Unity\Editors\*\Editor\Data\PlaybackEngines\AndroidPlayer\SDK\platform-tools\adb.exe' -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName),
  'D:\MobileDeveloper\android-sdk\platform-tools\adb.exe'
) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
```

If none exists, say adb is missing and stop; don't guess another path.

## Connect

```powershell
& $adb devices -l
```

The user usually connects with **Wireless debugging** (Android 11+), not USB:

1. Pairing (once per PC, or after "Forget"): the user opens *Developer options → Wireless debugging → Pair device with pairing code* and gives `IP:pairPort` and a 6-digit code. Run `& $adb pair <IP:pairPort> <code>` right away; the code expires when that dialog closes.
2. Connect: the connect port is different from the pairing port and changes whenever Wireless debugging restarts. Run `& $adb mdns services` and look for the `_adb-tls-connect._tcp` entry; adb usually auto-connects. Otherwise run `& $adb connect <IP:connectPort>` using the "IP address & Port" on the Wireless debugging screen.
3. Connect only to the user's phone (`model:Infinix_X6871`). Other `_adb._tcp` services on the office network belong to other people; ignore them.

When a wireless device is connected, pass `-s <serial>` only if more than one device is listed. Prefer no `-s` at all: after a reconnect the phone often appears only under its mDNS serial (`adb-…._adb-tls-connect._tcp`) and a stale `-s 192.168.x.x:port` makes adb hang on "waiting for device".

Large pushes (≈1 GB GGUF) over Wi-Fi debugging drop the connection on this phone; download models inside the app instead of `adb push`.

`pm list packages` may print `SecurityException ... user 999` on XOS (dual-app profile). This is harmless.

- Need exactly one line ending in `device`. `unauthorized` means the user must accept the RSA prompt on the phone. Empty means USB debugging is off or the cable is charge-only.
- Ask the user before running anything that uninstalls the app or clears data. Uninstalling deletes saved missions and notes.

## Install and launch

```powershell
& $adb install -r <path-to.apk>
& $adb shell monkey -p <applicationId> -c android.intent.category.LAUNCHER 1
```

Known application IDs: Godot demo `id.agenthq.officedemo`. For the Flutter app, read `applicationId` from `app\android\app\build.gradle*`.

`INSTALL_FAILED_UPDATE_INCOMPATIBLE` means a signature mismatch. Explain it and ask before uninstalling.

## Diagnose

```powershell
& $adb logcat -c
& $adb logcat -v time *:E AndroidRuntime:E flutter:V godot:V DEBUG:V   # crash + app logs
& $adb shell pidof <applicationId>
& $adb shell dumpsys meminfo <applicationId>          # TOTAL PSS = RAM used
& $adb shell dumpsys thermalservice                   # thermal status / throttling
& $adb shell dumpsys battery
& $adb shell cat /proc/meminfo | Select-Object -First 3
& $adb exec-out screencap -p > <scratchpad>\screen.png   # then Read the PNG to see it
```

Run logcat with a timeout or in the background; it never exits on its own.

XOS (Infinix) kills background apps aggressively. If the process disappears, check `adb logcat | Select-String 'lowmemorykiller|am_kill|Process .* has died'` before blaming the app. Ask the user to set battery mode to "No restrictions" for the app when benchmarking.

## Benchmarks (PRD §12 Fase 0 / docs/LLM_PHONE.md)

Record: date, XOS version, model + quantization, context, threads, load time, time to first token, tokens/s, peak PSS from `meminfo`, thermal status after 10 minutes, and whether the game stays responsive. Write numbers only from real measurements on the device; otherwise leave "Belum diuji".
