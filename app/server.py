"""FastAPI app: serves the player, the library API, audio, and ingest jobs."""
from __future__ import annotations

import hashlib
import atexit
import json
import shutil
import tempfile
import threading
import traceback
import uuid
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Dict, Optional

from fastapi import FastAPI, HTTPException, UploadFile, File, Form, Request, Body
from fastapi.responses import JSONResponse, FileResponse, Response
from fastapi.staticfiles import StaticFiles
from starlette.background import BackgroundTask

from . import audio as audiomod, config, library, pronounce
from .extract import SUPPORTED_EXTS
from .ingest import ingest_pdf, JobControl, _write_manifest_atomic, Chapter, _render_chapter

config.ensure_dirs()


# "Listen to text" scratch space: pasted-text narrations live ONLY here (a fresh temp dir per
# server run, wiped on exit) and are never written to the library or TTS cache.
_QUICK_DIR = Path(tempfile.mkdtemp(prefix="abk-quick-"))
atexit.register(shutil.rmtree, _QUICK_DIR, True)


@asynccontextmanager
async def _lifespan(app: "FastAPI"):
    # Advertise the server over mDNS so the phone app can auto-discover it (fail-safe: no-ops
    # when localhost-only or when zeroconf isn't installed — never blocks startup).
    from . import netinfo
    handle = netinfo.start_mdns()
    try:
        yield
    finally:
        netinfo.stop_mdns(handle)


app = FastAPI(title="Audiobook Reader", lifespan=_lifespan)

# Curated Kokoro voices for the UI (lang_code 'a' = US, 'b' = UK).
VOICES = [
    {"id": "af_heart", "label": "Heart (US, female)"},
    {"id": "af_bella", "label": "Bella (US, female)"},
    {"id": "af_nicole", "label": "Nicole (US, female)"},
    {"id": "af_sarah", "label": "Sarah (US, female)"},
    {"id": "am_michael", "label": "Michael (US, male)"},
    {"id": "am_adam", "label": "Adam (US, male)"},
    {"id": "am_fenrir", "label": "Fenrir (US, male)"},
    {"id": "bf_emma", "label": "Emma (UK, female)"},
    {"id": "bm_george", "label": "George (UK, male)"},
]

# Curated Voxtral presets for the UI (mirrors app.tts.voxtral_engine.PRESET_VOICES; 9 languages).
VOXTRAL_VOICES = [
    {"id": "casual_male", "label": "Casual (EN, male)"},
    {"id": "casual_female", "label": "Casual (EN, female)"},
    {"id": "cheerful_female", "label": "Cheerful (EN, female)"},
    {"id": "neutral_male", "label": "Neutral (EN, male)"},
    {"id": "neutral_female", "label": "Neutral (EN, female)"},
    {"id": "fr_male", "label": "French (male)"},
    {"id": "fr_female", "label": "French (female)"},
    {"id": "es_male", "label": "Spanish (male)"},
    {"id": "es_female", "label": "Spanish (female)"},
    {"id": "de_male", "label": "German (male)"},
    {"id": "de_female", "label": "German (female)"},
    {"id": "it_male", "label": "Italian (male)"},
    {"id": "it_female", "label": "Italian (female)"},
    {"id": "pt_male", "label": "Portuguese (male)"},
    {"id": "pt_female", "label": "Portuguese (female)"},
    {"id": "nl_male", "label": "Dutch (male)"},
    {"id": "nl_female", "label": "Dutch (female)"},
    {"id": "ar_male", "label": "Arabic (male)"},
    {"id": "hi_male", "label": "Hindi (male)"},
    {"id": "hi_female", "label": "Hindi (female)"},
]

# UI metadata per engine (label + a one-line note shown under the picker).
ENGINE_LABELS = {
    "kokoro": "Kokoro-82M — fast, default",
    "voxtral": "Voxtral-4B — premium, slower",
    "dummy": "Dummy — silent test audio",
}
ENGINE_NOTES = {
    "kokoro": "Kokoro-82M, chapter by chapter — start listening as soon as the first chapter is "
              "ready while the rest finish. The model downloads once on first run.",
    "voxtral": "Mistral's Voxtral-4B via MLX (Apple Silicon) — higher fidelity across 9 languages, "
               "but roughly real-time to generate, so a long book takes a while.",
    "dummy": "Silent placeholder audio with correct timings — for quickly trying the player, no "
             "model needed.",
}

