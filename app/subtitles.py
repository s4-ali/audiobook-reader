"""Build SRT / WebVTT subtitles and a plain-text transcript from a book manifest.

The per-sentence timings the manifest already stores (``s``/``e`` seconds, ``t`` text)
are exactly what a subtitle file needs, so this is a pure transform — no audio is read.
Per-chapter output aligns to that chapter's own audio file; whole-book output offsets each
chapter by the running sum of chapter durations (matching the chapter MP3s played — or
concatenated — in order), so it doubles as a synced, full-book transcript.
"""
from __future__ import annotations

from typing import List, Optional, Tuple

Cue = Tuple[float, float, str]


def _ts(sec: float, sep: str) -> str:
    """Format seconds as HH:MM:SS<sep>mmm (sep is ',' for SRT, '.' for VTT)."""
    if not sec or sec < 0 or sec != sec:   # falsy / negative / NaN
        sec = 0.0
    ms = int(round(sec * 1000))
    h, ms = divmod(ms, 3_600_000)
    m, ms = divmod(ms, 60_000)
    s, ms = divmod(ms, 1000)
    return f"{h:02d}:{m:02d}:{s:02d}{sep}{ms:03d}"


def _clean(text: str) -> str:
    return " ".join((text or "").split())


def _is_ready(ch: dict) -> bool:
    return ch.get("status", "ready") == "ready"


def _cues_for_chapter(ch: dict, offset: float) -> List[Cue]:
    out: List[Cue] = []
    for s in ch.get("sentences", []):
        st = float(s.get("s", 0.0)) + offset
        en = float(s.get("e", st)) + offset
        if en <= st:
            en = st + 0.5            # guarantee a positive, visible duration
        txt = _clean(s.get("t", ""))
        if txt:
            out.append((st, en, txt))
    return out


def build_cues(manifest: dict, chapter_index: Optional[int] = None) -> List[Cue]:
    """Timed cues for one chapter (times relative to its audio) or the whole book."""
    chapters = manifest.get("chapters", [])
    if chapter_index is not None:
        return _cues_for_chapter(chapters[chapter_index], 0.0)
    cues: List[Cue] = []
    offset = 0.0
    for ch in chapters:
        if not _is_ready(ch):
            continue
        cues.extend(_cues_for_chapter(ch, offset))
        offset += float(ch.get("duration", 0.0) or 0.0)
    return cues


def to_srt(cues: List[Cue]) -> str:
    lines: List[str] = []
    for i, (st, en, txt) in enumerate(cues, 1):
        lines += [str(i), f"{_ts(st, ',')} --> {_ts(en, ',')}", txt, ""]
    return "\n".join(lines)


def _vtt_escape(t: str) -> str:
    return t.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def to_vtt(cues: List[Cue]) -> str:
    lines: List[str] = ["WEBVTT", ""]
    for (st, en, txt) in cues:
        lines += [f"{_ts(st, '.')} --> {_ts(en, '.')}", _vtt_escape(txt), ""]
    return "\n".join(lines)


def to_transcript(manifest: dict) -> str:
    """A readable plain-text transcript: title, author, then chapter headings + paragraphs."""
    parts: List[str] = []
    parts.append(manifest.get("title") or manifest.get("id") or "Audiobook")
    if manifest.get("author"):
        parts.append(f"by {manifest['author']}")
    for ch in manifest.get("chapters", []):
        if not _is_ready(ch):
            continue
        parts += ["", "", f"## {_clean(ch.get('title', ''))}".rstrip(), ""]
        buf: List[str] = []
        for s in ch.get("sentences", []):
            t = _clean(s.get("t", ""))
            if not t:
                continue
            buf.append(t)
            if s.get("p"):                 # paragraph-break flag → flush a paragraph
                parts.append(" ".join(buf))
                buf = []
        if buf:
            parts.append(" ".join(buf))
    return "\n".join(parts).strip() + "\n"
