"""Turn a PDF into a navigable audiobook: audio files + manifest.json.

Run as a module:
    python -m app.ingest path/to/book.pdf --engine kokoro --voice af_heart
    python -m app.ingest            # processes every PDF in library/inbox/
"""
from __future__ import annotations

import argparse
import datetime as _dt
import json
import os
import shutil
import sys
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, List, Optional

from . import audio as audiomod
from . import config, extract as book_extract, pronounce, textproc
from .extract import BookDoc, Marker
from .tts import make_engine

# Progress is reported as a single event dict, e.g.
#   {"stage": "chapter_done", "done": 12, "total": 40, "message": "...",
#    "book_id": "...", "chapters_ready": 1, "chapters_total": 8, "chapter_index": 0}
ProgressFn = Callable[[dict], None]


class GenerationCancelled(Exception):
    """Raised inside the synth loop to unwind a cancelled generation."""


class JobControl:
    """Pause / resume / cancel signalling for a running generation.

    The ingest loop calls :meth:`checkpoint` between sentences and chapters:
    it blocks while paused and raises :class:`GenerationCancelled` when cancelled.
    """

    def __init__(self):
        self._pause = threading.Event()
        self._cancel = threading.Event()

    def pause(self):
        self._pause.set()

    def resume(self):
        self._pause.clear()

    def cancel(self):
        self._cancel.set()
        self._pause.clear()  # so a paused job can wake up and exit

    def is_paused(self) -> bool:
        return self._pause.is_set()

    def is_cancelled(self) -> bool:
        return self._cancel.is_set()

    def checkpoint(self):
        while self._pause.is_set() and not self._cancel.is_set():
            time.sleep(0.12)
        if self._cancel.is_set():
            raise GenerationCancelled()


@dataclass
class Chapter:
    index: int
    title: str
    level: int
    text: str
    start: int          # offset into linear_text
    end: int
    page: int
    submarkers: List[Marker] = field(default_factory=list)

    @property
    def id(self) -> str:
        return f"ch{self.index:04d}"


# ---------------------------------------------------------------------------
# Segmentation
# ---------------------------------------------------------------------------

def segment_chapters(doc: BookDoc) -> List[Chapter]:
    from . import structure

    text = doc.linear_text
    level1 = [m for m in doc.markers if m.level == 1]

    if len(level1) >= 1:
        chapters = _segment_by_markers(doc, level1)
    else:
        chapters = _segment_fixed(text)

    prof = structure.StructureProfile.from_json(doc.profile) if doc.profile else None

    # Apply the profile (skip non-narratable sections; trim spoken heading labels), drop
    # empty chapters, and renumber.
    out: List[Chapter] = []
    for ch in chapters:
        if prof is not None and structure.should_skip_section(prof, ch.title, ch.page):
            continue
        if prof is not None:
            cut = structure.strip_heading_labels(prof, ch.text, ch.title)
            if 0 < cut < len(ch.text):
                # Trim the label AND advance the chapter's start offset in lockstep so
                # sentence char offsets and topic timings stay aligned downstream.
                ch.text = ch.text[cut:]
                ch.start += cut
        if textproc.word_count(ch.text) == 0:
            continue
        ch.index = len(out)
        out.append(ch)
    return out


def _page_of_offset(doc: BookDoc, offset: int) -> int:
    page = 0
    for i, off in enumerate(doc.page_offsets):
        if off <= offset:
            page = i
        else:
            break
    return page


def _segment_by_markers(doc: BookDoc, level1: List[Marker]) -> List[Chapter]:
    text = doc.linear_text
    starts = [m.offset for m in level1]
    bounds = list(zip(starts, starts[1:] + [len(text)]))

    chapters: List[Chapter] = []
    # Front matter before the first heading.
    if starts[0] >= config.MIN_FRONTMATTER_CHARS:
        chapters.append(Chapter(
            index=0, title="Front Matter", level=1,
            text=text[0:starts[0]], start=0, end=starts[0], page=0,
        ))

    for m, (s, e) in zip(level1, bounds):
        subs = [x for x in doc.markers if x.level >= 2 and s < x.offset < e]
        chapters.append(Chapter(
            index=0, title=m.title, level=1,
            text=text[s:e], start=s, end=e, page=m.page, submarkers=subs,
        ))
    return chapters


