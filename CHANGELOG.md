# Changelog

All notable changes to kickFile. Versions follow [SemVer](https://semver.org); the Android `versionCode` is `MAJOR×10000 + MINOR×100 + PATCH`.

## 1.0.1 (2026-10-19)

- New app icon ("Beam": a file sending a local signal) on every platform, including Android themed icons, the status bar, the tray and the Linux window.
- The pairing code stops working after 10 wrong tries.
- Settings › About links to the source code.

## 1.0.0 (2026-10-19)

First public release, for Android, macOS, Windows and Linux.

- Send files, photos, videos, folders and text in both directions over Wi-Fi or a phone hotspot, with no internet.
- Devices find each other automatically (DNS-SD, with a subnet probe fallback), or connect with a QR code or short code.
- Encrypted (TLS with per-device certificates); a 6-digit code to check on first contact; trusted devices can auto-accept.
- Every transfer is checked with SHA-256 and resumes after a dropped connection; stalled transfers are detected after 15 s.
- Android: share to kickFile from any app; photos and videos go to the gallery, other files to Downloads/kickFile; transfers keep running with the screen off.
- Desktop: drag and drop, system tray, optional start at login.
- "Get kickFile on your other devices" page with a QR code and download links for every platform.
- Light and dark themes.
