# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A fully local system that turns PDFs and EPUBs into navigable audiobooks narrated with
**Kokoro-82M**, plus a no-build web player (chapter/topic nav, full-text search,
karaoke-style sentence highlighting, note-taking with Markdown/Obsidian export, full-screen
reading mode). Python (FastAPI + ingest pipeline) backend; vanilla JS frontend. Everything runs
on the user's machine — no cloud, except a **Firebase layer that is the single source of truth for
reading progress** (per-sentence, realtime, offline-cached, with live cross-device follow) plus
notes sync (see "Cloud sync & progress" below); the FastAPI server stays local either way.

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
./scripts/ingest.sh x.pdf --smart-parse    # force LLM structure profiling (--no-smart-parse / --reprofile)
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

### LLM-assisted structure parsing (`app/structure.py`) — optional, cached, fail-safe
The generic cleaning heuristics (`textproc.detect_running_lines`,
`pdf_extract._detect_headings_by_font`) can't catch book-specific cruft: running headers with
OCR drift, per-line watermarks, letter-spacing artifacts (`T H E`), TOC/cover bleed, spoken
chapter-heading labels. So a **headless `claude -p` call runs once per book on a small page
*sample*** (front matter, embedded TOC, each chapter's first page + PDF line geometry,
mid-body, back matter — capped at `STRUCTURE_SAMPLE_BUDGET` chars) and returns a compact
**`StructureProfile`**: cleaning rules + a corrected chapter list. It never sees the whole book
and never returns prose — only rules. Deterministic code applies the profile:
`apply_cleaning` (drop patterns/substrings/decoratives/page-numbers, fix letter-spacing,
geometry header/footer zones), `build_markers` (`trust` the embedded TOC | `correct` a curated
list | `derive` from a heading pattern — reusing the existing `_locate_*` offset helpers),
`should_skip_section` + `strip_heading_labels` (honored in `ingest.segment_chapters`).
- **Fits `BookDoc`**: the extractors route through `structure` when enabled and otherwise take
  the **exact** heuristic path (byte-identical). `BookDoc.profile` (the applied rules) +
  `structure_source` (`llm`|`heuristic`) flow to ingest and into the manifest.
- **The one offset-sensitive spot**: `segment_chapters` trims leading heading labels from a
  chapter's `text` and advances `ch.start` by the same char count, so sentence `cs`/`ce` and
  topic timings stay aligned (same invariant as the rest of the pipeline).
- **Enablement**: `structure.enabled()` reads `STRUCTURE_LLM` (`auto` = on iff the `claude` CLI
  is on PATH; `1`/`0` force). CLI `--smart-parse`/`--no-smart-parse`/`--reprofile`; the server's
  `/api/ingest` inherits the config default, so uploads profile automatically when `claude` is
  present. **Fail-safe**: no `claude`, timeout, or bad JSON → the `HEURISTIC` sentinel → today's
  heuristic path. Never blocks ingest.
- **Cached** by source-content hash under `STRUCTURE_CACHE_DIR` (`library/.cache/structure/`),
  so re-ingest / `--resume` is free; a readable copy is written to `<book-id>/structure.json`
  (hand-editable — edit it and `--reprofile` is *not* needed, but the cache wins unless you
  delete it). Uses the existing Claude Code login: **no API key, no new dependency**; ~1
  call/book (~$0.10, ~2 min).
- **Exploration tool** (`app/structure_tool.py`): a read-only `page <N>` (text + geometry) /
  `find <text>` inspector exposed to the model via a scoped `Bash` allowlist so it can pull
  extra pages when the sample is ambiguous. Seed-first: a rich sample yields a good profile even
  if the tool goes unused. `structure.load_views(path)` (which the tool calls) is the shared
  loader; `epub_extract.load_spine`/`toc_entries` back the EPUB side.
