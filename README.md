# 🎧 Audiobook Reader

Turn your **PDFs and EPUBs** into navigable audiobooks, narrated locally with
[**Kokoro-82M**](https://huggingface.co/hexgrad/Kokoro-82M), and listen in a
web player with chapter/topic navigation, full-text search, and
karaoke-style text highlighting that stays in sync with the voice.

Everything runs **on your machine** — no cloud required. *(Optional: sync your reading
progress & notes across devices via your own Firebase project — see
[Optional cloud sync](#optional-cloud-sync-firebase).)*

## Features

- **Local neural narration** with Kokoro-82M (multiple voices, adjustable speed).
- **Listen while it generates** — chapters render one at a time, so the first
  chapter is playable within seconds while the rest finish in the background.
  The player auto-continues as later chapters land.
- **Pause / resume / cancel** generation from the player at any time. Cancelled or
  interrupted books keep their finished chapters and can be **resumed** later
  (from the player's *Resume generating* button or `--resume` on the CLI).
- **PDF and EPUB** input. EPUBs use their built-in navigation/TOC for clean
  structure; PDFs use the outline/bookmarks (with font-size heading detection
  and fixed-size sections as fallbacks).
- **Automatic chapter & topic detection** — sub-headings become navigable topics
  nested under each chapter.
- **Web player**: play/pause, seek, ±10s, prev/next chapter, speed 0.75–2×, volume.
- **Synced highlighting** — the current sentence is highlighted and auto-scrolls;
  click any sentence to jump the audio there.
- **Search** the whole book (text + chapter/topic titles); click a result to jump.
- **Reading mode** — a full-screen, distraction-free view (press `F`): the player chrome
  slides away and the text fills the screen, with audio and highlighting still in sync.
- **Resume** where you left off (per book), saved in your browser.
- **Optional cloud sync** — sign in (email + password, your own Firebase project) to sync
  **reading progress (per sentence)** and **notes/highlights** across the web player and the
  phone app. Off by default; fully local until you configure it.
- **Add books from the browser** (upload a PDF → watch the progress bar) or via CLI.
- **Take it on your phone** — package a finished book and play it **offline** in the
  companion Flutter app (Android), with the same navigation, search and synced highlighting.
- **Keyboard shortcuts** for everything.

## Requirements

- macOS / Linux, **Python 3.13** (managed automatically by [`uv`](https://docs.astral.sh/uv/)).
- [`uv`](https://docs.astral.sh/uv/) — `curl -LsSf https://astral.sh/uv/install.sh | sh`
- **ffmpeg** (for MP3 output) — `brew install ffmpeg` *(WAV is used if missing)*
- **espeak-ng** (better pronunciation of rare words) — `brew install espeak-ng`

## Quick start

```bash
# 1. Install base deps + the Kokoro/PyTorch stack
./scripts/setup.sh --tts

# 2. (recommended) system tools for best quality
brew install ffmpeg espeak-ng

# 3. Start the player
./run
# opens http://127.0.0.1:8000 in your browser
```

`./run` is the only command you need day to day: it starts the player + API, makes the
server visible to your phone on the same Wi-Fi, and opens the browser. `PORT=8001 ./run`,
`HOST=127.0.0.1 ./run` (local only) and `OPEN=0 ./run` override the defaults.

Then click **“+ Add a book”**, pick a file, a **model** (Kokoro, Voxtral, or the
silent test engine) and a voice, and press **Generate audiobook**. The first run
downloads the model (~hundreds of MB) once. When it finishes, the book opens in the player.

> Want to try the player UI immediately without the big download? Run
> `./scripts/setup.sh` (no `--tts`), start the server, and add a book with the
> **Dummy (test)** engine — it produces correctly-timed silent audio so you can
> exercise navigation, search and highlighting in seconds.

## Command-line ingest

You can also generate audiobooks from the terminal (useful for batch/overnight runs):

```bash
# one file
./scripts/ingest.sh ~/Books/sapiens.pdf --voice af_heart --speed 1.0

# every PDF dropped into library/inbox/
./scripts/ingest.sh

# fast pipeline test, no model needed
./scripts/ingest.sh sample.pdf --engine dummy

# resume an interrupted run (only missing chapters are regenerated)
./scripts/ingest.sh ~/Books/sapiens.pdf --resume
```

The book appears in the web library as soon as ingest starts and becomes
playable chapter-by-chapter — you can start listening from the browser while a
CLI run is still generating later chapters.

## Premium voices — Voxtral-4B (optional, Apple Silicon)

Alongside Kokoro you can narrate with Mistral AI's
[**Voxtral-4B-TTS**](https://huggingface.co/mistralai/Voxtral-4B-TTS-2603) — a larger, more
expressive model (20 preset voices across 9 languages) that runs **fully offline** via
[MLX](https://github.com/ml-explore/mlx) on Apple Silicon. It's well suited to complex
non-fiction where tone and prosody matter.

```bash
# one-time: install the MLX stack (mlx-audio); the ~2.5 GB 4-bit model downloads on first run
./scripts/setup.sh --voxtral

# narrate with Voxtral instead of Kokoro
./scripts/ingest.sh ~/Books/essays.pdf --engine voxtral --voice casual_male
```

In the browser you can also just pick **Voxtral** (and its voice) from the **Model**
dropdown in the *Add a book* dialog — no flags needed; unavailable engines show as
*not installed*.

Voices include `casual_male`, `casual_female`, `cheerful_female`, `neutral_male`,
`neutral_female` (English) plus `fr_*`, `es_*`, `de_*`, `it_*`, `pt_*`, `nl_*`, `ar_male`,
`hi_*`. Pick the quantization with `VOXTRAL_REPO` (default `…-mlx-4bit`; `…-mlx-6bit` /
`…-mlx-bf16` trade size for quality) and set a default with `TTS_ENGINE=voxtral` /
`VOXTRAL_VOICE=…`.

> **Notes.** Voxtral is heavier and slower than Kokoro-82M (it's a 4B model), so expect longer
> generation. Its weights are **CC BY-NC 4.0 (non-commercial)** — Kokoro (Apache-2.0) remains the
> default. MLX runs on the GPU (Metal), so this path is unaffected by CoreML/ANE issues.
> To keep its narration flowing naturally, Voxtral synthesizes a whole paragraph at once (rather
> than sentence-by-sentence) and recovers the per-sentence timings that drive highlighting via
> forced alignment (torchaudio's `MMS_FA`, already installed; its ~300 MB model downloads once).

## Controlling generation

While a book is generating, the player's banner gives you live controls:

- **Pause / Resume** — halt and continue synthesis (keeps the model loaded).
- **Cancel** — stop generating; chapters already finished stay playable.
- **Resume generating** — shown on a cancelled/incomplete book; continues from the
  first unfinished chapter (needs the original file still in `library/inbox/`).

On the CLI, press **Ctrl-C** to stop (the book is marked *cancelled* with its
finished chapters intact), then continue later with `--resume`.

Generated audiobooks live in `library/books/<book-id>/` (one MP3 per chapter +
`manifest.json`). They appear automatically in the web library.

## Listen on your phone

Finished books can be played **offline** in the companion **Flutter app**
(`mobile/`, Android). A book is bundled as a single **`.abk`** file — a ZIP of
`manifest.json` + the chapter MP3s — and gets onto the phone two ways:

- **Download over Wi-Fi** — start the server so your phone can reach it
  (`./run` — it binds `0.0.0.0` for exactly this) and open the app's **Connect** screen. With both
  on the same Wi-Fi you don't need any IP address: this computer **appears in the list
  automatically** (mDNS) — just tap it. Can't see it? Click **📱 Connect your phone** in
  the web player's top bar and **scan the QR code**, or type the address by hand as before
  (`192.168.1.20:8000`). Then download any *ready* book. (The startup log and the QR panel
  both print the exact address to use.)
- **Import a file** — build the package on your computer and move it to the phone
  (AirDrop / Files / USB / cloud), then **Import** it in the app:

  ```bash
  ./scripts/export.sh <book-id>       # writes <book-id>.abk to the current dir
  ./scripts/export.sh                  # packages every "ready" book
  ```

  (Or use the **⤓** button on a book card in the web library — it hits the same
  `GET /api/books/<id>/package` endpoint.)

The app stores books on the device and plays them fully offline, with the same
chapter/topic navigation, full-text search, synced sentence highlighting, resume,
speed/volume, and background playback with lock-screen controls. See
[`mobile/README.md`](mobile/README.md) to build and run it.

## Optional cloud sync (Firebase)

By default the reader is fully local — progress lives in your browser and notes in each book's
`notes.json`. If you want your **listening position (synced per sentence)** and your
**notes & highlights** to follow you across the web player and the phone app, you can turn on
optional sync backed by **your own** [Firebase](https://firebase.google.com) project. It stays
off — and the app behaves exactly as before — until you add a config file.

**One-time setup:**

1. Create a Firebase project, then enable **Firestore Database** and the **Email/Password**
   sign-in provider (Authentication → Sign-in method).
2. In *Project settings → Your apps*, add a **Web app** and copy its config values.
3. Copy `web/firebase-config.example.js` → `web/firebase-config.js` and paste your values.
   (These are public client identifiers, not secrets — access is controlled by the rules
   below, and `firebase-config.js` is git-ignored.)
4. Paste these **Firestore security rules** (Firestore → Rules) so each account only ever
   touches its own data:

   ```
   rules_version = '2';
   service cloud.firestore {
     match /databases/{database}/documents {
       match /users/{uid}/{document=**} {
         allow read, write: if request.auth != null && request.auth.uid == uid;
       }
     }
   }
   ```

5. Restart the player, click **☁ Sign in** (top bar), and sign in with the **same email** on
   every device.

**Data model** (per account): `users/{uid}/books/{bookId}` holds the progress
`{ci, t, si, frac, updated, device}`; `users/{uid}/books/{bookId}/notes/{noteId}` holds one
doc per note. `notes.json` is kept as an identical local mirror so exports and `.abk` packaging
keep working; note deletions use soft-delete tombstones so they propagate without reappearing.

**Good to know:**

- The **first load** needs internet (the Firebase SDK loads from Google's CDN and you sign in);
  Firestore's offline cache then covers subsequent offline use.
- Sync is **additive** — signed out, or with no `firebase-config.js`, nothing changes.
- The phone app uses the **same** Firebase project — see [`mobile/README.md`](mobile/README.md).

## How it works

```
PDF / EPUB ─▶ extract text + TOC ─▶ clean & split into chapters/sentences
                                          │
                                          ▼
                         Kokoro-82M synthesizes each sentence
                                          │
                                          ▼
        concatenate → per-chapter MP3  +  manifest.json (sentence timings)
                                          │
                                          ▼
                 FastAPI serves audio + manifest → web player
```

- **Structure** comes from the EPUB nav/TOC, or the PDF outline (`level` + page).
  Sub-headings become navigable **topics** inside a chapter. No TOC? PDFs detect
  headings by font size and EPUBs fall back to one chapter per document; failing
  that, the text is chunked into ~1400-word sections.
- **Timing**: each sentence is synthesized separately, so we record its exact
  start/end time. That powers seeking, highlighting, and jump-to-search-result.
- **Seeking** works because the server serves audio with HTTP range support.
- **Streaming generation**: the manifest (with the full chapter list) is written
  *before* any audio, then each chapter flips from *pending* → *ready* as its
  audio is encoded. The player polls the manifest, plays ready chapters
  immediately, and auto-continues as later chapters finish. Interrupted runs
  resume from the first unfinished chapter.

## Configuration (environment variables)

| Variable | Default | Meaning |
|---|---|---|
| `TTS_ENGINE` | `kokoro` | `kokoro` or `dummy` |
| `KOKORO_VOICE` | `af_heart` | default voice id |
| `KOKORO_LANG` | `a` | `a`=US, `b`=UK English |
| `KOKORO_SPEED` | `1.0` | narration speed |
| `KOKORO_DEVICE` | `cpu` | `cpu`/`mps`/`auto`. CPU is usually fastest for this 82M model on Apple Silicon (~7× real-time on an M3 Pro). |
| `AUDIO_FORMAT` | `mp3` | `mp3` or `wav` |
| `WORDS_PER_FALLBACK_CHAPTER` | `1400` | section size when no outline exists |
| `AUDIOBOOK_LIBRARY` | `./library` | where books are stored |

Example: `KOKORO_VOICE=am_michael KOKORO_DEVICE=cpu ./scripts/run.sh`

## Voices

US (`KOKORO_LANG=a`): `af_heart`, `af_bella`, `af_nicole`, `af_sarah`,
`am_michael`, `am_adam`, `am_fenrir`.
UK (`KOKORO_LANG=b`): `bf_emma`, `bm_george`.
(See the [Kokoro voices list](https://huggingface.co/hexgrad/Kokoro-82M) for more.)

## Keyboard shortcuts

| Key | Action |
|---|---|
| `Space` | play / pause |
| `←` / `→` | back / forward 10s |
| `↑` / `↓` | previous / next sentence |
| `[` / `]` | previous / next chapter |
| `/` | focus search |
| `B` / `N` | bookmark / add a note at the current spot |
| `F` | reading mode (full screen) |
| `Esc` | exit reading mode / clear search / back to library |

## Troubleshooting

- **“ffmpeg failed” / files are `.wav`** — install ffmpeg (`brew install ffmpeg`).
  WAV works too, just larger.
- **Odd pronunciation of unusual words** — install `espeak-ng`
  (`brew install espeak-ng`); Kokoro uses it as a pronunciation fallback.
- **Generation speed / device** — the default is CPU, which benchmarks faster
  than MPS for Kokoro-82M on Apple Silicon (~7× real-time on an M3 Pro, so a
  10-hour book renders in ~1.3 hours). Try `KOKORO_DEVICE=mps` if you prefer the
  GPU, but expect it to be slower for this small model.
- **First generation is slow** — the model downloads once and caches under
  `~/.cache/huggingface`. Subsequent runs are much faster.

## Project layout

```
app/            FastAPI backend + ingest pipeline
  extract.py       shared book model + PDF/EPUB dispatcher
  pdf_extract.py   PDF → text + chapter/topic markers
  epub_extract.py  EPUB → text + chapter/topic markers
  textproc.py      cleaning + sentence segmentation
  tts/             kokoro_engine.py, dummy_engine.py
  audio.py         concatenation + MP3 encoding
  ingest.py        orchestration + CLI
  export.py        package a ready book into a .abk + CLI
  server.py        API + static serving
web/            no-build vanilla JS player (index.html, app.js, styles.css)
  sync.js          optional Firebase (Firestore) progress + notes sync
  firebase-config.example.js   copy to firebase-config.js to enable sync
mobile/         Flutter app (Android) — plays packaged .abk books offline
library/inbox/  drop PDFs here
library/books/  generated audiobooks
run             one-command launcher (wraps scripts/run.sh with LAN + browser defaults)
scripts/        setup.sh, run.sh, ingest.sh, export.sh
```
