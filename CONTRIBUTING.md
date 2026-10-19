# Contributing to kickFile

Thanks for helping. Bug reports, translations and pull requests are welcome: open an issue at <https://github.com/ukpratik/kickfile/issues>. For anything bigger than a small fix, open an issue first so we can agree on the approach.

## Reporting a bug

Include the two devices and their OS versions, how they were connected (same Wi-Fi, hotspot, VPN on?), what you did and what happened. **Settings › Help › Export logs** saves a diagnostic file without file names; attach it if you can.

## Rules that keep kickFile simple, private and maintainable

1. **Local only.** kickFile talks to other kickFile devices on the local network and nothing else: no servers, analytics, crash reporting, ads or update checks. Pull requests that add network calls outside the LAN won't be merged.
2. **Free dependencies only.** Every dependency must be open source and GPL-3.0-compatible (MIT, BSD, Apache-2.0, MPL-2.0, …), and must not pull in Google Play Services, Firebase or other proprietary SDKs: kickFile ships on F-Droid. Keep new dependencies rare and explain each one in the pull request.
3. **Protocol compatibility.** Devices on different versions must keep working together. Wire changes go through [docs/PROTOCOL.md](docs/PROTOCOL.md) first; additive changes are fine, breaking ones need a new protocol version.
4. **Tests with the code.** Logic gets unit tests; transfer behaviour gets a two-device test on loopback (see `app/test/support/nodes.dart`). Before pushing, run in `app/`:
   ```bash
   flutter analyze
   flutter test
   ```
   CI runs the same, then builds Android, macOS, Windows and Linux.
5. **Design.** Use the theme tokens in `app/lib/ui/theme/tokens.dart`, not raw colours or sizes. Every control needs a screen-reader label, touch targets stay at least 48 dp on mobile, and screens must work in light and dark themes and at 200% text size.
6. **Source headers.** Start each new source file with `// SPDX-License-Identifier: GPL-3.0-or-later`.
7. **Commits.** Conventional commits (`feat:`, `fix:`, `docs:`, `build:` …), small and focused. The code style is the existing one: 160-column lines, `flutter analyze` clean.

By contributing you agree that your contribution is licensed under GPL-3.0-or-later.

## Handy for development

- `app/test/tools/peer_test.dart` starts a headless kickFile peer on this computer, to test against a phone without a second laptop. See the comment at the top of the file.
- `tool/video/` explains how the how-to video and screenshots are rendered from the real UI.