# In-memory registries for ingest progress + pause/cancel control.
_jobs: Dict[str, dict] = {}
_controls: Dict[str, JobControl] = {}   # job_id -> control
_book_jobs: Dict[str, str] = {}         # book_id -> latest job_id
_engine_cache: dict = {}
_engine_lock = threading.Lock()


def _get_engine(engine: str, voice: str, lang: str, speed: float, device: str):
    key = (engine, voice, lang, round(speed, 3), device)
    with _engine_lock:
        if key not in _engine_cache:
            from .tts import make_engine
            _engine_cache[key] = make_engine(engine=engine, voice=voice, lang=lang,
                                             speed=speed, device=device)
        return _engine_cache[key]


# --------------------------------------------------------------------------- API
@app.get("/api/library")
def api_library():
    return {"books": library.list_books()}


def _engine_availability() -> dict:
    """Which engines can actually run right now (cheap, import-only — no model load)."""
    import importlib.util

    def present(name: str) -> bool:
        try:
            return importlib.util.find_spec(name) is not None
        except Exception:
            return False

    return {
        "kokoro": present("torch") and present("kokoro"),
        "voxtral": present("mlx_audio") and present("mistral_common"),
        "dummy": True,
    }


@app.get("/api/voices")
def api_voices():
    avail = _engine_availability()
    voices_by_engine = {"kokoro": VOICES, "voxtral": VOXTRAL_VOICES, "dummy": []}
    default_voice_by_engine = {"kokoro": config.DEFAULT_VOICE,
                               "voxtral": config.VOXTRAL_VOICE, "dummy": "dummy"}
    engines = [
        {"id": eid, "label": ENGINE_LABELS[eid], "available": avail[eid],
         "voices": voices_by_engine[eid], "default_voice": default_voice_by_engine[eid],
         "note": ENGINE_NOTES[eid]}
        for eid in ("kokoro", "voxtral", "dummy")
    ]
    return {
        # Back-compat top-level fields (Kokoro), plus the per-engine breakdown the UI uses.
        "voices": VOICES, "default": config.DEFAULT_VOICE,
        "default_engine": config.DEFAULT_ENGINE, "engines": engines,
    }


@app.get("/api/health")
def api_health():
    """Diagnostics: tool/engine availability, effective audio format, library + config."""
    from . import health
    return health.health_report()


@app.get("/api/server-info")
def api_server_info():
    """This server's LAN address(es) + whether it's reachable from other devices.

    Powers the "Connect your phone" panel (QR + address) and lets the mobile app confirm a
    connection. See app/netinfo.py."""
    from . import netinfo
    return netinfo.server_info()


@app.get("/api/pair.svg")
def api_pair_svg():
    """A scannable QR of this server's primary LAN URL — the phone app scans it to connect."""
    from . import netinfo
    info = netinfo.server_info()
    url = info.get("primary")
    if not url:
        raise HTTPException(503, "No Wi-Fi address found — connect this computer to a network.")
    try:
        svg = netinfo.qr_svg(url)
    except ImportError:
        raise HTTPException(503, "QR generation needs the 'qrcode' package (pip install qrcode).")
    return Response(svg, media_type="image/svg+xml", headers={"Cache-Control": "no-store"})


@app.get("/api/books/{book_id}/manifest")
def api_manifest(book_id: str):
    m = library.get_manifest(book_id)
    if not m:
        raise HTTPException(404, "Book not found")
    return m


@app.delete("/api/books/{book_id}")
def api_delete(book_id: str):
    import shutil
    book_dir = config.BOOKS_DIR / book_id
    if not book_dir.exists():
        raise HTTPException(404, "Book not found")
    shutil.rmtree(book_dir)
    return {"ok": True}


