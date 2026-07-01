"""Reading notes / annotations: per-book storage + Markdown/Obsidian export.

Notes live in a sibling ``notes.json`` next to each book's ``manifest.json`` — never inside
the manifest, which the ingest pipeline rewrites after every chapter and on ``--resume``.
One record type with an optional body: a *highlight* is just a note with an empty body. Each
note anchors to a **sentence range** ``[si..sj]`` in a chapter and carries a durable text
quote (``exact`` plus ``prefix``/``suffix`` context, Hypothesis-style) so it survives
re-narration/re-segmentation, alongside fast-path hints (sentence indices, char offsets,
audio seconds) copied straight from the manifest.

The exporters are pure transforms over ``(manifest, notes)`` — same shape as
``subtitles.to_transcript`` — so they never read audio or touch the network. Storage mirrors
``ingest._write_manifest_atomic``: a temp file + ``os.replace`` so a reader never sees a
half-written file.
"""
from __future__ import annotations

import datetime as _dt
import json
import os
import re
import threading
import uuid
from itertools import groupby
from pathlib import Path
from typing import List, Optional

from . import config

VERSION = 1
COLORS = ("yellow", "green", "blue", "pink", "purple")
KINDS = ("highlight", "note")
DEFAULT_COLOR = "yellow"

# Defensive field caps — a note body/quote/tag can't grow unbounded on disk.
MAX_NOTE = 10_000
MAX_EXACT = 2_000
MAX_CTX = 64
MAX_TAGS = 20
MAX_TAG = 40

# Guards every read-modify-write of notes.json. The server touches it from request workers,
# background ingest threads and a BackgroundTask, so concurrent writes are real (single
# process). This makes those atomic; it is not cross-process locking.
_lock = threading.Lock()


class NoteError(ValueError):
    """Invalid note payload — the server maps this to HTTP 400."""


# --------------------------------------------------------------------------- storage
def _now_iso() -> str:
    """UTC, second precision, ``Z`` suffix (W3C annotation style; sorts lexicographically)."""
    return (_dt.datetime.now(_dt.timezone.utc).replace(microsecond=0)
            .isoformat().replace("+00:00", "Z"))


def notes_path(book_id: str) -> Path:
    return config.BOOKS_DIR / book_id / "notes.json"


def _empty_doc(book_id: str) -> dict:
    return {"book": book_id, "version": VERSION, "notes": []}


def load_doc(book_id: str) -> dict:
    """Read the notes doc fresh; tolerate a missing or corrupt file (never raises)."""
    p = notes_path(book_id)
    if not p.exists():
        return _empty_doc(book_id)
    try:
        data = json.loads(p.read_text(encoding="utf-8"))
        if not isinstance(data, dict) or not isinstance(data.get("notes"), list):
            return _empty_doc(book_id)
        data.setdefault("book", book_id)
        data.setdefault("version", VERSION)
        return data
    except Exception:
        return _empty_doc(book_id)


def _write_atomic(book_id: str, doc: dict) -> None:
    p = notes_path(book_id)
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_name(p.name + ".tmp")
    tmp.write_text(json.dumps(doc, ensure_ascii=False, indent=1), encoding="utf-8")
    os.replace(tmp, p)


def _reading_key(n: dict):
    return (n.get("ch", 0), n.get("si", 0), n.get("cs", 0), n.get("created", ""))


def list_notes(book_id: str) -> List[dict]:
    """All notes for a book in reading order (chapter, then sentence)."""
    return sorted(load_doc(book_id).get("notes", []), key=_reading_key)


# ------------------------------------------------------------------------- validation
def _as_float(v, default: float = 0.0) -> float:
    try:
        f = float(v)
        return f if f == f else default   # reject NaN
    except (TypeError, ValueError):
        return default


def _as_int(v, default: int = 0) -> int:
    try:
        return int(v)
    except (TypeError, ValueError):
        return default


def _norm_tags(v) -> List[str]:
    """Accept a list or a comma/newline string; strip ``#``, dedupe (case-insensitively)."""
    if isinstance(v, str):
        parts: list = re.split(r"[,\n]+", v)
    elif isinstance(v, (list, tuple)):
        parts = list(v)
    else:
        return []
    out: List[str] = []
    seen = set()
    for raw in parts:
        t = str(raw).strip().lstrip("#").strip()[:MAX_TAG]
        if not t:
            continue
        key = t.lower()
        if key in seen:
            continue
        seen.add(key)
        out.append(t)
        if len(out) >= MAX_TAGS:
            break
    return out


