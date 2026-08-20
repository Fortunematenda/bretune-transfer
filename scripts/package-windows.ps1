$ErrorActionPreference = "Stop"

function Get-AppVersion {
    $pubspec = Join-Path (Split-Path -Parent $PSScriptRoot) "pubspec.yaml"
    $match = Select-String -Path $pubspec -Pattern '^version:\s*(\S+)' | Select-Object -First 1
    if (-not $match) { throw "Could not read version from pubspec.yaml" }
    return ($match.Matches[0].Groups[1].Value -split '\+')[0]
}

Set-Location (Split-Path -Parent $PSScriptRoot)

$version = Get-AppVersion
$releaseDir = Join-Path $PWD "build\windows\x64\runner\Release"
$distDir = Join-Path $PWD "dist"
$stagingRoot = Join-Path $distDir "staging"
$stagingDir = Join-Path $stagingRoot "BretuneTransfer"

if (-not (Test-Path (Join-Path $releaseDir "bretune_transfer.exe"))) {
    Write-Host "Release build not found. Run: flutter build windows --release" -ForegroundColor Red
    exit 1
}

New-Item -ItemType Directory -Force -Path $distDir | Out-Null
Remove-Item $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $stagingDir | Out-Null
Copy-Item -Path (Join-Path $releaseDir "*") -Destination $stagingDir -Recurse -Force

$zipPath = Join-Path $distDir "BretuneTransfer-Windows-x64-$version-portable.zip"
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
Compress-Archive -Path $stagingDir -DestinationPath $zipPath -Force
Write-Host "Portable ZIP: $zipPath" -ForegroundColor Green

$sevenZip = @(
    "${env:ProgramFiles}\7-Zip\7z.exe",
    "${env:ProgramFiles(x86)}\7-Zip\7z.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1

if ($sevenZip) {
    $archivePath = Join-Path $distDir "BretuneTransfer-Windows-x64-$version-portable.7z"
    if (Test-Path $archivePath) { Remove-Item $archivePath -Force }
    & $sevenZip a -t7z $archivePath (Join-Path $stagingDir "*") | Out-Null
    Write-Host "Portable 7z:  $archivePath" -ForegroundColor Green
}

$iscc = @(
    "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
    "${env:ProgramFiles}\Inno Setup 6\ISCC.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1

if ($iscc) {
    $iss = Join-Path $PSScriptRoot "BretuneTransfer.iss"
    & $iscc "/DMyAppVersion=$version" $iss
    Write-Host "Installer:    dist\BretuneTransfer-Setup-$version.exe" -ForegroundColor Green
} else {
    Write-Host "Inno Setup not found. Install it to create BretuneTransfer-Setup.exe:" -ForegroundColor Yellow
    Write-Host "https://jrsoftware.org/isdl.php" -ForegroundColor Yellow
}

Remove-Item $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "Users can install like Dukto:" -ForegroundColor Cyan
Write-Host "  - Run BretuneTransfer-Setup.exe (installer), or"
Write-Host "  - Extract the portable zip/7z and run bretune_transfer.exe"