@app.get("/api/books/{book_id}/package")
def api_package(book_id: str):
    """Bundle a ready book into a .abk (zip) and stream it to the phone app.

    Built into a temp dir and cleaned up after the response (FileResponse supports Range,
    so large downloads are resumable)."""
    import shutil
    import tempfile
    from . import export

    if not (config.BOOKS_DIR / book_id).exists():
        raise HTTPException(404, "Book not found")
    tmpdir = Path(tempfile.mkdtemp(prefix="abk_"))
    try:
        path = export.package_book(book_id, out_dir=tmpdir)
    except ValueError as e:           # not "ready" yet
        shutil.rmtree(tmpdir, ignore_errors=True)
        raise HTTPException(409, str(e))
    except FileNotFoundError as e:    # missing book or audio file
        shutil.rmtree(tmpdir, ignore_errors=True)
        raise HTTPException(404, str(e))
    except Exception as e:
        shutil.rmtree(tmpdir, ignore_errors=True)
        raise HTTPException(500, f"Packaging failed: {e}")
    return FileResponse(
        path, media_type="application/zip", filename=f"{book_id}.abk",
        background=BackgroundTask(shutil.rmtree, tmpdir, True),  # (path, ignore_errors)
    )


def _manifest_or_404(book_id: str) -> dict:
    m = library.get_manifest(book_id)
    if not m:
        raise HTTPException(404, "Book not found")
    return m


def _subtitle_response(book_id: str, ci: Optional[int], ext: str):
    """Serve .srt/.vtt for one chapter (times relative to its audio) or the whole book."""
    ext = ext.lower()
    if ext not in ("srt", "vtt"):
        raise HTTPException(404, "Subtitles are available as .srt or .vtt")
    m = _manifest_or_404(book_id)
    from . import subtitles
    chapters = m.get("chapters", [])
    if ci is not None:
        if ci < 0 or ci >= len(chapters):
            raise HTTPException(404, "Chapter not found")
        if chapters[ci].get("status", "ready") != "ready":
            raise HTTPException(409, "That chapter isn't ready yet")
        cues = subtitles.build_cues(m, chapter_index=ci)
        stem = f"{book_id}-ch{ci + 1:02d}"
    else:
        cues = subtitles.build_cues(m)
        stem = book_id
    if not cues:
        raise HTTPException(409, "No timed text available yet")
    body = subtitles.to_vtt(cues) if ext == "vtt" else subtitles.to_srt(cues)
    media = "text/vtt" if ext == "vtt" else "application/x-subrip"
    return Response(body, media_type=f"{media}; charset=utf-8",
                    headers={"Content-Disposition": f'attachment; filename="{stem}.{ext}"'})


@app.get("/api/books/{book_id}/transcript.txt")
def api_transcript(book_id: str):
    from . import subtitles
    body = subtitles.to_transcript(_manifest_or_404(book_id))
    return Response(body, media_type="text/plain; charset=utf-8",
                    headers={"Content-Disposition": f'attachment; filename="{book_id}.txt"'})


@app.get("/api/books/{book_id}/subtitles.{ext}")
def api_subtitles_book(book_id: str, ext: str):
    return _subtitle_response(book_id, None, ext)


@app.get("/api/books/{book_id}/chapter/{ci}/subtitles.{ext}")
def api_subtitles_chapter(book_id: str, ci: int, ext: str):
    return _subtitle_response(book_id, ci, ext)


# --------------------------------------------------------------------- reading notes
# Notes live in a sibling notes.json (see app/notes.py) — never in the manifest. CRUD +
# Markdown/Obsidian export (mirrors the transcript/subtitles endpoints) + a merge-sync
# primitive the mobile app uses over the LAN.
@app.get("/api/books/{book_id}/notes")
def api_notes_list(book_id: str):
    _manifest_or_404(book_id)
    from . import notes
    return {"notes": notes.list_notes(book_id)}


