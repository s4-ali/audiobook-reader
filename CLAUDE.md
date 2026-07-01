# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A fully local system that turns PDFs and EPUBs into navigable audiobooks narrated with
**Kokoro-82M**, plus a no-build web player (chapter/topic nav, full-text search,
karaoke-style sentence highlighting, note-taking with Markdown/Obsidian export). Python
(FastAPI + ingest pipeline) backend; vanilla JS frontend. Everything runs on the user's
machine — no cloud.

## Commands

The Python interpreter is the project venv: `.venv/bin/python`. The `scripts/*.sh` wrappers
`cd` to the repo root so `app` is importable; to invoke modules directly use
`PYTHONPATH=. .venv/bin/python -m app.<module>`.

```bash
./scripts/setup.sh --tts          # create .venv (uv, Python 3.13) + install base + Kokoro/torch
brew install ffmpeg espeak-ng     # ffmpeg = MP3 output; espeak-ng = pronunciation fallback
./scripts/run.sh                  # serve player+API at http://127.0.0.1:8000 (env: HOST, PORT)
./scripts/ingest.sh <file.pdf|epub> [--voice af_heart --speed 1.0 --resume]
./scripts/ingest.sh               # ingest every PDF/EPUB in library/inbox/
./scripts/ingest.sh x.pdf --engine dummy   # fast pipeline test, no model download
./scripts/export.sh <book-id>              # package a ready book → <book-id>.abk (mobile app)
.venv/bin/python scripts/make_sample_pdf.py     # writes library/inbox/sample-book.pdf
.venv/bin/python scripts/make_sample_epub.py    # writes library/inbox/sample-book.epub
```

### Verifying changes (there is no test suite / linter / build step)

- **Whole pipeline + player without the model**: ingest with `--engine dummy` (generates
  silent audio sized to the text, with correct timings) then open the player. This is the
  primary way to exercise everything quickly.
- **Syntax**: `node --check web/app.js` and `.venv/bin/python -m py_compile app/*.py`.
- **Isolation**: set `AUDIOBOOK_LIBRARY=/tmp/somedir` (read at import in `app/config.py`) to
  run ingest/server against a throwaway library without touching `library/`.
- **HTTP endpoints in-process**: `from fastapi.testclient import TestClient` against
  `app.server.app` (httpx is installed). To exercise pause/cancel timing, subclass
  `DummyEngine` to `time.sleep()` per `synth` and pre-insert it into `server._engine_cache`.

## Architecture

### `manifest.json` is the central contract
Every book lives in `library/books/<book-id>/` as per-chapter audio files plus a
`manifest.json`. The ingest pipeline writes it, the server serves it, the player consumes it
— changing its shape touches all three. Key fields: top-level `status`
(`generating`|`ready`|`partial`|`cancelled`) and `chapters_ready`/`chapters_total`; each
chapter has `status` (`pending`|`ready`|`error`), `audio`, `duration`, `topics[]`, and
`sentences[]`. Sentence keys are terse: `i` index, `t` text, `s`/`e` start/end **seconds**,
`cs`/`ce` char offsets into the chapter text, `p` paragraph-break flag. The per-sentence
`s`/`e` timings are what power seeking, highlighting, and jump-to-search-result; they exist
because each sentence is synthesized separately.

### `BookDoc` unifies PDF and EPUB
`app/extract.py` defines the shared `BookDoc` (cleaned `linear_text`, `page_offsets`,
`markers`) and `Marker` (level 1 = chapter, level ≥2 = topic). `extract.extract(path)`
dispatches by extension to `pdf_extract.py` (PyMuPDF outline → font-heading heuristic →
fixed chunks) or `epub_extract.py` (ebooklib spine + nav TOC → one-chapter-per-document
fallback). Everything downstream is format-agnostic because it only sees a `BookDoc`.

