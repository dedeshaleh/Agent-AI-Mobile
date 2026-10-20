# Build the Flutter APK, push it to the phone over Wi-Fi with a transfer
# percentage, install it, and launch it. Every stage prints "[n/4] ... xx%" and
# the same line is written to -ProgressFile so another terminal (or an agent) can
# tail the status while this runs in the background.
#
#   .\scripts\Deploy-Phone.ps1 -Serial 192.168.137.141:38653
#   .\scripts\Deploy-Phone.ps1 -Serial <ip:port> -SkipBuild      # push the last APK only
#   .\scripts\Deploy-Phone.ps1 -Serial <ip:port> -Release
param(
  [Parameter(Mandatory = $true)] [string] $Serial,
  [switch] $SkipBuild,
  [switch] $Release,
  [switch] $NoUnity,
  [string] $ProgressFile = (Join-Path $env:TEMP 'agenthq-deploy-progress.txt')
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$app = Join-Path $root 'app'
$adb = 'D:\MobileDeveloper\android-sdk\platform-tools\adb.exe'
$env:Path += ';D:\MobileDeveloper\flutter\bin'
$env:JAVA_HOME = 'D:\MobileDeveloper\jdk-21'
$started = Get-Date

function Report([string] $line) {
  $stamp = '{0:mm\:ss}' -f ((Get-Date) - $started)
  $text = "[$stamp] $line"
  Write-Host $text
  Set-Content -LiteralPath $ProgressFile -Value $text -Encoding utf8
}

$flavor = if ($Release) { 'release' } else { 'debug' }
$apk = Join-Path $app "build\app\outputs\flutter-apk\app-$flavor.apk"

# ---- 1/4 build -------------------------------------------------------------
if (-not $SkipBuild) {
  Report '[1/4] Build APK 0% (flutter build apk, biasanya 1-4 menit)'
  $args = @('build', 'apk', "--$flavor", '--target-platform', 'android-arm64')
  if (-not $NoUnity) { $args += '--dart-define=UNITY_EMBED=true' }
  $log = Join-Path $env:TEMP 'agenthq-build.log'
  # Gradle has no global percentage; surface its task names as coarse progress.
  $stages = @{ 'configureCMake' = 10; 'buildCMake' = 25; 'compileFlutterBuild' = 45; 'compileDebugKotlin' = 60; 'compileReleaseKotlin' = 60; 'mergeDex' = 75; 'package' = 85; 'assemble' = 95 }
  $pct = 0
  $failed = $false
  if (Test-Path -LiteralPath $log) { Remove-Item -LiteralPath $log -Force }
  Push-Location $app   # flutter must run where pubspec.yaml lives
  try {
    & cmd /c "flutter $($args -join ' ') -v 2>&1" | ForEach-Object {
      $line = $_
      foreach ($k in $stages.Keys) {
        if ($line -match "Task :app:$k" -and $stages[$k] -gt $pct) { $pct = $stages[$k]; Report "[1/4] Build APK $pct% ($k)" }
      }
      if ($line -match 'Error:|error:|FAILED|Exception') { Write-Host $line; $failed = $true }
      Add-Content -LiteralPath $log -Value $line
    }
  } finally { Pop-Location }
  # A stale APK from an earlier build must not be mistaken for this build's output.
  if ($failed -or -not (Test-Path -LiteralPath $apk) -or (Get-Item $apk).LastWriteTime -lt $started) {
    Report "[1/4] Build GAGAL (lihat $log)"; throw 'Build gagal'
  }
  $size = [math]::Round((Get-Item $apk).Length / 1MB, 1)
  Report "[1/4] Build APK 100% ($size MB)"
} else {
  if (-not (Test-Path -LiteralPath $apk)) { throw "APK tidak ada: $apk" }
  Report "[1/4] Build dilewati, pakai $apk"
}

# ---- 2/4 push --------------------------------------------------------------
& $adb connect $Serial | Out-Null
$total = (Get-Item $apk).Length
$remote = '/data/local/tmp/agenthq.apk'
Report "[2/4] Kirim ke HP 0% (0 / $([math]::Round($total/1MB)) MB)"
$push = Start-Process -FilePath $adb -ArgumentList @('-s', $Serial, 'push', $apk, $remote) -PassThru -WindowStyle Hidden
while (-not $push.HasExited) {
  Start-Sleep -Seconds 5
  $sent = (& $adb -s $Serial shell "stat -c %s $remote 2>/dev/null") -as [long]
  if ($sent) {
    $pct = [math]::Floor($sent * 100 / $total)
    $rate = [math]::Round($sent / 1MB / ((Get-Date) - $started).TotalSeconds, 1)
    Report "[2/4] Kirim ke HP $pct% ($([math]::Round($sent/1MB)) / $([math]::Round($total/1MB)) MB)"
  }
}
if ($push.ExitCode -ne 0) { Report '[2/4] Kirim GAGAL (koneksi putus? cek port wireless debugging)'; throw 'adb push gagal' }
Report '[2/4] Kirim ke HP 100%'

# ---- 3/4 install -----------------------------------------------------------
Report '[3/4] Instal di HP (pm install, 20-60 detik)'
$out = & $adb -s $Serial shell pm install -r $remote
if ("$out" -notmatch 'Success') { Report "[3/4] Instal GAGAL: $out"; throw 'pm install gagal' }
Report '[3/4] Instal 100%'

# ---- 4/4 launch ------------------------------------------------------------
# monkey writes its argument echo to stderr; no 2>&1 here or PowerShell 5.1 turns it into an error.
$ErrorActionPreference = 'Continue'
& $adb -s $Serial shell monkey -p id.agenthq.agent_hq -c android.intent.category.LAUNCHER 1 | Out-Null
$ErrorActionPreference = 'Stop'
Report '[4/4] Selesai, aplikasi dibuka di HP'