- **Known limit**: headings mangled by the PDF's own glyph extraction (letter-spacing *inside*
  words, digit-for-letter substitution, mixed-case prefixes like `Case Study`) can survive on a
  chapter's first sentence — no clean rule catches them and more heuristics would be fragile.
  EPUBs (clean markup) don't have this.

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
espeak-ng, defaults to **CPU** because it benchmarks faster than MPS for this 82M model),
`VoxtralEngine` (optional premium engine — Mistral's **Voxtral-4B-TTS**, run locally via
**MLX/`mlx-audio`** on Apple Silicon; 20 presets, 9 languages, also 24 kHz so the pipeline is
byte-for-byte unchanged; lazily imports `mlx-audio`, loads the quantized model **once** and
reuses it per sentence; weights are **CC BY-NC 4.0** (non-commercial) and it's heavier/slower
than Kokoro; select with `TTS_ENGINE=voxtral` / `--engine voxtral`, deps via
`./scripts/setup.sh --voxtral`, repo/voice via `VOXTRAL_REPO`/`VOXTRAL_VOICE`), or
`DummyEngine` (silent tone sized to word count — the key tool for fast dev/verification). An
engine returns float32 mono 24kHz PCM from `synth(text)`. **MLX runs on Metal, not CoreML**, so
Voxtral is unaffected by CoreML/ANE issues. Voxtral still synthesizes **per sentence** (same as
Kokoro), which is what keeps the manifest's per-sentence `s`/`e` timings — and thus karaoke
highlighting + click-to-seek — working; the tradeoff is that per-sentence chunking forgoes some
of Voxtral's cross-sentence prosody. A Kokoro-style/empty voice id (e.g. the default `af_heart`)
is auto-mapped to the Voxtral preset so `--engine voxtral` works without also passing `--voice`.

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

### Phone pairing (`app/netinfo.py`) — mDNS auto-discovery + QR, no more typing IPs
So the mobile app doesn't need the Mac's IP hand-typed, the server makes itself findable two
ways, both **best-effort / fail-safe** (any missing dep or blocked network degrades to the next
option, never an error): (1) **mDNS** — advertises `_audiobook._tcp` (via `zeroconf`) in the
FastAPI **lifespan** so the app lists this computer to tap; (2) **QR** — `GET /api/pair.svg`
renders the LAN URL as an SVG (pure-Python from `qrcode`'s matrix, **no Pillow/lxml**), shown by
the web player's **📱 Connect your phone** button. `GET /api/server-info` reports the reachable
`urls`/`primary` + `lan_reachable`. `netinfo` finds LAN IPv4s with the UDP-connect trick (no
dependency) and `friendly_name()`. **Gotcha**: the server only knows its own bind host/port
because `scripts/run.sh` **`export`s `HOST`/`PORT`** and `config.py` reads them back
(`BIND_HOST`/`PORT`); mDNS only advertises — and the QR panel only stops warning — when
`lan_reachable` (bound to `0.0.0.0`, i.e. `HOST=0.0.0.0`). `run.sh` prints the network URL at
startup via `python -m app.netinfo`. Mobile side: `services/discovery.dart` (`nsd`, prefers the
resolved IPv4) + `screens/scan_screen.dart` (`mobile_scanner`, needs `CAMERA`) feed
`browse_screen.dart`; both new plugins and the QR/mDNS deps are additive.

### Player (`web/`, no build step)
Vanilla JS served statically. Loads the manifest, renders sentences as clickable spans, and
syncs the active sentence to playback via the `<audio>` `timeupdate` event + binary search on
sentence start times. Search is client-side (indexes manifest sentences); the resume point lives
only in Firestore (+ its offline cache) — no `localStorage` progress — and doubles as the realtime
cross-device follow source (see "Cloud sync & progress"). During generation it polls `genstate`; the generation
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
a file, extracts to `<Audiobooks>/<id>/` — the **same flat layout** the desktop serves —
and plays offline. It's a deliberate re-implementation of `web/app.js` minus generation:
`just_audio` + `just_audio_background` for playback and lock-screen controls, a `just_audio`
playlist (`setAudioSources`) of the chapter MP3s, and the **same binary-search-on-
sentence-start-times** sync — `findActiveSentence` in `mobile/lib/models/manifest.dart`
ports the web `findActiveIndex`. The manifest stays the single contract:
`mobile/lib/models/manifest.dart` mirrors it field-for-field (terse sentence keys included)
and replicates the "missing chapter status = ready" leniency via `Chapter.isReady`.

### Mobile persistent storage — books survive reinstall + auto-discovery
Books live in a **shared, file-explorer-visible `<external-root>/Audiobooks/<id>/` folder**, not
app-internal storage (which Android wipes on uninstall). `services/storage_access.dart` resolves
the real shared root via a native `MethodChannel` (`getStorageInfo` → `{externalRoot, sdkInt}` in
`MainActivity.kt`, using `Environment.getExternalStorageDirectory()`) and requests **All files
access** (`Permission.manageExternalStorage` on API ≥30, legacy `Permission.storage` below) — the
`MANAGE_EXTERNAL_STORAGE` (+ legacy) perms are declared in the manifest. `LibraryStore` prefers
that folder when access is held and **falls back to `<app docs>/books/` when it isn't** (so the app
never breaks), tracked by `usingFallback`; the library screen shows a grant banner and re-checks on
app-resume, calling `reset()` after a grant to switch folders. A **one-time migration** copies any
books from the old internal folder into the shared one (prefs flag `migratedToShared`).
- **Auto-discovery is free**: `LibraryStore.list()` already surfaces any `<folder>/manifest.json`,
  so a hand-dropped book folder just appears. Folder name need **not** equal the manifest id —
  playback/notes/progress key off the actual `InstalledBook.dir`, so `NotesStore` takes an
  `InstalledBook` (not a path rebuilt from the id).