def _segment_fixed(text: str) -> List[Chapter]:
    sents = textproc.split_sentences(text)
    if not sents:
        return [Chapter(0, "Full Text", 1, text, 0, len(text), 0)]

    chapters: List[Chapter] = []
    cur_start = sents[0].start
    words = 0
    last_end = sents[0].start
    n = 0
    for s in sents:
        words += textproc.word_count(s.text)
        last_end = s.end
        if words >= config.WORDS_PER_FALLBACK_CHAPTER:
            chapters.append(Chapter(
                index=0, title=f"Section {n + 1}", level=1,
                text=text[cur_start:last_end], start=cur_start, end=last_end, page=0,
            ))
            n += 1
            cur_start = last_end
            words = 0
    if cur_start < len(text.rstrip()):
        chapters.append(Chapter(
            index=0, title=f"Section {n + 1}", level=1,
            text=text[cur_start:], start=cur_start, end=len(text), page=0,
        ))
    return chapters


# ---------------------------------------------------------------------------
# Audio + timing
# ---------------------------------------------------------------------------

def _time_at_char(timings: List[dict], char_off: int) -> float:
    if not timings:
        return 0.0
    best = timings[0]["s"]
    for tm in timings:
        if tm["cs"] <= char_off < tm["ce"]:
            return tm["s"]
        if tm["cs"] <= char_off:
            best = tm["s"]
        else:
            break
    return best


def _render_chapter(engine, ch: Chapter, sr: int,
                    on_sentence: Optional[Callable[[], None]] = None,
                    control: Optional[JobControl] = None,
                    pron_rules: Optional[list] = None):
    sents = textproc.split_sentences(ch.text)
    parts: List = []
    timings: List[dict] = []
    t = 0.0
    for k, sent in enumerate(sents):
        if control is not None:
            control.checkpoint()  # blocks while paused, raises if cancelled
        # Synthesize the spoken form (pronunciation rules applied); the manifest below
        # keeps sent.text — the original words — so highlighting and search still match.
        pcm = engine.synth(pronounce.apply(sent.text, pron_rules))
        dur = audiomod.duration_seconds(pcm, sr)
        start = t
        end = t + dur
        parts.append(pcm)

        between = ch.text[sent.end: sents[k + 1].start] if k + 1 < len(sents) else "\n\n"
        is_para = "\n\n" in between
        gap_ms = config.PARAGRAPH_GAP_MS if is_para else config.SENTENCE_GAP_MS
        parts.append(audiomod.silence(gap_ms, sr))

        entry = {"i": k, "t": sent.text, "s": round(start, 3), "e": round(end, 3),
                 "cs": sent.start, "ce": sent.end}
        if is_para:
            entry["p"] = 1
        timings.append(entry)
        t = end + gap_ms / 1000.0
        if on_sentence:
            on_sentence()

    pcm = audiomod.concat(parts)
    topics = []
    for m in ch.submarkers:
        topics.append({
            "title": m.title, "level": m.level,
            "time": round(_time_at_char(timings, m.offset - ch.start), 3),
        })
    return pcm, timings, topics


# ---------------------------------------------------------------------------
# Top-level ingest
# ---------------------------------------------------------------------------

def _now_iso() -> str:
    return _dt.datetime.now().replace(microsecond=0).isoformat()


def _fmt_mmss(sec: float) -> str:
    m, s = divmod(int(sec), 60)
    return f"{m}:{s:02d}"


def _write_manifest_atomic(book_dir: Path, manifest: dict) -> None:
    """Write manifest.json atomically so the player never reads a half-written file."""
    tmp = book_dir / "manifest.json.tmp"
    tmp.write_text(json.dumps(manifest, ensure_ascii=False, indent=1), encoding="utf-8")
    os.replace(tmp, book_dir / "manifest.json")


