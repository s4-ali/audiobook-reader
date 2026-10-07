# Narrate selected text on Android: research notes

Date: 2026-10-08. Device: Pixel 9 Pro (Tensor G4), Android 17 / API 37.

## Question

Can a phone narrate whatever text is selected in another app (a blog in the browser, say) using
an open TTS model, started from the text-selection menu?

## Answer

Yes. Selecting text in Chrome, then **⋮ → Narrate**, speaks it with a model running entirely on
the phone. No server, no network after the voice is downloaded.

## How it works

- **Menu entry.** An activity with an `ACTION_PROCESS_TEXT` intent filter (`text/plain`) is listed
  in the selection toolbar of other apps; its `android:label` is the menu text. A second filter
  for `ACTION_SEND` puts the same entry in the share sheet.
- **Speech.** [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) 1.13.8 (ONNX Runtime, CPU)
  loads an unpacked model folder from `<external files>/tts/<name>/`.
- **Streaming.** Text is split into sentences. A synth thread renders one sentence at a time into
  a bounded queue and a playback thread drains it into a streaming `AudioTrack`, so audio starts
  once the first sentence is ready.
- **Lifetime.** A `mediaPlayback` foreground service owns playback, so it is meant to outlive the
  small panel that the menu opens. Both run in a separate `:narrate` process.

Code: `android/app/src/main/kotlin/com/audiobook/audiobook_player/narrate/`. Architecture and
gotchas are in the root `CLAUDE.md`.

## Measurements

Same 8-sentence paragraph (about 30 s of speech), 4 threads, release build. "Render speed" is
seconds of audio produced per second of compute; below 1× the phone cannot keep up with playback.

| Model | Download | Render speed | First audio (cold) |
|---|---|---|---|
| Piper `en_US-lessac-medium` | 64 MB | 6–8× | 1.3–2.6 s |
| Kitten nano v0.8 (fp32) | 61 MB | 3–6× | 1.7–3.5 s |
| Kokoro-82M v0.19 (fp32) | 305 MB | 1.2× cool, 0.6–0.7× warm | 3.7–9.9 s |
| Kokoro-82M v0.19 (int8) | 98 MB | 0.56× | 7.6 s |

Other findings:

- **Kokoro is borderline on this phone.** After a few minutes of work the phone reported light
  thermal throttling and Kokoro fell below real time, which is heard as pauses between sentences.
  Piper is the default for that reason.
- **int8 Kokoro is slower than fp32**, not faster, so the smaller download is not a way out.
- **4 threads was the best setting.** Runs at 2, 3, 5, 6 and 8 threads were all slower, though the
  later ones overlap with the phone warming up, so the comparison is not clean.
- **Model load** takes 1–3 s and is paid once per process, not per selection.

Audio quality was not assessed; the three voices need comparing by ear.

## Limitations

- **App coverage.** The entry only appears in apps that use Android's standard selection toolbar.
  Apps with a custom selection menu, or text that cannot be selected, will not show it. The share
  sheet is the fallback.
- **Placement.** In Chrome the entry sits under the ⋮ overflow. The host app and system decide
  the order; an app cannot pin itself to the first row.
- **Language.** The three voices are English only.
- **Controls.** Pause, resume and stop only. No sentence skipping, seeking or highlighting.
- **APK size.** The runtime adds about 85 MB of native libraries because three CPU architectures
  are packaged. An arm64-only build would add about 30 MB.

## Verified on the device

- Select in Chrome → ⋮ → Narrate → speech.
- Pause and resume from the panel.
- Switching voice mid-narration (restarts the current text with the new voice).
- In-app download, unpack and use of a voice.
- Automatic pause and resume when a notification sound takes audio focus.

## Not yet verified

- Pause and Stop from the notification.
- Dismissing the panel by tapping outside it while audio continues.
- Playback with the screen off.
- The share-sheet route from a real app (only triggered directly over adb).
- Very large selections.

## Build gotchas

- The sherpa-onnx AAR is not on Maven Central. `tool/fetch_narrate_deps.sh` downloads it into the
  git-ignored `android/app/libs/`; the Gradle build fails without it.
- Release builds run R8. sherpa-onnx's native code calls the synthesis callback by exact signature
  (`invoke([F)Ljava/lang/Integer;`), which a Kotlin lambda does not have. The first release build
  aborted with `NoSuchMethodError` until the callback became a real `Function1` class kept by
  `proguard-rules.pro`.
- `AudioTrack` buffer size must be a whole number of 4-byte float frames; Piper's 22050 Hz sample
  rate exposed this.

## Possible next steps

- Compare the voices by ear and settle the default.
- Try Kokoro v1.0 (has `af_heart`, the desktop default voice) and Kitten micro/mini.
- Sentence skip and a seekable position.
- Package arm64 only, or split APKs per architecture.
- Offer narration through the desktop server when it is reachable, for Kokoro quality without the
  phone's speed limit.