### Ingest pipeline (`app/ingest.py`) — streaming + resumable
`ingest_pdf()` (handles both formats despite the name): `extract` → `segment_chapters`
(splits `linear_text` at level-1 marker offsets, attaching level-≥2 markers as topics; falls
back to ~1400-word sections) → for each chapter: `split_sentences` (pysbd, `app/textproc.py`)
→ `engine.synth` per sentence → concatenate with inter-sentence/paragraph silence →
`audio.write_audio` (pipes raw PCM to ffmpeg → MP3, WAV fallback). **The skeleton manifest
(all chapters `pending`) is written before any audio, then rewritten atomically after each
chapter completes** — that's what makes a book playable while later chapters render. `resume`
skips chapters already `ready` with an existing audio file.

### Pluggable TTS (`app/tts/`)
`make_engine()` returns `KokoroEngine` (real; lazily imports torch/kokoro, configures
espeak-ng, defaults to **CPU** because it benchmarks faster than MPS for this 82M model) or
`DummyEngine` (silent tone sized to word count — the key tool for fast dev/verification). An
engine returns float32 mono 24kHz PCM from `synth(text)`.

### Generation control (`JobControl` in `app/ingest.py`)
Pause/cancel are `threading.Event`s checked at `control.checkpoint()` between every sentence
and chapter (blocks while paused, raises `GenerationCancelled` when cancelled). Cancel keeps
already-finished chapters and sets manifest `status="cancelled"`; the run is resumable.

### Server (`app/server.py`)
FastAPI. Ingest runs in background threads (`_spawn_job`), with a cached engine
(`_engine_cache`), an in-memory job registry (`_jobs`), per-job `_controls`, and a
`_book_jobs` map. **Jobs are in-memory only** — a server restart drops active jobs, but the
on-disk manifest makes the book resumable. Endpoints: `/api/library`, `/api/ingest` (upload),
`/api/books/{id}/manifest`, control endpoints `pause`/`resume`/`cancel`, and the lightweight
`/api/books/{id}/genstate` (what the player polls — returns counts + `active`/`paused` so the
full manifest is only re-fetched when a chapter finishes). Audio + manifests are served via
`StaticFiles` at `/media` (supports HTTP Range → seeking); the web UI is mounted at `/`.

### Player (`web/`, no build step)
Vanilla JS served statically. Loads the manifest, renders sentences as clickable spans, and
syncs the active sentence to playback via the `<audio>` `timeupdate` event + binary search on
sentence start times. Search and resume are client-side (search indexes manifest sentences;
position saved to `localStorage`). During generation it polls `genstate`; the generation
banner doubles as the pause/resume/cancel control surface.

### Notes / annotations (`app/notes.py`) — a second sibling contract
Per-book reading notes live in `library/books/<id>/notes.json` (`{book, version, notes[]}`),
**never inside `manifest.json`** (ingest rewrites the manifest; notes must survive that).
`app/notes.py` owns storage (locked, atomic write like `_write_manifest_atomic`) + validation
+ pure `to_markdown`/`to_obsidian` exporters (mirrors `subtitles.py`). One record type: a
`highlight` is a `note` with an empty body. Each note anchors to a **sentence range `[si..sj]`**
with a durable text quote (`exact` + `prefix`/`suffix`, Hypothesis-style re-anchoring) plus
fast-path hints (`si/sj`, `cs/ce`, `s/e`) copied from the manifest. **`cs`/`ce` index the
original extracted chapter text the frontend never sees — they're pass-through metadata, not
used for DOM/re-anchoring** (the player re-anchors against per-sentence `t`). Server endpoints
(in `server.py`, mirroring the transcript/subtitles style): `GET/POST /api/books/{id}/notes`,
`PATCH/DELETE …/notes/{note_id}`, `GET …/notes.md?flavor=obsidian|plain`, and
`POST …/notes/sync` (merge by `id`, last-write-wins on `updated` — the mobile push/pull
primitive). The player (`web/app.js`) adds select-to-highlight, a note editor, a sidebar
`#notesPanel`, in-text highlight washes (`.sent.hl-*`, painted so `.active` still wins), and
key `n` / the 📝 button for a note at the current spot. `.abk` packaging bundles `notes.json`
when present, and the mobile app (`mobile/lib/models/note.dart`, `services/notes_store.dart`)
mirrors the record + exporters field-for-field and syncs via `…/notes/sync`.