def _skeleton(book_id, doc, chapters, eng_info, fmt, sr, voice, lang, speed) -> dict:
    """Full structure, known right after extraction; audio/timings filled in later."""
    return {
        "id": book_id, "title": doc.title, "author": doc.author,
        "source_pdf": "", "created": _now_iso(),
        "engine": eng_info.get("engine"),
        "voice": eng_info.get("voice", voice or config.DEFAULT_VOICE),
        "lang": eng_info.get("lang", lang or config.DEFAULT_LANG),
        "speed": eng_info.get("speed", speed if speed is not None else config.DEFAULT_SPEED),
        "device": eng_info.get("device", ""),
        "sample_rate": sr, "audio_format": fmt, "toc_source": doc.toc_source,
        "structure_source": doc.structure_source,
        "n_pages": doc.n_pages,
        "status": "generating", "chapters_total": len(chapters), "chapters_ready": 0,
        "total_duration": 0.0,
        "chapters": [{
            "id": ch.id, "index": ch.index, "title": ch.title, "level": ch.level,
            "page": ch.page, "status": "pending",
            "audio": None, "duration": 0.0, "start_global": None,
            "topics": [{"title": m.title, "level": m.level, "time": None}
                       for m in ch.submarkers],
            "sentences": [],
        } for ch in chapters],
    }


