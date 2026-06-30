"""FastAPI app: serves the player, the library API, audio, and ingest jobs."""
from __future__ import annotations

import threading
import traceback
import uuid
from pathlib import Path
from typing import Dict, Optional

from fastapi import FastAPI, HTTPException, UploadFile, File, Form
from fastapi.responses import JSONResponse
from fastapi.staticfiles import StaticFiles

from . import config, library
from .extract import SUPPORTED_EXTS
from .ingest import ingest_pdf, JobControl, _write_manifest_atomic

config.ensure_dirs()
app = FastAPI(title="Audiobook Reader")

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


@app.get("/api/voices")
def api_voices():
    return {"voices": VOICES, "default": config.DEFAULT_VOICE}


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
# Audio + manifests (StaticFiles supports HTTP Range, so seeking works).
app.mount("/media", StaticFiles(directory=str(config.BOOKS_DIR)), name="media")
# Frontend (index.html at "/").
app.mount("/", StaticFiles(directory=str(config.WEB_DIR), html=True), name="web")
