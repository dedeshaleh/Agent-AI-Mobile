$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path -Parent $PSScriptRoot
$taskAdb = Join-Path $taskRoot '.tools/android/platform-tools/adb.exe'
$taskApk = Join-Path $taskRoot 'build/AgentHQ-demo.apk'
if (-not (Test-Path -LiteralPath $taskApk)) { throw 'APK belum tersedia. Jalankan Build-Android.ps1.' }
if (-not (Test-Path -LiteralPath $taskAdb)) { throw 'ADB belum tersedia. Lihat docs/ANDROID_BUILD.md.' }
& $taskAdb devices
if ($LASTEXITCODE -ne 0) { throw 'ADB gagal dijalankan' }
$taskDevices = @(& $taskAdb devices | Where-Object { $_ -match '\sdevice$' })
if ($taskDevices.Count -ne 1) { throw 'Hubungkan tepat satu HP, aktifkan USB debugging, lalu izinkan laptop dari layar HP.' }
& $taskAdb install -r $taskApk
if ($LASTEXITCODE -ne 0) { throw 'Instalasi APK gagal' }
& $taskAdb shell monkey -p id.agenthq.officedemo -c android.intent.category.LAUNCHER 1
if ($LASTEXITCODE -ne 0) { throw 'APK terpasang, tetapi gagal dibuka otomatis. Buka Agent HQ Demo di HP.' }
