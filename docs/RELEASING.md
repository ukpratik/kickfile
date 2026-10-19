# Releasing kickFile

One tag, several channels:

| Channel | What | Built by | Signed by |
|---|---|---|---|
| **GitHub Releases** | Android APKs | Maintainer, locally | Release key (`kickfile`) |
| | macOS DMG, Windows zip, Linux tar.gz | `release.yml` on the tag | macOS: ad-hoc (not notarised); Windows/Linux: unsigned |
| **F-Droid** | Android APK, built from the tag | F-Droid | F-Droid's key |
| **Google Play** *(later)* | App bundle | Maintainer | Upload key; Play re-signs |

The Android builds have different signers, so a phone can't update one with another: to switch channel, uninstall first. Nothing secret is ever in this repository; `*.jks`, `*.keystore` and `key.properties` are git-ignored.

## Versioning

- `version:` in `app/pubspec.yaml` is `X.Y.Z+CODE`, with `CODE = X×10000 + Y×100 + Z` (1.0.0 = `1.0.0+10000`, 1.0.1 = `+10001`, 1.1.0 = `+10100`).
- Tags are `vX.Y.Z`, on a clean commit on `main`. A released version is never rebuilt or overwritten: a fix is a new version.

## Signing key (one time)

| Key | File (outside the repo) | Alias | Gradle properties |
|---|---|---|---|
| Release key | `~/.android-keys/kickfile-release.jks` | `kickfile` | `kickfile.release.*` |

```bash
mkdir -p ~/.android-keys && chmod 700 ~/.android-keys
keytool -genkeypair -v -keystore ~/.android-keys/kickfile-release.jks -storetype PKCS12 \
  -alias kickfile -keyalg RSA -keysize 4096 -validity 10000
chmod 600 ~/.android-keys/kickfile-release.jks
```

Add to `~/.gradle/gradle.properties` (your home folder, **not** the repo):

```properties
kickfile.release.storeFile=/Users/<you>/.android-keys/kickfile-release.jks
kickfile.release.storePassword=<password>
kickfile.release.keyAlias=kickfile
kickfile.release.keyPassword=<password>
```

Without them, release builds are unsigned (that's what CI and F-Droid do).

**Back up the key and its password together** (password manager plus one offline copy). Losing the key means GitHub installs can never be updated again.

### Certificate fingerprints

Check an APK with `apksigner verify --print-certs kickFile-android.apk`.

| Certificate | SHA-256 |
|---|---|
| Release key (`kickfile`): GitHub Releases APKs | `AC:55:3F:B6:F2:8C:10:44:20:47:F1:7C:72:B4:86:AA:AA:63:78:8F:3F:43:CE:58:B9:27:01:84:5A:97:B8:04` |
| F-Droid signing key: F-Droid installs | *from the F-Droid package page after the first F-Droid build* |

## Every release

1. **Version.** Bump `version:` in `app/pubspec.yaml`. Add a `CHANGELOG.md` entry and `fastlane/metadata/android/en-US/changelogs/<CODE>.txt` (plain text, ≤ 500 characters). Update the Settings › About version text.
2. **Gates.** In `app/`: `flutter analyze` and `flutter test` clean, and CI green on `main` (all four platforms).
3. **Tag** on a clean tree:
   ```bash
   git status --porcelain              # must print nothing
   git tag -a vX.Y.Z -m "kickFile X.Y.Z"
   git push origin vX.Y.Z
   ```
   `release.yml` builds the desktop apps and attaches them, with `SHA256SUMS-desktop.txt`, to a **draft** release.
4. **Android APKs**, from the tag:
   ```bash
   cd app
   flutter build apk --release                    # universal → kickFile-android.apk
   flutter build apk --release --split-per-abi    # → kickFile-android-arm64.apk, -armv7.apk, -x86_64.apk
   apksigner verify --print-certs <apk>           # must show the release fingerprint above
   gh release upload vX.Y.Z <apks> --clobber
   ```
   Asset names have no version, so `releases/latest/download/<name>` links on the site and in the app keep working.
5. **Archive** the files in `~/Desktop/PersonalProjects/builds/kickfile/X.Y.Z/` with `builds/archive-build.sh` (maintainer machine only; never committed).
6. **Publish** the draft release. Then, if `site/` changed, run **Actions › Pages**.
7. **F-Droid** (first time): copy `fdroid/io.github.ukpratik.kickfile.yml` into a merge request on [fdroiddata](https://gitlab.com/fdroid/fdroiddata), with `commit:` set to the tag's commit hash. Later releases are picked up automatically from the tags (`UpdateCheckMode: Tags`).
