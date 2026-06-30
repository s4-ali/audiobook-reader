"""EPUB -> clean linear text + chapter/topic markers.

EPUBs are much friendlier than PDFs: clean XHTML content, a spine (reading
order) and a hierarchical navigation document (the TOC). We:
  1. Concatenate the spine documents (as cleaned text) into one linear string.
  2. Turn the nav/TOC tree into chapter (level 1) / topic (level >= 2) markers,
     mapping each entry's href (+ optional #anchor) to a char offset.
  3. Fall back to "one chapter per spine document" if there is no TOC.
"""
from __future__ import annotations

import re
import warnings
from pathlib import Path
from typing import Dict, List, Optional

from . import textproc
from .extract import BookDoc, Marker

# Block-level tags force a paragraph break; these are dropped entirely.
_BLOCK = {"p", "div", "section", "article", "blockquote", "li", "ul", "ol",
          "table", "tr", "td", "th", "h1", "h2", "h3", "h4", "h5", "h6",
          "br", "hr", "figure", "figcaption", "pre", "header", "footer"}
_SKIP = {"script", "style", "head", "title", "nav"}


def _doc_to_text(html: bytes) -> str:
    """Render an XHTML document to paragraph-separated plain text."""
    from bs4 import BeautifulSoup, NavigableString, Tag

    soup = BeautifulSoup(html, "html.parser")
    out: List[str] = []

    def walk(node):
        if isinstance(node, NavigableString):
            out.append(str(node))
        elif isinstance(node, Tag):
            if node.name in _SKIP:
                return
            for child in node.children:
                walk(child)
            if node.name in _BLOCK:
                out.append("\n")

    walk(soup.body or soup)

    paragraphs: List[str] = []
    for seg in "".join(out).split("\n"):
        seg = textproc.normalize_unicode(seg)
        seg = re.sub(r"[ \t ]+", " ", seg).strip()
        if seg:
            paragraphs.append(seg)
    return "\n\n".join(paragraphs)


def _meta(book, name: str) -> str:
    try:
        data = book.get_metadata("DC", name)
        if data:
            return (data[0][0] or "").strip()
    except Exception:
        pass
    return ""


def _locate_in_text(title: str, text: str) -> int:
    """Best-effort char offset of a heading within a document's text."""
    t = title.strip()
    if not t or not text:
        return 0
    pos = text.lower().find(t.lower())
    if pos >= 0:
        return pos
    want = textproc.normalize_for_match(title)
    if not want:
        return 0
    norm = textproc.normalize_for_match(text)
    p = norm.find(want[:40])
    if p < 0:
        return 0
    return int(p / max(1, len(norm)) * len(text))


def extract(epub_path: str | Path) -> BookDoc:
    import ebooklib
    from ebooklib import epub

    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        book = epub.read_epub(str(epub_path))

    title = _meta(book, "title") or Path(epub_path).stem.replace("_", " ").strip()
    author = _meta(book, "creator")

    # --- Linear text in spine (reading) order ---
    pages: List[str] = []
    page_offsets: List[int] = []
    name_to_index: Dict[str, int] = {}
    parts: List[str] = []
    cursor = 0
    for entry in book.spine:
        idref = entry[0] if isinstance(entry, (tuple, list)) else entry
        item = book.get_item_with_id(idref)
        if item is None or item.get_type() != ebooklib.ITEM_DOCUMENT:
            continue
        text = _doc_to_text(item.get_content())
        name = item.get_name() or ""
        idx = len(pages)
        name_to_index[name] = idx
        name_to_index[name.split("/")[-1]] = idx  # also match by basename
        page_offsets.append(cursor)
        pages.append(text)
        parts.append(text)
        cursor += len(text) + 2  # +2 for the "\n\n" joiner
    linear_text = "\n\n".join(parts)

    markers = _markers_from_toc(book, pages, page_offsets, name_to_index)
    source = "epub-nav"
    if not markers:
        markers = _markers_from_spine(pages, page_offsets)
        source = "epub-spine" if markers else "none"

    return BookDoc(
        title=title, author=author, n_pages=len(pages),
        pages=pages, linear_text=linear_text, page_offsets=page_offsets,
        markers=markers, toc_source=source,
    )


def _href_index(href: Optional[str], name_to_index: Dict[str, int]) -> Optional[int]:
    if not href:
        return None
    h = href.split("#")[0]
    if h in name_to_index:
        return name_to_index[h]
    base = h.split("/")[-1]
    return name_to_index.get(base)


def _markers_from_toc(book, pages, page_offsets, name_to_index) -> List[Marker]:
    markers: List[Marker] = []

    def add(title, href, level):
        title = (title or "").strip()
        di = _href_index(href, name_to_index)
        if not title or di is None:
            return
        offset = page_offsets[di] + _locate_in_text(title, pages[di])
        markers.append(Marker(level=max(1, level), title=title, page=di, offset=offset))

    def walk(entry, level):
        if isinstance(entry, (tuple, list)) and len(entry) == 2 and not isinstance(entry[1], str):
            section, children = entry            # (Section/Link, [children])
            add(getattr(section, "title", None), getattr(section, "href", None), level)
            for child in children:
                walk(child, level + 1)
        elif isinstance(entry, (tuple, list)):
            for child in entry:
                walk(child, level)
        else:                                    # epub.Link
            add(getattr(entry, "title", None), getattr(entry, "href", None), level)

    for top in (book.toc or []):
        walk(top, 1)
    markers.sort(key=lambda m: m.offset)
    return markers


def _markers_from_spine(pages, page_offsets) -> List[Marker]:
    """No TOC: treat each spine document as a chapter."""
    markers: List[Marker] = []
    for i, text in enumerate(pages):
        if textproc.word_count(text) == 0:
            continue
        first = text.split("\n\n", 1)[0].strip()
        title = first if 0 < len(first) <= 80 else f"Section {i + 1}"
        markers.append(Marker(level=1, title=title, page=i, offset=page_offsets[i]))
    return markers