def _coerce(payload: dict, manifest: Optional[dict], base: Optional[dict] = None) -> dict:
    """Validate + clamp a create (``base=None``) or merge a PATCH (``base`` = existing note).

    On PATCH only keys present in ``payload`` are overwritten, so a partial patch (e.g. just
    ``color``) never wipes the body. ``manifest`` (create only) range-checks ``ch``.
    """
    if not isinstance(payload, dict):
        raise NoteError("Note payload must be an object")
    n = dict(base) if base else {}
    creating = base is None
    has = payload.__contains__

    if creating or has("ch"):
        ch = _as_int(payload.get("ch", n.get("ch", 0)))
        if manifest is not None:
            chapters = manifest.get("chapters", [])
            if ch < 0 or ch >= len(chapters):
                raise NoteError(f"Chapter index {ch} out of range")
        n["ch"] = ch

    if creating or has("si") or has("sj"):
        si = max(0, _as_int(payload.get("si", n.get("si", 0))))
        sj = max(0, _as_int(payload.get("sj", n.get("sj", si))))
        if sj < si:
            si, sj = sj, si
        n["si"], n["sj"] = si, sj

    for k in ("cs", "ce"):
        if creating or has(k):
            n[k] = _as_int(payload.get(k, n.get(k, 0)))
    for k in ("s", "e"):
        if creating or has(k):
            n[k] = _as_float(payload.get(k, n.get(k, 0.0)))

    if creating or has("exact"):
        n["exact"] = str(payload.get("exact", n.get("exact", "")))[:MAX_EXACT]
    for k in ("prefix", "suffix"):
        if creating or has(k):
            n[k] = str(payload.get(k, n.get(k, "")))[:MAX_CTX]

    if creating or has("color"):
        c = str(payload.get("color", n.get("color", DEFAULT_COLOR))).lower()
        n["color"] = c if c in COLORS else DEFAULT_COLOR

    if creating or has("tags"):
        n["tags"] = _norm_tags(payload.get("tags", n.get("tags", [])))

    if creating or has("note"):
        n["note"] = str(payload.get("note", n.get("note", "")))[:MAX_NOTE]

    # kind: honor an explicit valid kind, else derive from whether there's a body.
    if has("kind") and str(payload.get("kind")) in KINDS:
        n["kind"] = str(payload.get("kind"))
    else:
        n["kind"] = "note" if str(n.get("note", "")).strip() else "highlight"

    return n


# ------------------------------------------------------------------------------- CRUD
def create_note(book_id: str, payload: dict, manifest: Optional[dict] = None) -> dict:
    note = _coerce(payload, manifest)
    note["id"] = uuid.uuid4().hex
    note["created"] = note["updated"] = _now_iso()
    with _lock:
        doc = load_doc(book_id)
        doc["notes"].append(note)
        _write_atomic(book_id, doc)
    return note


def update_note(book_id: str, note_id: str, payload: dict) -> Optional[dict]:
    with _lock:
        doc = load_doc(book_id)
        for i, n in enumerate(doc["notes"]):
            if n.get("id") == note_id:
                merged = _coerce(payload, None, base=n)
                merged["id"] = note_id
                merged["created"] = n.get("created") or _now_iso()
                merged["updated"] = _now_iso()
                doc["notes"][i] = merged
                _write_atomic(book_id, doc)
                return merged
    return None


def delete_note(book_id: str, note_id: str) -> bool:
    with _lock:
        doc = load_doc(book_id)
        kept = [n for n in doc["notes"] if n.get("id") != note_id]
        if len(kept) == len(doc["notes"]):
            return False
        doc["notes"] = kept
        _write_atomic(book_id, doc)
    return True


def merge_notes(book_id: str, incoming: List[dict]) -> List[dict]:
    """Merge a peer's notes in, last-write-wins per ``id`` on ``updated``; return the result.

    The primitive the mobile app uses to push/pull over the LAN. Unknown ids are added; a
    record whose ``updated`` is newer (or equal) replaces the local one. Deletions do not
    propagate (no tombstones in v1) — a re-add just reappears, never silently lost.
    """
    with _lock:
        doc = load_doc(book_id)
        by_id = {n.get("id"): n for n in doc["notes"] if n.get("id")}
        for raw in (incoming or []):
            if not isinstance(raw, dict):
                continue
            nid = raw.get("id")
            if not nid:
                continue
            existing = by_id.get(nid)
            if existing is None or str(raw.get("updated", "")) >= str(existing.get("updated", "")):
                clean = _coerce(raw, None)
                clean["id"] = nid
                clean["created"] = raw.get("created") or (existing or {}).get("created") or _now_iso()
                clean["updated"] = raw.get("updated") or _now_iso()
                by_id[nid] = clean
        doc["notes"] = sorted(by_id.values(), key=_reading_key)
        _write_atomic(book_id, doc)
        return doc["notes"]


# ----------------------------------------------------------------------------- export
def _clean(text: str) -> str:
    return " ".join((text or "").split())


def _mmss(sec: float) -> str:
    """Format seconds as ``M:SS`` (or ``H:MM:SS``); NaN/negative guard like subtitles._ts."""
    if not sec or sec < 0 or sec != sec:
        sec = 0.0
    total = int(sec)
    h, rem = divmod(total, 3600)
    m, s = divmod(rem, 60)
    return f"{h}:{m:02d}:{s:02d}" if h else f"{m}:{s:02d}"