### `.abk` packaging + mobile app (`app/export.py`, `mobile/`)
`export.package_book(book_id)` zips a **ready** book's `manifest.json` + chapter MP3s
(`ZIP_STORED` — MP3 is already compressed) into `<book-id>.abk`, with all members at the
archive root keeping their bare names so the manifest's `audio` references resolve
unchanged. Exposed as a CLI (`app/export.py` / `scripts/export.sh`) and as
`GET /api/books/{id}/package` (builds into a tempdir, streams via `FileResponse`, cleans up
with a `BackgroundTask`; 409 if the book isn't `ready`). The Flutter app under `mobile/`
(Android) consumes it: it downloads `.abk` over the LAN (reusing `/api/library`) or imports
a file, extracts to `<app docs>/books/<id>/` — the **same flat layout** the desktop serves —
and plays offline. It's a deliberate re-implementation of `web/app.js` minus generation:
`just_audio` + `just_audio_background` for playback and lock-screen controls, a `just_audio`
playlist (`setAudioSources`) of the chapter MP3s, and the **same binary-search-on-
sentence-start-times** sync — `findActiveSentence` in `mobile/lib/models/manifest.dart`
ports the web `findActiveIndex`. The manifest stays the single contract:
`mobile/lib/models/manifest.dart` mirrors it field-for-field (terse sentence keys included)
and replicates the "missing chapter status = ready" leniency via `Chapter.isReady`.

## Conventions & gotchas

- **CPU is the default TTS device** (`KOKORO_DEVICE`, see `app/config.py`); MPS is slower for
  Kokoro-82M on Apple Silicon. All tunables (voice, gaps, fallback chapter size, paths) are
  env vars in `config.py`.
- **Manifest is read fresh from disk on every request** and written atomically
  (`_write_manifest_atomic`), so partial reads never happen and state survives restarts.
- **Backward compatibility**: treat a chapter with no `status` field as ready — the player
  uses `isReady()` for this; mirror that leniency in any new manifest-reading code.
- CSS uses `[hidden] { display: none !important; }` because the toggled elements (`#modal`,
  `#player`, …) set an explicit `display` that would otherwise beat the `hidden` attribute.
- **MP3 output must be CBR, never VBR** (`config.MP3_BITRATE` → ffmpeg `-b:a`, not `-q:a`).
  The per-sentence `s`/`e` timings are raw-PCM sample offsets; for them to line up with what a
  player seeks to, the file needs an exact time↔byte mapping. CBR gives that (every frame is
  the same byte size); VBR does not, so browsers (`<audio>.currentTime`) and ExoPlayer/just_audio
  fall back to interpolating the coarse Xing TOC and land seeks *seconds* off — that desyncs the
  karaoke highlight and sends click-to-seek to the wrong sentence. Re-encoding VBR→CBR is
  content-preserving (identical duration + sample timeline), so `scripts/reencode_cbr.py` fixes
  legacy books in place without re-running TTS.
- MP3 encoding adds a fixed ~50 ms leading delay vs. the raw-PCM-derived timings — a constant
  offset, negligible for sentence-level highlighting; don't try to "fix" it per chapter.
- **Mobile (`mobile/`) Android gotchas**: `MainActivity` must extend `AudioServiceActivity`
  (just_audio_background needs it for the shared FlutterEngine), `minSdk >= 23`, and cleartext
  HTTP must be enabled (LAN server is `http://`). The phone reaches the desktop over Wi-Fi, so
  serve with `HOST=0.0.0.0`; from an Android emulator the host is `10.0.2.2`. Only
  `status == "ready"` books are packageable. The on-device integration test
  (`mobile/integration_test/app_test.dart`) needs a running server (override its URL with
  `--dart-define=SERVER_URL=...`).