- **Reading-state durability**: notes live in `notes.json` inside the (persistent) book folder;
  **reading progress lives only in Firestore** (+ its offline cache) — there is no local progress
  file or prefs copy anymore (the old `progress_sidecar.dart` and `SharedPreferences pos:*` were
  removed). An **anonymous-auth baseline** (see below) means there's always a uid, so progress is
  offline-durable and reinstall-safe *once signed in with a real account* (an anonymous-only uid is
  app-local and lost on uninstall — signing in carries history across reinstalls/devices).

### Cloud sync & progress (Firebase) — Firestore is the single source of truth for progress
**Reading progress is Firestore-only** — no `localStorage`/`SharedPreferences`/sidecar copy. Its
**offline persistence** (web `persistentLocalCache`; mobile `Settings(persistenceEnabled: true)` in
`main.dart`) is the local store, so resume + realtime cross-device follow run off one mechanism,
work offline, and queue writes until reconnect. **Anonymous-auth baseline**: both clients sign in
anonymously on first launch so there's *always* a uid (Firestore needs one to store/cache anything);
signing in with email **links** that uid so anonymous history carries over, and sign-out drops back
to a fresh anonymous session. Notes still sync too, and `notes.json` stays a local mirror. The
FastAPI server is untouched — clients talk to Firestore directly (no Admin SDK, no server secrets).
*If Firebase isn't configured at all (no `firebase-config.js` / `firebase_options.dart`), there is
no progress persistence — a deliberate dev tradeoff, since progress is no longer additive.*
- **Web** (`web/sync.js`, an ES module — the *only* place Firebase is imported; loaded from the
  gstatic CDN to keep the no-build-step rule). It dynamically imports the git-ignored
  `web/firebase-config.js` (absent/placeholder → disabled) and exposes `window.abkSync`.
  Inversion of control to dodge classic-vs-module load-order races: `app.js` sets handlers on
  `window.ABK` in `init()` and calls `window.abkSync?.…` guarded; `sync.js` calls
  `window.ABK.onAuthChange` once auth resolves.
- **Mobile** (`mobile/lib/services/sync_store.dart`, a `ChangeNotifier` seam registered in
  `main.dart`, live whenever `flutterfire configure` has generated `lib/firebase_options.dart` — a
  uid exists from the anonymous baseline; the guarded init never blocks startup). `available` = any
  uid; **`signedInWithAccount`** = a real (non-anonymous) account, which gates the account screen +
  the library cloud icon. `awaitUid()` lets a cold first open still resume. `settings_store` keeps
  `clientId`/`si` helpers but **no longer stores a resume position**.
