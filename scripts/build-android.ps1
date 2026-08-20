$ErrorActionPreference = "Stop"
Set-Location (Split-Path -Parent $PSScriptRoot)
dart run tool/configure_platforms.dart
flutter pub get
flutter analyze
flutter test
flutter build apk --release
Write-Host "Android APK: build\app\outputs\flutter-apk\app-release.apk" -ForegroundColor Green