@app.post("/api/books/{book_id}/notes", status_code=201)
def api_notes_create(book_id: str, payload: dict = Body(...)):
    m = _manifest_or_404(book_id)
    from . import notes
    try:
        return notes.create_note(book_id, payload, manifest=m)
    except notes.NoteError as e:
        raise HTTPException(400, str(e))


@app.post("/api/books/{book_id}/notes/sync")
def api_notes_sync(book_id: str, payload: dict = Body(...)):
    _manifest_or_404(book_id)
    from . import notes
    incoming = payload.get("notes") if isinstance(payload, dict) else None
    if not isinstance(incoming, list):
        raise HTTPException(400, "Expected a JSON object with a 'notes' list")
    return {"notes": notes.merge_notes(book_id, incoming)}


@app.patch("/api/books/{book_id}/notes/{note_id}")
def api_notes_update(book_id: str, note_id: str, payload: dict = Body(...)):
    _manifest_or_404(book_id)
    from . import notes
    try:
        n = notes.update_note(book_id, note_id, payload)
    except notes.NoteError as e:
        raise HTTPException(400, str(e))
    if n is None:
        raise HTTPException(404, "Note not found")
    return n


@app.delete("/api/books/{book_id}/notes/{note_id}")
def api_notes_delete(book_id: str, note_id: str):
    _manifest_or_404(book_id)
    from . import notes
    if not notes.delete_note(book_id, note_id):
        raise HTTPException(404, "Note not found")
    return {"ok": True}


@app.get("/api/books/{book_id}/notes.md")
def api_notes_md(book_id: str, flavor: str = "plain"):
    m = _manifest_or_404(book_id)
    from . import notes
    ns = notes.list_notes(book_id)
    if flavor == "obsidian":
        body, suffix = notes.to_obsidian(m, ns), "-obsidian"
    else:
        body, suffix = notes.to_markdown(m, ns), ""
    return Response(body, media_type="text/markdown; charset=utf-8",
                    headers={"Content-Disposition":
                             f'attachment; filename="{book_id}-notes{suffix}.md"'})


@app.get("/api/books/{book_id}/feed.xml")
def api_feed(book_id: str, request: Request):
    """Podcast RSS feed (chapters = serial episodes) — subscribe in any podcast app."""
    m = _manifest_or_404(book_id)
    from . import feed
    xml = feed.build_feed(m, str(request.base_url), book_id)
    return Response(xml, media_type="application/rss+xml; charset=utf-8")


@app.get("/api/books/{book_id}/cover.png")
def api_cover(book_id: str):
    from . import feed
    return Response(feed.cover_png(_manifest_or_404(book_id)), media_type="image/png")


# --------------------------------------------------------------- notes narration (TTS)
# A lightweight text->speech endpoint for the Obsidian note-narrator plugin: cleaned text in,
# audio + per-sentence timings out (the same {i,t,s,e,cs,ce,p} shape as a chapter's
# sentences[]). It reuses the ingest per-sentence render path via a one-off Chapter, so the
# synth/silence/timing math is byte-identical to book generation — no book/chapter/manifest
# machinery. Results are cached by a content hash under config.TTS_CACHE_DIR and the audio is
# served (with HTTP Range, so seeking works) at /tts-media, so re-narrating an unchanged note
# is instant.
def _tts_key(text: str, engine: str, voice: str, lang: str, speed: float, fmt: str) -> str:
    payload = "\x1f".join([text, engine, voice, lang, f"{float(speed):.3f}", fmt])
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()[:16]


# In-memory registry of running narration jobs, keyed by the content hash. Because the key is a
# pure function of (text, engine, voice, …), re-POSTing the same note dedups onto the same job
# instead of starting a second synthesis. Jobs are memory-only; the finished audio + timings are
# durable on disk (TTS_CACHE_DIR), so after a restart the next POST either serves the disk cache
# instantly (finished) or re-synthesizes (was mid-flight). Shape mirrors an ingest job's genstate:
# {status, stage, done, total, message, result?} so the plugin renders a real progress bar.
_tts_jobs: Dict[str, dict] = {}
_tts_lock = threading.Lock()


