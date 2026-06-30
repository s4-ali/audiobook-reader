"""Text cleaning, paragraph reconstruction and sentence segmentation.

The goal is to turn messy PDF text into clean, narratable prose while keeping
enough structure (paragraph breaks) to drive natural pauses and to map text
positions back to audio timestamps.
"""
from __future__ import annotations

import re
import unicodedata
from collections import Counter
from dataclasses import dataclass
from typing import List, Tuple

# ---------------------------------------------------------------------------
# Cleaning
# ---------------------------------------------------------------------------

_LIGATURES = {
    "ﬀ": "ff", "ﬁ": "fi", "ﬂ": "fl", "ﬃ": "ffi",
    "ﬄ": "ffl", "ﬅ": "st", "ﬆ": "st",
    "‘": "'", "’": "'", "“": '"', "”": '"',
    "–": "-", "—": "-", "…": "...", " ": " ",
}

_PAGE_NUM_RE = re.compile(r"^\s*(?:[ivxlcdm]+|\d+)\s*$", re.IGNORECASE)


def normalize_unicode(text: str) -> str:
    for k, v in _LIGATURES.items():
        text = text.replace(k, v)
    text = unicodedata.normalize("NFKC", text)
    return text


def _dehyphenate(text: str) -> str:
    # Join words split across line breaks: "exam-\nple" -> "example"
    text = re.sub(r"(\w)[­-]\n(\w)", r"\1\2", text)
    return text


def detect_running_lines(pages: List[str], threshold: float = 0.4) -> set:
    """Find header/footer lines that repeat across many pages so we can strip them."""
    first_last = Counter()
    n = max(1, len(pages))
    for page in pages:
        lines = [ln.strip() for ln in page.splitlines() if ln.strip()]
        if not lines:
            continue
        for ln in (lines[0], lines[-1]):
            # Ignore very long lines (real content) and pure page numbers (handled separately)
            if 0 < len(ln) <= 80 and not _PAGE_NUM_RE.match(ln):
                first_last[ln] += 1
    return {ln for ln, c in first_last.items() if c / n >= threshold and c >= 3}


def clean_page(raw: str, running: set) -> str:
    """Clean a single page into paragraph-separated prose.

    Single newlines (visual line wraps) become spaces; blank lines become
    paragraph breaks ("\n\n").
    """
    raw = normalize_unicode(raw)
    raw = _dehyphenate(raw)

    kept: List[str] = []
    for ln in raw.splitlines():
        s = ln.strip()
        if not s:
            kept.append("")  # paragraph separator marker
            continue
        if s in running:
            continue
        if _PAGE_NUM_RE.match(s):
            continue
        kept.append(s)

    # Rebuild: group consecutive non-empty lines into paragraphs.
    paragraphs: List[str] = []
    buf: List[str] = []
    for ln in kept:
        if ln == "":
            if buf:
                paragraphs.append(" ".join(buf))
                buf = []
        else:
            buf.append(ln)
    if buf:
        paragraphs.append(" ".join(buf))

    text = "\n\n".join(paragraphs)
    text = re.sub(r"[ \t]+", " ", text)
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text.strip()


def slugify(text: str, maxlen: int = 60) -> str:
    text = normalize_unicode(text).lower()
    text = re.sub(r"[^a-z0-9]+", "-", text).strip("-")
    if len(text) > maxlen:
        text = text[:maxlen].rstrip("-")
    return text or "book"


def normalize_for_match(text: str) -> str:
    text = normalize_unicode(text).lower()
    text = re.sub(r"^\s*(chapter|section|part)\s+[\divxlc]+[:.\s-]*", "", text)
    text = re.sub(r"[^a-z0-9 ]+", " ", text)
    return re.sub(r"\s+", " ", text).strip()


# ---------------------------------------------------------------------------
# Sentence segmentation (with character offsets)
# ---------------------------------------------------------------------------

@dataclass
class Sentence:
    text: str
    start: int  # char offset within the source text
    end: int


_FALLBACK_SENT_RE = re.compile(r"[^.!?]+(?:[.!?]+[\"')\]]*|\Z)", re.DOTALL)


def _fallback_segment(text: str) -> List[Sentence]:
    out: List[Sentence] = []
    for m in _FALLBACK_SENT_RE.finditer(text):
        s = m.group().strip()
        if not s:
            continue
        start = m.start() + (len(m.group()) - len(m.group().lstrip()))
        out.append(Sentence(s, start, start + len(s)))
    return out


_segmenter = None


def split_sentences(text: str) -> List[Sentence]:
    """Split into sentences, returning char spans into ``text``.

    Uses pysbd when available (handles abbreviations well), else a regex fallback.
    Paragraph breaks always force a boundary so pause logic stays correct.
    """
    global _segmenter
    if not text.strip():
        return []

    # Split on paragraphs first so offsets stay aligned and pauses land right.
    results: List[Sentence] = []
    for para in re.finditer(r"[^\n]+(?:\n(?!\n)[^\n]+)*", text):
        chunk = para.group()
        base = para.start()
        results.extend(_split_chunk(chunk, base))
    return results


def _split_chunk(chunk: str, base: int) -> List[Sentence]:
    global _segmenter
    try:
        if _segmenter is None:
            import warnings
            with warnings.catch_warnings():
                warnings.simplefilter("ignore")  # pysbd emits SyntaxWarnings on 3.12+
                import pysbd
            _segmenter = pysbd.Segmenter(language="en", clean=False, char_span=True)
        spans = _segmenter.segment(chunk)
        out: List[Sentence] = []
        for sp in spans:
            s = sp.sent.strip()
            if not s:
                continue
            lead = len(sp.sent) - len(sp.sent.lstrip())
            start = base + sp.start + lead
            out.append(Sentence(s, start, start + len(s)))
        return out
    except Exception:
        return [Sentence(s.text, base + s.start, base + s.end)
                for s in _fallback_segment(chunk)]


def word_count(text: str) -> int:
    return len(re.findall(r"\b\w+\b", text))
