# 🎧 Audiobook Reader

Turn your **PDFs and EPUBs** into navigable audiobooks, narrated locally with
[**Kokoro-82M**](https://huggingface.co/hexgrad/Kokoro-82M), and listen in a
web player with chapter/topic navigation, full-text search, and
karaoke-style text highlighting that stays in sync with the voice.

Everything runs **on your machine** — no cloud, no accounts.

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
- **Resume** where you left off (per book), saved in your browser.
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
./scripts/run.sh
# open http://127.0.0.1:8000
```

Then click **“+ Add a PDF”**, pick a file and a voice, and press
**Generate audiobook**. The first run downloads the Kokoro model (~hundreds of
MB) once. When it finishes, the book opens in the player.

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
  (`HOST=0.0.0.0 ./scripts/run.sh`), open the app, tap **Connect**, enter your
  computer's address (e.g. `192.168.1.20:8000`), and download any *ready* book.
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
| `Esc` | clear search / back to library |

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
mobile/         Flutter app (Android) — plays packaged .abk books offline
library/inbox/  drop PDFs here
library/books/  generated audiobooks
scripts/        setup.sh, run.sh, ingest.sh, export.sh
```