def _tts_disk_result(key: str) -> Optional[dict]:
    """The finished narration for `key` if it's already cached on disk (audio + meta), else None."""
    meta_path = config.TTS_CACHE_DIR / f"{key}.json"
    if not meta_path.exists():
        return None
    try:
        cached = json.loads(meta_path.read_text(encoding="utf-8"))
    except Exception:
        return None  # corrupt/partial cache entry → treat as absent, re-synthesize
    if cached.get("audio") and (config.TTS_CACHE_DIR / cached["audio"]).exists():
        cached["cached"] = True
        return cached
    return None


def _tts_done_state(key: str, result: dict) -> dict:
    n = len(result.get("sentences", []))
    return {"key": key, "status": "done", "stage": "done", "message": "Ready",
            "done": n, "total": n, "cached": bool(result.get("cached")), "result": result}


def _tts_run(key: str, text: str, engine: str, voice: str, lang: str,
             speed: float, fmt: str, device: str, ephemeral: bool = False) -> None:
    """Background synthesis worker: loads the engine, renders per sentence (bumping the job's
    `done` counter through _render_chapter's on_sentence hook so the client sees live progress),
    encodes, then caches the result to disk. Failures land on the job so the poller surfaces them."""
    job = _tts_jobs[key]
    try:
        job["stage"] = "model"
        job["message"] = "Loading the voice model…"
        engine_obj = _get_engine(engine, voice, lang, speed, device)
        sr = engine_obj.sample_rate
        job["stage"] = "synth"
        job["message"] = "Synthesizing narration…"
        ch = Chapter(index=0, title="", level=1, text=text, start=0, end=len(text), page=0)

        def on_sentence() -> None:
            job["done"] += 1

        pcm, timings, _topics = _render_chapter(
            engine_obj, ch, sr, on_sentence=on_sentence, pron_rules=pronounce.load_rules())
        job["stage"] = "encode"
        job["message"] = "Encoding audio…"
        out_dir, url_base = ((_QUICK_DIR, "/quick-media") if ephemeral
                             else (config.TTS_CACHE_DIR, "/tts-media"))
        out_path = audiomod.write_audio(pcm, out_dir / key, sr=sr, fmt=fmt)
        result = {
            "key": key, "audio": out_path.name, "audio_url": f"{url_base}/{out_path.name}",
            "format": out_path.suffix.lstrip("."), "sample_rate": sr,
            "duration": round(audiomod.duration_seconds(pcm, sr), 3),
            "engine": engine, "voice": voice, "lang": lang, "speed": speed,
            "sentences": timings, "cached": False,
        }
        if not ephemeral:                           # pasted text is never persisted
            (config.TTS_CACHE_DIR / f"{key}.json").write_text(
                json.dumps(result, ensure_ascii=False), encoding="utf-8")
        job["done"] = len(timings)
        job["total"] = len(timings)
        job["result"] = result
        job["stage"] = "done"
        job["message"] = "Ready"
        job["status"] = "done"
    except Exception as e:                          # keep the failure visible to the poller
        traceback.print_exc()
        job["status"] = "error"
        job["error"] = str(e)
        job["message"] = f"Narration failed: {e}"


