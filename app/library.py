"""Library index: discover generated audiobooks on disk."""
from __future__ import annotations

import json
from pathlib import Path
from typing import List, Optional

from .config import BOOKS_DIR


def _read_manifest(book_dir: Path) -> Optional[dict]:
    mf = book_dir / "manifest.json"
    if not mf.exists():
        return None
    try:
        return json.loads(mf.read_text(encoding="utf-8"))
    except Exception:
        return None


def list_books() -> List[dict]:
    """Return lightweight summaries for the library view."""
    books: List[dict] = []
    if not BOOKS_DIR.exists():
        return books
    for book_dir in sorted(BOOKS_DIR.iterdir()):
        if not book_dir.is_dir():
            continue
        m = _read_manifest(book_dir)
        if not m:
            continue
        chapters = m.get("chapters", [])
        books.append({
            "id": m.get("id", book_dir.name),
            "title": m.get("title", book_dir.name),
            "author": m.get("author", ""),
            "voice": m.get("voice", ""),
            "engine": m.get("engine", ""),
            "n_chapters": m.get("chapters_total", len(chapters)),
            "chapters_ready": m.get("chapters_ready",
                                    sum(1 for c in chapters if c.get("status", "ready") == "ready")),
            "status": m.get("status", "ready"),
            "duration": m.get("total_duration", 0.0),
            "created": m.get("created", ""),
        })
    books.sort(key=lambda b: b.get("created", ""), reverse=True)
    return books


def get_manifest(book_id: str) -> Optional[dict]:
    return _read_manifest(BOOKS_DIR / book_id)
