# How-to video

Rebuild `media/kickFile-how-to.mp4` (1080p, captions + macOS `say` voice-over, plus a `.srt`).

1. **Desktop scenes:** the real UI, rendered with real transfers between in-process devices:
   `cd app && KF_VIDEO=<work>/desktop flutter test test/video`
2. **Android scenes:** `adb screenrecord` on an emulator against `test/tools/peer_test.dart` (`KF_PEER_NAME="Arjun's MacBook Air"`).
   Save them as `<work>/android/r1.mp4` … `r4.mp4`:
   - r1 · first run
   - r2 · phone → Mac
   - r3 · Mac → phone
   - r4 · Connection help + QR
3. **Build:** copy `build_video.py` into `<work>` and run `python3 build_video.py <out.mp4>`. It needs `ffmpeg` and Google Chrome. Scene text and timings are in `SCENES`; `ICON` points at the 1024 px app icon.

`media/` is git-ignored (large files).