@app.post("/api/tts")
def api_tts(payload: dict = Body(...)):
    """Start (or rejoin) a narration job for `text` and return its live status. The synthesis
    runs on a background thread; the client polls GET /api/tts/{key} for progress (per-sentence
    `done`/`total`) and the final `result`. Already-cached content returns done immediately."""
    text = (payload.get("text") or "").strip()
    if not text:
        raise HTTPException(400, "Provide non-empty 'text' to narrate")
    engine = (payload.get("engine") or config.DEFAULT_ENGINE).lower()
    default_voice = config.VOXTRAL_VOICE if engine == "voxtral" else config.DEFAULT_VOICE
    voice = payload.get("voice") or default_voice
    lang = payload.get("lang") or config.DEFAULT_LANG
    raw_speed = payload.get("speed")
    speed = float(raw_speed if raw_speed is not None else config.DEFAULT_SPEED)
    fmt = (payload.get("format") or config.AUDIO_FORMAT).lower()
    device = payload.get("device") or config.KOKORO_DEVICE
    key = payload.get("key") or _tts_key(text, engine, voice, lang, speed, fmt)
    config.TTS_CACHE_DIR.mkdir(parents=True, exist_ok=True)

    cached = _tts_disk_result(key)
    if cached is not None:                          # synthesized in a prior run → instant
        return _tts_done_state(key, cached)

    with _tts_lock:
        job = _tts_jobs.get(key)
        if job is None or job["status"] == "error":  # start fresh (or retry a failed one)
            try:
                from . import textproc
                total = len(textproc.split_sentences(text))
            except Exception:
                total = 0
            job = {"key": key, "status": "running", "stage": "model",
                   "message": "Starting…", "done": 0, "total": total,
                   "result": None, "error": None}
            _tts_jobs[key] = job
            threading.Thread(target=_tts_run,
                             args=(key, text, engine, voice, lang, speed, fmt, device),
                             daemon=True).start()
    return job


@app.post("/api/quick")
def api_quick(payload: dict = Body(...)):
    """Narrate pasted text without saving it: same synthesis as /api/tts, but audio goes to the
    per-run temp dir, nothing is hash-cached on disk, and the key is random (no dedupe).
    Poll GET /api/tts/{key}; discard with POST /api/quick/{key}/discard."""
    text = (payload.get("text") or "").strip()
    if not text:
        raise HTTPException(400, "Paste some text to listen to")
    engine = (payload.get("engine") or config.DEFAULT_ENGINE).lower()
    default_voice = config.VOXTRAL_VOICE if engine == "voxtral" else config.DEFAULT_VOICE
    voice = payload.get("voice") or default_voice
    raw_speed = payload.get("speed")
    speed = float(raw_speed if raw_speed is not None else config.DEFAULT_SPEED)
    key = "q-" + uuid.uuid4().hex[:12]
    try:
        from . import textproc
        total = len(textproc.split_sentences(text))
    except Exception:
        total = 0
    job = {"key": key, "status": "running", "stage": "model", "message": "Starting…",
           "done": 0, "total": total, "result": None, "error": None}
    _tts_jobs[key] = job
    threading.Thread(target=_tts_run,
                     args=(key, text, engine, voice, config.DEFAULT_LANG, speed,
                           config.AUDIO_FORMAT, config.KOKORO_DEVICE, True),
                     daemon=True).start()
    return job


@app.post("/api/quick/{key}/discard")
def api_quick_discard(key: str):
    """Forget a pasted-text narration and delete its audio. POST (not DELETE) so the browser
    can fire it from sendBeacon/keepalive on tab close."""
    if not key.startswith("q-") or "/" in key or ".." in key:
        raise HTTPException(400, "not a quick narration key")
    _tts_jobs.pop(key, None)
    for f in _QUICK_DIR.glob(f"{key}.*"):
        f.unlink(missing_ok=True)
    return {"ok": True}


@app.get("/api/tts/{key}")
def api_tts_status(key: str):
    """Poll a narration job: {status, stage, done, total, message, result?}."""
    job = _tts_jobs.get(key)
    if job is not None:
        return job
    cached = _tts_disk_result(key)                  # finished in a previous server run
    if cached is not None:
        return _tts_done_state(key, cached)
    raise HTTPException(404, "no such narration job")


