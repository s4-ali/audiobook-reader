# Audiobook Player (mobile)

A Flutter (Android) companion app for the [Audiobook Reader](../README.md) project. It plays
**packaged audiobooks offline** with the same experience as the web player: chapter/topic
navigation, full-text search, karaoke-style sentence highlighting, tap-to-seek, resume,
speed/volume, background playback with lock-screen controls, a full-screen **reading mode**,
and — optionally — **cloud sync** of reading progress and notes (see below).

Generation stays on the desktop (it needs the Kokoro model); this app is playback-only.

## How books get here

A finished book is bundled into a single **`.abk`** file — a ZIP of `manifest.json` plus the
per-chapter MP3s (see [`app/export.py`](../app/export.py)). Two ways to load one:

1. **Download over Wi-Fi** — on the computer, run `HOST=0.0.0.0 ./scripts/run.sh`. In the
   app tap **Connect**, enter the computer's address (e.g. `192.168.1.20:8000`), and download
   any *ready* book.
2. **Import a file** — `./scripts/export.sh <book-id>` on the computer, move the `.abk` to the
   phone (AirDrop / Files / USB / cloud), then **Import** it in the app.

Books are extracted to the app's documents directory (`books/<book-id>/`) and play fully
offline.

## Cloud sync (optional)

Reading progress (**per sentence**) and notes can sync with the web player and your other
devices via **Cloud Firestore**, using the SAME Firebase project as the web app. It's off by
default — the app is fully local until you configure it.

1. Do the web setup in the [main README](../README.md#optional-cloud-sync-firebase) (create the
   Firebase project, enable Firestore + Email/Password, paste the security rules).
2. From `mobile/`, run **`flutterfire configure`** and pick the same project — it generates
   `lib/firebase_options.dart` (+ `android/app/google-services.json`) for the Android app
   (package `com.audiobook.audiobook_player`). `main.dart` initializes from it, guarded.
3. `flutter run`, then tap the **cloud** icon in the library and sign in with the same account
   you use on the web.

Notes:
- Uses the minimal FlutterFire path (explicit `FirebaseOptions`), so **no Gradle changes and no
  `google-services.json` are required**. If a future Firebase BoM demands `minSdk 24`, raise the
  `maxOf(23, …)` floor in `android/app/build.gradle.kts`.
- **Reading mode**: tap the **⛶** fullscreen icon in the reader; the floating controls auto-hide
  (tap to reveal, ✕ or Back to exit). Audio + highlighting keep running.

## Develop / run

```bash
cd mobile
flutter pub get
flutter analyze
flutter test                       # unit tests (manifest parsing + highlight binary search)
flutter run -d <android-device>    # or `flutter build apk`
```

### On-device end-to-end test

`integration_test/app_test.dart` exercises the real path on a device/emulator (LAN download →
extract → play → highlight, plus a UI smoke test). It needs the desktop server running and
serving a *ready* book with id `the-light-without-a-keeper` (ingest the bundled sample with
`--engine dummy` to create one quickly):

```bash
# computer: HOST=0.0.0.0 ./scripts/run.sh
flutter test integration_test/app_test.dart -d <android-device> \
  --dart-define=SERVER_URL=http://10.0.2.2:8000   # 10.0.2.2 = host alias from an AVD
```

## Layout

```
lib/
  models/manifest.dart        Dart mirror of manifest.json + findActiveSentence (binary search)
  services/
    settings_store.dart       persisted rate/volume/position(+si)/server URL (SharedPreferences)
    library_store.dart        on-device library under <app docs>/books/<id>/
    transfer.dart             LAN fetch/download (dio) + .abk extraction (flutter_archive)
    player_controller.dart    just_audio wrapper: playlist, streams, highlight sync, resume
    sync_store.dart           optional Firebase (Firestore) progress + notes sync (no-op if off)
  screens/
    library_screen.dart       installed books grid + Connect / Import / account
    browse_screen.dart        connect to server, list, download with progress
    reader_screen.dart        text + highlighting + outline/search + transport + reading mode
    account_screen.dart       email/password sign-in for cloud sync
  firebase_options.dart       Firebase options from `flutterfire configure` (drives sync)
  main.dart                   JustAudioBackground.init + guarded Firebase init + providers + theme
```

## Android notes

- `MainActivity` extends `AudioServiceActivity` (required by `just_audio_background`).
- `minSdk >= 23`; cleartext HTTP is enabled so the app can reach the desktop's `http://` LAN
  server. The media-session service + permissions are declared in `AndroidManifest.xml`.
- Cloud sync is additive — with no values in `lib/firebase_config.dart` the app runs exactly as
  before (local progress + notes only), and never blocks startup if Firebase can't initialize.