- **Data model** (identical both sides): progress = fields on the book doc
  `users/{uid}/books/{bookId}` (`{ci,t,si,frac,updated(ms),device,deviceName}`); notes = one doc per
  note under `…/books/{bookId}/notes/{noteId}`. `updated` drives LWW (mirrors `notes.merge_notes`);
  `device`=clientId (echo suppression), `deviceName` labels the follow banner ("Playing on Web/Android").
- **Per-sentence progress + auto-follow**: written on each active-sentence change (debounced ~1s /
  coalesced), plus a flush on pause/seek/chapter/unload/background. Resume = the shared doc's latest
  (one doc per account per book, so it already holds the furthest spot), read **cache-first** so it's
  instant + offline. Both sides run a **realtime listener** (`SyncStore.progressStream` / `watchProgress`)
  driving **cross-device auto-follow**: while this device is idle/paused and another device is
  *actively* playing (a `device`≠ours update within ~12s), it **mirrors that device's position live** —
  seeking the paused player so the karaoke highlight + scroll track it, with a "Playing on
  \<deviceName\>" banner (`PlayerController.following`/`followingDeviceName` + reader `_followBanner`;
  web `followRemote`/`#followBanner`). It **never** moves during our own playback; any transport action
  (or the banner's Stop) is a take-over that resumes from the mirrored spot, and progress writes are
  **suppressed while following** so the mirrored spot never echoes back as ours. The mobile library
  screen follows `SyncStore.allProgressStream` so cards + "Continue" update live.
- **Notes**: Firestore is the shared truth when signed in; **`notes.json` stays an identical
  mirror** so export/`.abk` keep working. One-time reconcile on open (LWW) → realtime listener;
  create/update/delete dual-write. **Soft-delete tombstones** (`deleted:true`, always filtered
  out of `notes.json`) make deletions propagate without resurrection. Web keeps ids aligned by
  minting the id client-side and persisting via `POST …/notes/sync` (honors the id) instead of
  `POST …/notes` (reassigns). Mobile reuses `NotesStore.mergeById` (the Dart twin of
  `merge_notes`).
- **Enablement**: web = copy `firebase-config.example.js` → `firebase-config.js`; mobile =
  `flutterfire configure` (generates `lib/firebase_options.dart`). Same Firebase project/rules
  for both (README "Optional cloud sync"). Minimal FlutterFire path (explicit `FirebaseOptions`
  via `DefaultFirebaseOptions.currentPlatform`) → **no Gradle edits / google-services plugin
  needed** (a generated `google-services.json` is git-ignored and unused).

### Reading mode (full-screen) — both surfaces
Distraction-free reading that keeps audio + karaoke highlight + click/tap-to-seek working on the
same sentence spans. Web: an `#app.reading` class hides `#topbar`/`#sidebar`/`#player` and a
floating `#readingControls` auto-hides; `f` toggles, `Esc` exits. Mobile: null
`appBar`/`bottomNavigationBar` + `SystemChrome` immersive, an auto-hiding control pill; the ⛶
button enters, ✕/system-Back exits (`PopScope`). Mobile's sentence tap recognizers still win on
words (seek), so a tap on the gaps toggles the controls.

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
  (just_audio_background needs it for the shared FlutterEngine) **and** override
  `configureFlutterEngine` to register the `getStorageInfo` `MethodChannel` (call `super` first);
  `minSdk >= 23`, and cleartext HTTP must be enabled (LAN server is `http://`). Persistent book
  storage needs **All files access** — the app opens the system grant screen from the library
  banner; without it the library silently uses the app-internal fallback (books lost on uninstall). The phone reaches the desktop over Wi-Fi, so
  serve with `HOST=0.0.0.0`; from an Android emulator the host is `10.0.2.2`. Only
  `status == "ready"` books are packageable. The on-device integration test
  (`mobile/integration_test/app_test.dart`) needs a running server (override its URL with
  `--dart-define=SERVER_URL=...`).
