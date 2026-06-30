"""PDF -> clean linear text + structural markers (chapters / topics).

Strategy:
  1. Pull cleaned text per page and concatenate into one linear string,
     remembering where each page starts (so we can map TOC pages -> offsets).
  2. Prefer the embedded PDF outline (bookmarks) for chapter/topic structure.
  3. If there is no outline, fall back to font-size based heading detection.
  4. If that also fails, the caller chunks the text into fixed-size sections.
"""
from __future__ import annotations

from pathlib import Path
from typing import List

import fitz  # PyMuPDF

from . import textproc
from .extract import BookDoc, Marker


def _meta(doc, key: str) -> str:
    v = (doc.metadata or {}).get(key) or ""
    return v.strip()


def extract(pdf_path: str | Path) -> BookDoc:
    pdf_path = Path(pdf_path)
    doc = fitz.open(pdf_path)

    raw_pages = [doc.load_page(i).get_text("text") for i in range(doc.page_count)]
    running = textproc.detect_running_lines(raw_pages)

    pages: List[str] = []
    page_offsets: List[int] = []
    parts: List[str] = []
    cursor = 0
    for raw in raw_pages:
        cleaned = textproc.clean_page(raw, running)
        page_offsets.append(cursor)
        pages.append(cleaned)
        parts.append(cleaned)
        cursor += len(cleaned) + 2  # +2 for the "\n\n" page joiner
    linear_text = "\n\n".join(parts)

    title = _meta(doc, "title") or pdf_path.stem.replace("_", " ").strip()
    author = _meta(doc, "author")

    markers, source = _build_markers(doc, pages, page_offsets, linear_text)

    result = BookDoc(
        title=title, author=author, n_pages=doc.page_count,
        pages=pages, linear_text=linear_text, page_offsets=page_offsets,
        markers=markers, toc_source=source,
    )
    doc.close()
    return result


def _locate_offset(title: str, page: int, pages: List[str], page_offsets: List[int]) -> int:
    """Best-effort char offset of a heading: search its title near its page."""
    if page < 0 or page >= len(pages):
        page = max(0, min(page, len(pages) - 1))
    base = page_offsets[page]
    want = textproc.normalize_for_match(title)
    if want:
        norm = textproc.normalize_for_match(pages[page])
        pos = norm.find(want[:40])
        if pos >= 0:
            # Map normalized position back roughly to raw page text by ratio.
            ratio = pos / max(1, len(norm))
            approx = int(ratio * len(pages[page]))
            return base + approx
    return base


def _build_markers(doc, pages, page_offsets, linear_text):
    toc = doc.get_toc(simple=True) or []
    markers: List[Marker] = []
    for level, title, page1 in toc:
        title = (title or "").strip()
        if not title:
            continue
        page = max(0, page1 - 1)
        off = _locate_offset(title, page, pages, page_offsets)
        markers.append(Marker(level=max(1, int(level)), title=title, page=page, offset=off))

    if markers:
        markers.sort(key=lambda m: m.offset)
        return markers, "outline"

    # Fallback: detect headings by font size.
    font_markers = _detect_headings_by_font(doc, pages, page_offsets)
    if font_markers:
        return font_markers, "font"

    return [], "none"


def _detect_headings_by_font(doc, pages, page_offsets) -> List[Marker]:
    """Heuristic heading detection: lines whose font is clearly larger than body."""
    sizes: List[float] = []
    spans_info = []  # (page, size, text, y)
    for pi in range(doc.page_count):
        page = doc.load_page(pi)
        d = page.get_text("dict")
        for block in d.get("blocks", []):
            for line in block.get("lines", []):
                txt = "".join(s.get("text", "") for s in line.get("spans", [])).strip()
                if not txt:
                    continue
                size = max((s.get("size", 0) for s in line.get("spans", [])), default=0)
                bold = any("bold" in (s.get("font", "").lower()) for s in line.get("spans", []))
                sizes.append(size)
                spans_info.append((pi, size, txt, bold))
    if not sizes:
        return []

    sizes.sort()
    body = sizes[len(sizes) // 2]  # median ~ body text size
    threshold = body * 1.25

    markers: List[Marker] = []
    for pi, size, txt, bold in spans_info:
        is_heading = (size >= threshold or (bold and size >= body * 1.1))
        # Headings are short, not full sentences.
        if is_heading and 2 <= len(txt) <= 90 and txt[-1] not in ".,;:":
            off = _locate_offset(txt, pi, pages, page_offsets)
            markers.append(Marker(level=1, title=txt, page=pi, offset=off))

    # Deduplicate near-identical consecutive markers and require some spacing.
    cleaned: List[Marker] = []
    for m in sorted(markers, key=lambda x: x.offset):
        if cleaned and (m.offset - cleaned[-1].offset) < 400:
            continue
        cleaned.append(m)
    # Too many headings == probably noise; bail out.
    if len(cleaned) > max(4, doc.page_count // 2 + 5) and len(cleaned) > 80:
        return []
    return cleaned
