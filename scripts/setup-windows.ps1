$ErrorActionPreference = "Stop"

Write-Host "Bretune Transfer - Windows setup" -ForegroundColor Cyan
if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
    Write-Host "Flutter is not installed or is not in PATH." -ForegroundColor Red
    Write-Host "Install Flutter from https://docs.flutter.dev/get-started/install/windows then reopen PowerShell."
    exit 1
}

Set-Location (Split-Path -Parent $PSScriptRoot)
flutter doctor
flutter create --platforms=windows,android --org com.bretunetech --project-name bretune_transfer .
dart run tool/configure_platforms.dart
flutter pub get
flutter analyze

Write-Host "" 
Write-Host "Setup complete." -ForegroundColor Green
Write-Host "Run the Windows app with: flutter run -d windows"
Write-Host "Build an installer-ready Windows release with: .\scripts\build-windows.ps1"
Write-Host "Build Android APK with: .\scripts\build-android.ps1"