def ingest_pdf(pdf_path: str | Path, *, engine_name: str = None, voice: str = None,
               lang: str = None, speed: float = None, device: str = None,
               audio_format: str = None, overwrite: bool = True, resume: bool = False,
               progress: Optional[ProgressFn] = None, engine=None,
               control: Optional[JobControl] = None,
               smart_parse: Optional[bool] = None, reprofile: bool = False) -> dict:
    """Generate an audiobook, writing each chapter's audio + manifest as it finishes.

    The manifest (with the full chapter list) is written *before* any audio, so the
    book is visible immediately and the first chapter becomes playable while the
    remaining chapters render in the background. Safe to interrupt and ``resume``.
    """
    config.ensure_dirs()
    pdf_path = Path(pdf_path)
    fmt = (audio_format or config.AUDIO_FORMAT).lower()

    def report(stage, done=0, total=0, message="", **extra):
        if progress:
            ev = {"stage": stage, "done": done, "total": total, "message": message}
            ev.update(extra)
            progress(ev)

    report("extract", message=f"Reading {pdf_path.name}")
    doc = book_extract.extract(pdf_path, smart_parse=smart_parse, reprofile=reprofile)
    if doc.structure_source == "llm":
        report("extract", message="Structure profiled by LLM")
    chapters = segment_chapters(doc)
    if not chapters:
        raise RuntimeError("No readable text found in PDF.")

    book_id = textproc.slugify(doc.title or pdf_path.stem)
    book_dir = config.BOOKS_DIR / book_id
    mf_path = book_dir / "manifest.json"

    # Resume an interrupted run when the structure still matches; otherwise (re)create.
    existing = None
    if book_dir.exists() and resume and mf_path.exists():
        try:
            cand = json.loads(mf_path.read_text(encoding="utf-8"))
            if len(cand.get("chapters", [])) == len(chapters):
                existing = cand
        except Exception:
            existing = None
    if existing is None and book_dir.exists():
        if overwrite:
            shutil.rmtree(book_dir)
        else:
            raise FileExistsError(f"Book '{book_id}' already exists (use --overwrite or --resume).")
    book_dir.mkdir(parents=True, exist_ok=True)
    if doc.profile:  # a readable copy of the applied structure profile, for inspection/editing
        try:
            (book_dir / "structure.json").write_text(
                json.dumps(doc.profile, ensure_ascii=False, indent=1), encoding="utf-8")
        except OSError:
            pass

    if engine is None:
        report("model", message=f"Loading {engine_name or config.DEFAULT_ENGINE} engine")
        engine = make_engine(engine=engine_name, voice=voice, lang=lang,
                             speed=speed, device=device)
    sr = engine.sample_rate
    eng_info = engine.info()

    if existing:
        manifest = existing
        manifest["status"] = "generating"
    else:
        manifest = _skeleton(book_id, doc, chapters, eng_info, fmt, sr, voice, lang, speed)
    manifest["source_pdf"] = pdf_path.name
    manifest["structure_source"] = doc.structure_source
    pron_rules = pronounce.load_rules()
    manifest["pronunciation_rules"] = len(pron_rules)
    _write_manifest_atomic(book_dir, manifest)
    if pron_rules:
        report("model", message=f"Pronunciation dictionary: {len(pron_rules)} rule(s) loaded")

    total_sents = sum(len(textproc.split_sentences(ch.text)) for ch in chapters)

    # Account for any already-finished chapters (resume); reset the rest to pending.
    running = 0.0
    ready_count = 0
    done_sents = 0
    for centry in manifest["chapters"]:
        if centry["status"] == "ready" and centry.get("audio") and (book_dir / centry["audio"]).exists():
            running += centry.get("duration", 0.0)
            ready_count += 1
            done_sents += len(centry["sentences"])
        else:
            centry["status"] = "pending"
    manifest["chapters_ready"] = ready_count
    manifest["total_duration"] = round(running, 3)

    report("prepared", done_sents, total_sents,
           message=f"{len(chapters)} chapters · {total_sents} sentences",
           book_id=book_id, chapters_total=len(chapters), chapters_ready=ready_count)

    cancelled = False
    try:
        for ci, ch in enumerate(chapters):
            centry = manifest["chapters"][ci]
            if centry["status"] == "ready":
                continue  # already done (resume)
            if control is not None:
                control.checkpoint()  # honor pause/cancel between chapters too

            def _tick(_ci=ci, _ch=ch, _rc=ready_count):
                nonlocal done_sents
                done_sents += 1
                report("synthesize", done_sents, total_sents,
                       message=f"Ch {_ci + 1}/{len(chapters)}: {_ch.title[:40]}",
                       book_id=book_id, chapters_total=len(chapters), chapters_ready=_rc)

            try:
                pcm, timings, topics = _render_chapter(engine, ch, sr,
                                                       on_sentence=_tick, control=control,
                                                       pron_rules=pron_rules)
                out_path = audiomod.write_audio(pcm, book_dir / ch.id, sr=sr, fmt=fmt)
            except GenerationCancelled:
                raise
            except Exception as e:
                centry["status"] = "error"
                centry["error"] = f"{type(e).__name__}: {e}"
                _write_manifest_atomic(book_dir, manifest)
                report("chapter_error", done_sents, total_sents,
                       message=f"Chapter {ci + 1} failed: {e}", book_id=book_id,
                       chapters_total=len(chapters), chapters_ready=ready_count)
                continue

            dur = audiomod.duration_seconds(pcm, sr)
            centry.update(status="ready", audio=out_path.name, duration=round(dur, 3),
                          start_global=round(running, 3), sentences=timings, topics=topics)
            running += dur
            ready_count += 1
            manifest["chapters_ready"] = ready_count
            manifest["total_duration"] = round(running, 3)
            manifest["audio_format"] = out_path.suffix.lstrip(".")
            _write_manifest_atomic(book_dir, manifest)
            report("chapter_done", done_sents, total_sents,
                   message=f"Chapter {ci + 1}/{len(chapters)} ready ({_fmt_mmss(dur)})",
                   book_id=book_id, chapters_total=len(chapters),
                   chapters_ready=ready_count, chapter_index=ci)
    except (GenerationCancelled, KeyboardInterrupt):
        cancelled = True

    if cancelled:
        manifest["status"] = "cancelled"
    else:
        all_ready = all(c["status"] == "ready" for c in manifest["chapters"])
        manifest["status"] = "ready" if all_ready else "partial"
    _write_manifest_atomic(book_dir, manifest)
    report("cancelled" if cancelled else "done", done_sents, total_sents,
           message="Generation cancelled" if cancelled else f"Saved to {book_dir}",
           book_id=book_id, chapters_total=len(chapters), chapters_ready=ready_count)
    return manifest


