<#
.SYNOPSIS
  Mengonfigurasi proyek Unity Agent HQ lalu mengekspornya ke app\android\unityLibrary (flutter_embed_unity).

.DESCRIPTION
  Langkah 1: AgentHQSetup.Configure (scene, URP, Player Settings) dalam batchmode.
  Langkah 2: ProjectExporterBatchmode.ExportProject (plugin flutter_embed_unity) ke app\android\unityLibrary.
  Membutuhkan Unity 6000.3.26f1 dengan modul Android dan lisensi yang sudah aktif.

.PARAMETER SkipSetup
  Lewati langkah 1 jika proyek sudah dikonfigurasi.
#>
[CmdletBinding()]
param(
    [switch]$SkipSetup,
    [string]$UnityPath = 'D:\MobileDeveloper\Unity\Editors\6000.3.26f1\Editor\Unity.exe'
)

$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent $PSScriptRoot
$project = Join-Path $repo 'unity\AgentHQ'
$exportPath = Join-Path $repo 'app\android\unityLibrary'
$scratch = Join-Path $env:TEMP 'agenthq-unity'
New-Item -ItemType Directory -Force -Path $scratch | Out-Null

if (-not (Test-Path $UnityPath)) {
    Write-Error "Unity.exe tidak ditemukan: $UnityPath"
    exit 1
}
if (-not (Test-Path (Join-Path $project 'Packages\manifest.json'))) {
    Write-Error "Proyek Unity tidak ditemukan: $project"
    exit 1
}

function Invoke-Unity {
    param([string]$Label, [string[]]$Arguments, [string]$LogFile)

    Write-Host "== $Label" -ForegroundColor Cyan
    Write-Host "   log: $LogFile"
    if (Test-Path $LogFile) { Remove-Item $LogFile -Force }

    $process = Start-Process -FilePath $UnityPath -ArgumentList $Arguments -Wait -PassThru -NoNewWindow
    $code = $process.ExitCode

    if (Test-Path $LogFile) {
        Write-Host "--- 40 baris terakhir $LogFile ---"
        Get-Content $LogFile -Tail 40
        Write-Host '---'
        $problems = Select-String -Path $LogFile -Pattern 'AgentHQSetup\] GAGAL|error CS|Exception:|Export incomplete'
        if ($problems) {
            Write-Host "Baris bermasalah di log:" -ForegroundColor Yellow
            $problems | Select-Object -First 20 | ForEach-Object { Write-Host "  $($_.Line)" }
        }
    }

    if ($code -ne 0) {
        Write-Error "$Label gagal (exit code $code). Periksa $LogFile"
        exit $code
    }
}

$common = @('-batchmode', '-nographics', '-quit', '-projectPath', "`"$project`"", '-buildTarget', 'Android')

if (-not $SkipSetup) {
    $setupLog = Join-Path $scratch 'unity_setup.log'
    Invoke-Unity -Label 'Langkah 1: AgentHQSetup.Configure' -LogFile $setupLog -Arguments ($common + @(
        '-executeMethod', 'AgentHQSetup.Configure',
        '-logFile', "`"$setupLog`""))
}

$exportLog = Join-Path $scratch 'unity_export.log'
Invoke-Unity -Label 'Langkah 2: ProjectExporterBatchmode.ExportProject' -LogFile $exportLog -Arguments ($common + @(
    '-executeMethod', 'ProjectExporterBatchmode.ExportProject',
    '-exportPath', "`"$exportPath`"",
    '-logFile', "`"$exportLog`""))

$buildGradle = Join-Path $exportPath 'build.gradle'
if (-not (Test-Path $buildGradle)) {
    Write-Error "Ekspor tidak menghasilkan $buildGradle"
    exit 1
}

$streaming = Select-String -Path $exportLog -Pattern '^unityStreamingAssets=' | Select-Object -First 1
Write-Host ''
Write-Host "Ekspor selesai: $exportPath" -ForegroundColor Green
if ($streaming) {
    Write-Host "Tambahkan ke app\android\gradle.properties: $($streaming.Line)" -ForegroundColor Yellow
} else {
    Write-Host 'Tambahkan ke app\android\gradle.properties: unityStreamingAssets=' -ForegroundColor Yellow
}
Write-Host 'Lalu build Flutter dengan: flutter build apk --dart-define=UNITY_EMBED=true'
exit 0