def _run_job(job_id: str, pdf_path: Path, opts: dict, resume: bool, control: JobControl):
    job = _jobs[job_id]
    try:
        def progress(ev: dict):
            upd = {"stage": ev["stage"], "message": ev.get("message", "")}
            if ev.get("total"):
                upd["percent"] = int(ev["done"] * 100 / ev["total"])
            for k in ("book_id", "chapters_ready", "chapters_total"):
                if ev.get(k) is not None:
                    upd[k] = ev[k]
            if ev.get("book_id"):
                _book_jobs[ev["book_id"]] = job_id
            job.update(upd)  # never sets "status" — that's owned by the control endpoints

        engine = _get_engine(opts["engine"], opts["voice"], opts["lang"],
                             opts["speed"], opts["device"])
        progress({"stage": "model", "message": "Engine ready"})
        m = ingest_pdf(pdf_path, engine=engine, voice=opts["voice"], lang=opts["lang"],
                       speed=opts["speed"], audio_format=opts["format"],
                       overwrite=not resume, resume=resume, progress=progress, control=control)
        if control.is_cancelled():
            job.update(status="cancelled", book_id=m["id"], message="Cancelled",
                       chapters_ready=m["chapters_ready"], chapters_total=m["chapters_total"])
        else:
            job.update(status="done", book_id=m["id"], title=m["title"],
                       chapters_ready=m["chapters_ready"], chapters_total=m["chapters_total"],
                       message="Complete", percent=100)
    except Exception as e:
        job.update(status="error", message=f"{type(e).__name__}: {e}",
                   traceback=traceback.format_exc())


def _spawn_job(pdf_path: Path, opts: dict, resume: bool = False) -> str:
    job_id = uuid.uuid4().hex[:12]
    control = JobControl()
    _controls[job_id] = control
    _jobs[job_id] = {"id": job_id, "status": "running", "stage": "queued",
                     "percent": 0, "message": "Queued", "filename": Path(pdf_path).name}
    threading.Thread(target=_run_job, args=(job_id, Path(pdf_path), opts, resume, control),
                     daemon=True).start()
    return job_id


def _active_job_id(book_id: str):
    jid = _book_jobs.get(book_id)
    job = _jobs.get(jid) if jid else None
    if job and job.get("status") in ("running", "paused", "cancelling"):
        return jid
    return None


@app.post("/api/ingest")
async def api_ingest(
    file: UploadFile = File(...),
    engine: str = Form(config.DEFAULT_ENGINE),
    voice: str = Form(config.DEFAULT_VOICE),
    lang: str = Form(config.DEFAULT_LANG),
    speed: float = Form(config.DEFAULT_SPEED),
    device: str = Form(config.KOKORO_DEVICE),
    format: str = Form(config.AUDIO_FORMAT),
):
    if not file.filename.lower().endswith(SUPPORTED_EXTS):
        raise HTTPException(400, "Please upload a PDF or EPUB file")
    dest = config.INBOX_DIR / Path(file.filename).name
    dest.write_bytes(await file.read())
    opts = {"engine": engine, "voice": voice, "lang": lang,
            "speed": speed, "device": device, "format": format}
    return {"job_id": _spawn_job(dest, opts, resume=False)}


@app.get("/api/jobs/{job_id}")
def api_job(job_id: str):
    job = _jobs.get(job_id)
    if not job:
        raise HTTPException(404, "Job not found")
    return job


# ----------------------------------------------------- generation controls
@app.get("/api/books/{book_id}/genstate")
def api_genstate(book_id: str):
    """Lightweight status the player polls: progress + pause/active flags."""
    m = library.get_manifest(book_id)
    if not m:
        raise HTTPException(404, "Book not found")
    jid = _active_job_id(book_id)
    job = _jobs.get(jid) if jid else None
    status = job.get("status") if job else None
    chapters = m.get("chapters", [])
    return {
        "manifest_status": m.get("status", "ready"),
        "chapters_ready": m.get("chapters_ready",
                                sum(1 for c in chapters if c.get("status", "ready") == "ready")),
        "chapters_total": m.get("chapters_total", len(chapters)),
        "active": bool(job),
        "paused": status == "paused",
        "cancelling": status == "cancelling",
        "message": (job or {}).get("message", ""),
        "job_id": jid,
        "has_source": bool(m.get("source_pdf") and (config.INBOX_DIR / m["source_pdf"]).exists()),
    }


@app.post("/api/books/{book_id}/pause")
def api_pause(book_id: str):
    jid = _active_job_id(book_id)
    job = _jobs.get(jid) if jid else None
    if not (job and job.get("status") == "running"):
        raise HTTPException(409, "No active generation to pause")
    _controls[jid].pause()
    job.update(status="paused", message="Paused")
    return {"ok": True, "status": "paused"}


