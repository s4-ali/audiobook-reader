#!/usr/bin/env python
"""Settle sentence-start boundaries in existing books' manifests, in place.

Older manifests put every sentence's `s` exactly on its first spoken sample (or, for
Voxtral books, on the forced aligner's first-word onset). That zero leading margin makes
click-to-seek fragile: players seek MP3 with frame granularity (~24 ms, landing at or
before the target), so a seek can land a hair early and play the tail of the previous
sentence — worst on Voxtral books, whose speech is continuous across sentence boundaries.

New ingests settle each start halfway into the preceding pause (capped at
config.SENTENCE_LEAD_MS; see ingest._settle_boundaries). This script applies the identical
transform to already-generated books. Manifest-only: audio is untouched, TTS is not re-run.

    .venv/bin/python scripts/retime_boundaries.py [book-id ...]   # default: every book

Idempotent: manifests are stamped with `timing_version` and skipped on a second run
(settling twice would keep eroding the boundary's leading margin).
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from app import config  # noqa: E402
from app.ingest import settle_manifest, _write_manifest_atomic  # noqa: E402


def main(argv: list[str]) -> None:
    if argv:
        ids = argv
    elif config.BOOKS_DIR.is_dir():
        ids = sorted(p.name for p in config.BOOKS_DIR.iterdir()
                     if (p / "manifest.json").exists())
    else:
        ids = []
    if not ids:
        print(f"No books found under {config.BOOKS_DIR}")
        return
    for book_id in ids:
        book_dir = config.BOOKS_DIR / book_id
        mf_path = book_dir / "manifest.json"
        if not mf_path.exists():
            print(f"{book_id}: no manifest.json — skipped")
            continue
        manifest = json.loads(mf_path.read_text(encoding="utf-8"))
        if settle_manifest(manifest):
            _write_manifest_atomic(book_dir, manifest)
            print(f"{book_id}: sentence boundaries settled")
        else:
            print(f"{book_id}: already settled — skipped")


if __name__ == "__main__":
    main(sys.argv[1:])
