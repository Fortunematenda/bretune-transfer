# Bretune Transfer

Local Wi‑Fi file transfer for **Windows** and **Android**. Pair devices on the same network, then send files or folders. There is no cloud relay — transfers stay on your LAN.

## Downloads

Installers are hosted at [bretunetech.com/downloads](https://bretunetech.com/downloads/):

- [Windows installer](https://bretunetech.com/downloads/BretuneTransfer-Setup-1.1.0.exe)
- [Windows portable zip](https://bretunetech.com/downloads/BretuneTransfer-Windows-x64-1.1.0-portable.zip)
- [Android APK](https://bretunetech.com/downloads/bretune-transfer.apk)

## Requirements

- Same Wi‑Fi network on both devices
- Windows: allow Bretune Transfer through Private network firewall
- Android: camera permission for QR pairing; storage access for sending files

## Build

```bash
flutter pub get
flutter test
flutter build windows --release
flutter build apk --release
```

Windows packaging (installer + portable zip):

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\package-windows.ps1
```