def _cli_progress(ev: dict) -> None:
    stage = ev["stage"]
    msg = ev.get("message", "")
    if stage == "synthesize" and ev.get("total"):
        pct = int(ev["done"] * 100 / ev["total"])
        bar = ("#" * (pct // 4)).ljust(25)
        sys.stdout.write(f"\r  [{bar}] {pct:3d}%  {msg[:46]:<46}")
        sys.stdout.flush()
    elif stage == "chapter_done":
        sys.stdout.write(f"\r  ✓ {msg:<60}\n")
        sys.stdout.flush()
    elif stage == "chapter_error":
        sys.stdout.write(f"\r  ✗ {msg:<60}\n")
        sys.stdout.flush()
    elif stage in ("extract", "model", "prepared", "done", "cancelled"):
        sys.stdout.write(f"  · {msg}\n")


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description="Ingest a PDF into a narrated audiobook.")
    p.add_argument("pdf", nargs="?",
                   help="PDF or EPUB file (default: every PDF/EPUB in library/inbox/)")
    p.add_argument("--engine", default=config.DEFAULT_ENGINE, choices=["kokoro", "voxtral", "dummy"])
    p.add_argument("--voice", default=config.DEFAULT_VOICE)
    p.add_argument("--lang", default=config.DEFAULT_LANG)
    p.add_argument("--speed", type=float, default=config.DEFAULT_SPEED)
    p.add_argument("--device", default=config.KOKORO_DEVICE, choices=["auto", "mps", "cpu"])
    p.add_argument("--format", dest="fmt", default=config.AUDIO_FORMAT, choices=["mp3", "wav"])
    p.add_argument("--no-overwrite", action="store_true")
    p.add_argument("--resume", action="store_true",
                   help="resume an interrupted book (skip chapters already generated)")
    p.add_argument("--smart-parse", dest="smart_parse", action="store_true", default=None,
                   help="use the LLM structure profiler (overrides STRUCTURE_LLM)")
    p.add_argument("--no-smart-parse", dest="smart_parse", action="store_false",
                   help="disable the LLM structure profiler for this run")
    p.add_argument("--reprofile", action="store_true",
                   help="ignore any cached structure profile and re-run the model")
    args = p.parse_args(argv)

    if args.pdf:
        pdfs = [Path(args.pdf)]
    else:
        config.ensure_dirs()
        pdfs = sorted([p for p in config.INBOX_DIR.iterdir()
                       if p.suffix.lower() in book_extract.SUPPORTED_EXTS])
        if not pdfs:
            print(f"No PDFs/EPUBs found in {config.INBOX_DIR}. Pass a path or drop files there.")
            return 1

    engine = None  # reuse a single loaded model across multiple PDFs
    for pdf in pdfs:
        if not pdf.exists():
            print(f"Not found: {pdf}")
            continue
        print(f"\n► {pdf.name}")
        if engine is None:
            engine = make_engine(engine=args.engine, voice=args.voice, lang=args.lang,
                                 speed=args.speed, device=args.device)
        m = ingest_pdf(pdf, engine=engine, voice=args.voice, lang=args.lang,
                       speed=args.speed, audio_format=args.fmt,
                       overwrite=not args.no_overwrite, resume=args.resume,
                       progress=_cli_progress,
                       smart_parse=args.smart_parse, reprofile=args.reprofile)
        mins = m["total_duration"] / 60
        print(f"  ✓ {m['title']} — {m['chapters_ready']}/{m['chapters_total']} chapters, "
              f"{mins:.1f} min ({m['status']})  (id: {m['id']})")
        if m.get("status") == "cancelled":
            print("  (stopped — resume later with:  ./scripts/ingest.sh <file> --resume)")
            break
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
