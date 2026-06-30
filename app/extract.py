"""Shared book model + format dispatcher.

Both the PDF and EPUB extractors produce a :class:`BookDoc`, so everything
downstream (chapter segmentation, TTS, the player) is format-agnostic.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import List

SUPPORTED_EXTS = (".pdf", ".epub")


@dataclass
class Marker:
    """A structural anchor: a chapter (level 1) or sub-topic (level >= 2)."""
    level: int
    title: str
    page: int           # 0-based source position (PDF page or spine doc index)
    offset: int         # char offset into linear_text


@dataclass
class BookDoc:
    title: str
    author: str
    n_pages: int                # PDF pages, or EPUB spine documents
    pages: List[str]            # cleaned text per page/document
    linear_text: str            # whole book as one string
    page_offsets: List[int]     # char offset where each page/document begins
    markers: List[Marker] = field(default_factory=list)
    toc_source: str = "none"    # outline | font | epub-nav | epub-spine | none


def extract(path: str | Path) -> BookDoc:
    """Dispatch to the right extractor based on file extension."""
    ext = Path(path).suffix.lower()
    if ext == ".pdf":
        from .pdf_extract import extract as _extract
    elif ext == ".epub":
        from .epub_extract import extract as _extract
    else:
        raise ValueError(
            f"Unsupported file type {ext!r}. Supported: {', '.join(SUPPORTED_EXTS)}")
    return _extract(path)