@app.post("/api/books/{book_id}/resume")
def api_resume(book_id: str):
    jid = _active_job_id(book_id)
    job = _jobs.get(jid) if jid else None
    if job and job.get("status") == "paused":
        _controls[jid].resume()
        job.update(status="running", message="Resumed")
        return {"ok": True, "status": "running", "job_id": jid}
    if job and job.get("status") in ("running", "cancelling"):
        return {"ok": True, "status": job["status"], "job_id": jid}
    return _start_resume_job(book_id)  # no live job — start a fresh resuming run


@app.post("/api/books/{book_id}/cancel")
def api_cancel(book_id: str):
    jid = _active_job_id(book_id)
    job = _jobs.get(jid) if jid else None
    if job and job.get("status") in ("running", "paused"):
        _controls[jid].cancel()
        job.update(status="cancelling", message="Cancelling…")
        return {"ok": True, "status": "cancelling"}
    # No live job: mark a stuck/in-progress manifest as cancelled.
    m = library.get_manifest(book_id)
    if not m:
        raise HTTPException(404, "Book not found")
    if m.get("status") == "generating":
        m["status"] = "cancelled"
        _write_manifest_atomic(config.BOOKS_DIR / book_id, m)
    return {"ok": True, "status": m.get("status")}


def _start_resume_job(book_id: str):
    m = library.get_manifest(book_id)
    if not m:
        raise HTTPException(404, "Book not found")
    fname = m.get("source_pdf", "")
    src = config.INBOX_DIR / fname
    if not fname or not src.exists():
        raise HTTPException(409, f"Original file '{fname}' isn't in the inbox; "
                                 "re-add it, or resume from the CLI with --resume.")
    opts = {"engine": m.get("engine") or config.DEFAULT_ENGINE,
            "voice": m.get("voice") or config.DEFAULT_VOICE,
            "lang": m.get("lang") or config.DEFAULT_LANG,
            "speed": m.get("speed") if m.get("speed") is not None else config.DEFAULT_SPEED,
            "device": config.KOKORO_DEVICE,
            "format": m.get("audio_format") or config.AUDIO_FORMAT}
    return {"ok": True, "status": "running", "job_id": _spawn_job(src, opts, resume=True)}


# --------------------------------------------------------------- static mounts
class _NoCacheStaticFiles(StaticFiles):
    """Serve static files with revalidation instead of heuristic caching. There's no build
    step and files change *in place*: UI assets (app.js/styles.css) on every edit, chapter
    MP3s on re-encode (scripts/reencode_cbr.py) or regeneration. Without a Cache-Control
    header, browsers cache "heuristically" (~10% of the file's age — days, for an older
    book) and reuse stale bytes without ever asking the server — for audio that silently
    desyncs seeking from the fresh manifest timings, and not even a hard reload reliably
    evicts media fetched later by a click. ``no-cache`` keeps the cached copy but
    revalidates each use (a cheap local 304 via ETag); HTTP-Range seeking is unaffected."""

    async def get_response(self, path, scope):
        response = await super().get_response(path, scope)
        response.headers["Cache-Control"] = "no-cache"
        return response


# Audio + manifests (StaticFiles supports HTTP Range, so seeking works; no-cache so a
# re-encoded/regenerated chapter MP3 is never played from a stale browser cache).
app.mount("/media", _NoCacheStaticFiles(directory=str(config.BOOKS_DIR)), name="media")
# Cached notes-narration audio for the /api/tts endpoint (also Range-capable → seeking).
app.mount("/tts-media", _NoCacheStaticFiles(directory=str(config.TTS_CACHE_DIR)), name="tts-media")
# Throwaway pasted-text audio (see _QUICK_DIR) — never in the library.
app.mount("/quick-media", _NoCacheStaticFiles(directory=str(_QUICK_DIR)), name="quick-media")
# Frontend (index.html at "/") — no-cache so UI edits show up on a normal reload.
app.mount("/", _NoCacheStaticFiles(directory=str(config.WEB_DIR), html=True), name="web")
