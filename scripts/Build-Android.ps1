$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path -Parent $PSScriptRoot
$taskGodot = Join-Path $taskRoot '.tools/godot/Godot_v4.5.1-stable_win64_console.exe'
$taskJdk = Get-ChildItem -LiteralPath (Join-Path $taskRoot '.tools/java') -Directory | Select-Object -First 1
if (-not $taskJdk) { throw 'JDK 17 belum tersedia. Lihat docs/ANDROID_BUILD.md.' }
$env:JAVA_HOME = $taskJdk.FullName
$env:ANDROID_HOME = Join-Path $taskRoot '.tools/android'
$env:ANDROID_SDK_ROOT = $env:ANDROID_HOME
$env:PATH = "$env:JAVA_HOME\bin;$env:ANDROID_HOME\platform-tools;$env:PATH"
$taskSettings = Join-Path $taskRoot '.tools/godot/editor_data/editor_settings-4.5.tres'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $taskSettings) | Out-Null
New-Item -ItemType File -Force -Path (Join-Path $taskRoot '.tools/godot/_sc_') | Out-Null
$taskJavaPath = $taskJdk.FullName.Replace('\', '/')
$taskSdkPath = $env:ANDROID_HOME.Replace('\', '/')
@"
[gd_resource type="EditorSettings" format=3]

[resource]
export/android/java_sdk_path = "$taskJavaPath"
export/android/android_sdk_path = "$taskSdkPath"
"@ | Set-Content -LiteralPath $taskSettings -Encoding UTF8
New-Item -ItemType Directory -Force -Path (Join-Path $taskRoot 'build') | Out-Null
& $taskGodot --headless --path (Join-Path $taskRoot 'game') --editor --import --quit
if ($LASTEXITCODE -ne 0) { throw 'Project import failed' }
& $taskGodot --headless --path (Join-Path $taskRoot 'game') --export-debug Android (Join-Path $taskRoot 'build/AgentHQ-demo.apk')
if ($LASTEXITCODE -ne 0) { throw 'Android export failed. Check Godot error output.' }
Get-Item -LiteralPath (Join-Path $taskRoot 'build/AgentHQ-demo.apk') | Select-Object FullName,Length
