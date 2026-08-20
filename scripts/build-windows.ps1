$ErrorActionPreference = "Stop"
Set-Location (Split-Path -Parent $PSScriptRoot)
flutter pub get
flutter analyze
flutter test
flutter build windows --release
& (Join-Path $PSScriptRoot "package-windows.ps1")
