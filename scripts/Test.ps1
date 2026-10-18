$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path -Parent $PSScriptRoot
$taskGodot = Join-Path $taskRoot '.tools/godot/Godot_v4.5.1-stable_win64_console.exe'
& $taskGodot --headless --path (Join-Path $taskRoot 'game') --editor --import --quit
if ($LASTEXITCODE -ne 0) { throw 'Import failed' }
foreach ($taskTest in @('run_tests.gd', 'ui_smoke.gd')) {
    & $taskGodot --headless --path (Join-Path $taskRoot 'game') --script (Join-Path $taskRoot "tests/$taskTest")
    if ($LASTEXITCODE -ne 0) { throw "Failed: $taskTest" }
}