def _ch_title(manifest: dict, ch: int) -> str:
    """Chapter title, or a ``Chapter N`` fallback when ``ch`` no longer exists (shrunk book)."""
    chapters = manifest.get("chapters", [])
    if 0 <= ch < len(chapters):
        return _clean(chapters[ch].get("title", "")) or f"Chapter {ch + 1}"
    return f"Chapter {ch + 1}"


def _blockquote(text: str, marker: str = "> ") -> str:
    """Prefix EVERY line so a multi-line / ``>``-containing body can't escape a callout."""
    return "\n".join(marker + ln for ln in (text or "").split("\n"))


def _slug_tag(t: str) -> str:
    s = re.sub(r"\s+", "-", (t or "").strip())
    s = re.sub(r"[^0-9A-Za-z_/\-]", "", s)
    return s or "tag"


def _inline_tags(tags: List[str]) -> str:
    return " ".join("#" + _slug_tag(t) for t in (tags or []) if t)


def _yaml_scalar(s: str) -> str:
    """Quote a YAML scalar when it contains metacharacters (keeps frontmatter valid)."""
    s = str(s or "")
    if s == "" or s[0] in " -?" or re.search(r"""[:#\[\]{},&*!|>%@`"']""", s):
        return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'
    return s


def _group_by_chapter(notes: List[dict]):
    ordered = sorted(notes, key=_reading_key)
    for ch, group in groupby(ordered, key=lambda n: n.get("ch", 0)):
        yield ch, list(group)


def _today() -> str:
    return _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%d")


def to_markdown(manifest: dict, notes: List[dict]) -> str:
    """Portable Markdown: frontmatter + per-chapter sections, quote as blockquote + note."""
    title = _clean(manifest.get("title") or manifest.get("id") or "Audiobook")
    author = _clean(manifest.get("author", ""))
    parts: List[str] = ["---", f"title: {_yaml_scalar(title)}"]
    if author:
        parts.append(f"author: {_yaml_scalar(author)}")
    parts += [f"date: {_today()}", "tags: [audiobook, notes]", "---", "", f"# {title} — Notes"]
    if author:
        parts += ["", f"*by {author}*"]
    if not notes:
        return "\n".join(parts + ["", "_No notes yet._"]).strip() + "\n"
    for ch, group in _group_by_chapter(notes):
        parts += ["", f"## {_ch_title(manifest, ch)}"]
        for n in group:
            quote = _clean(n.get("exact", ""))
            body = (n.get("note") or "").strip()
            meta = f"*[{_mmss(n.get('s', 0.0))}]*"
            tagline = _inline_tags(n.get("tags", []))
            if tagline:
                meta += "  " + tagline
            parts.append("")
            if quote:
                parts += [_blockquote(quote), ""]
            parts.append(meta)
            if body:
                parts += ["", f"**Note:** {body}"]
    return "\n".join(parts).strip() + "\n"


def to_obsidian(manifest: dict, notes: List[dict]) -> str:
    """Obsidian flavor: plural-list frontmatter tags (1.9+), ``[!quote]`` callouts, block ids."""
    title = _clean(manifest.get("title") or manifest.get("id") or "Audiobook")
    author = _clean(manifest.get("author", ""))
    book_id = manifest.get("id", "")

    extra: List[str] = []
    seen = set()
    for n in notes:
        for t in n.get("tags", []):
            s = _slug_tag(t)
            if s and s.lower() not in seen:
                seen.add(s.lower())
                extra.append(s)

    fm: List[str] = ["---", f"title: {_yaml_scalar(title)}"]
    if author:
        fm.append(f"author: {_yaml_scalar(author)}")
    fm += [f"date: {_today()}", "source: audiobook-reader"]
    if book_id:
        fm.append(f"book_id: {_yaml_scalar(book_id)}")
    fm.append("tags:")
    for t in ["audiobook", "notes", *extra]:
        fm.append(f"  - {t}")
    fm.append("---")

    parts = fm + ["", f"# {title}"]
    if not notes:
        return "\n".join(parts + ["", "_No notes yet._"]).strip() + "\n"
    for ch, group in _group_by_chapter(notes):
        ctitle = _ch_title(manifest, ch)
        parts += ["", f"## {ctitle}"]
        for n in group:
            quote = _clean(n.get("exact", ""))
            body = (n.get("note") or "").strip()
            tagline = _inline_tags(n.get("tags", []))
            parts += ["", f"> [!quote] {ctitle} — [{_mmss(n.get('s', 0.0))}]"]
            if quote:
                parts.append(_blockquote(quote))
            if body:
                parts += [">", _blockquote(body)]
                if tagline:
                    parts.append("> " + tagline)
            elif tagline:
                parts += [">", "> " + tagline]
            # Stable block id, on the line DIRECTLY after the callout (no blank line) so it
            # attaches to the callout block → linkable/embeddable as [[Title#^chN-sSI]].
            parts.append(f"^ch{ch + 1}-s{n.get('si', 0)}")
    return "\n".join(parts).strip() + "\n"
