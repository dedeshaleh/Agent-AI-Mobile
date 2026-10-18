$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path -Parent $PSScriptRoot
$taskGodot = Join-Path $taskRoot '.tools/godot/Godot_v4.5.1-stable_win64_console.exe'
if (-not (Test-Path -LiteralPath $taskGodot)) { throw 'Godot belum tersedia. Lihat README.md.' }
& $taskGodot --path (Join-Path $taskRoot 'game')
