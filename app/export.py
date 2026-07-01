"""Package a completed audiobook into a single ``.abk`` file for transfer to phones.

An ``.abk`` is just a ZIP archive (stored, not deflated — the MP3s are already
compressed) whose members sit at the archive root::

    <book-id>.abk
    ├── manifest.json      # the existing contract, byte-for-byte
    ├── ch0000.mp3
    ├── ch0001.mp3
    └── …                  # exactly the files referenced by each ready chapter

The mobile app reads ``manifest.id`` to choose its on-device folder and resolves each
chapter's ``audio`` filename next to the manifest — the same layout the server already
serves from disk, so nothing downstream needs to change.

Run as a module:
    python -m app.export <book-id>              # package one book into the cwd
    python -m app.export                        # package every "ready" book
    python -m app.export <book-id> -o ~/Desktop # choose the output directory
"""
from __future__ import annotations

import argparse
import os
import zipfile
from pathlib import Path
from typing import Optional

from . import config, library


def package_book(book_id: str, out_dir: Optional[Path] = None) -> Path:
    """Bundle a ready book's manifest + audio into ``<out_dir>/<book-id>.abk``.

    Raises FileNotFoundError if the book (or a referenced audio file) is missing and
    ValueError if the book is not fully generated (``status != "ready"``).
    """
    book_dir = config.BOOKS_DIR / book_id
    manifest = library.get_manifest(book_id)
    if manifest is None:
        raise FileNotFoundError(f"No book with id '{book_id}' in {config.BOOKS_DIR}")
    status = manifest.get("status", "ready")
    if status != "ready":
        raise ValueError(
            f"Book '{book_id}' is '{status}', not 'ready' — finish generating it first "
            "(resume with ./scripts/ingest.sh <file> --resume)."
        )

    # Collect the audio files referenced by ready chapters (mirrors the player's leniency:
    # a chapter with no explicit status is treated as ready).
    audio_files = []
    for ch in manifest.get("chapters", []):
        if ch.get("status", "ready") != "ready":
            continue
        name = ch.get("audio")
        if not name:
            continue
        fp = book_dir / name
        if not fp.exists():
            raise FileNotFoundError(
                f"Audio file '{name}' referenced by chapter {ch.get('id')} is missing from {book_dir}"
            )
        audio_files.append(fp)

    out_dir = Path(out_dir) if out_dir else Path.cwd()
    out_dir.mkdir(parents=True, exist_ok=True)
    out_path = out_dir / f"{book_id}.abk"
    tmp_path = out_path.with_name(out_path.name + ".tmp")

    # ZIP_STORED: the payload is already-compressed MP3, so deflate burns CPU for ~0 gain.
    with zipfile.ZipFile(tmp_path, "w", compression=zipfile.ZIP_STORED) as zf:
        zf.write(book_dir / "manifest.json", "manifest.json")
        # Ship reading notes with the book when present, so they land next to the manifest
        # in the same flat layout the mobile app reads (see app/notes.py).
        notes_file = book_dir / "notes.json"
        if notes_file.exists():
            zf.write(notes_file, "notes.json")
        for fp in audio_files:
            zf.write(fp, fp.name)
    os.replace(tmp_path, out_path)  # atomic: never leave a half-written .abk
    return out_path


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description="Package a completed audiobook into a .abk file.")
    p.add_argument("book_id", nargs="?",
                   help="book id to package (default: every 'ready' book in the library)")
    p.add_argument("-o", "--output", help="output directory for the .abk file (default: cwd)")
    args = p.parse_args(argv)

    out_dir = Path(args.output) if args.output else None

    if args.book_id:
        ids = [args.book_id]
    else:
        ids = [b["id"] for b in library.list_books() if b.get("status", "ready") == "ready"]
        if not ids:
            print(f"No 'ready' books found in {config.BOOKS_DIR}.")
            return 1

    rc = 0
    for bid in ids:
        try:
            path = package_book(bid, out_dir=out_dir)
            size_mb = path.stat().st_size / (1024 * 1024)
            print(f"  ✓ {bid} → {path}  ({size_mb:.1f} MB)")
        except (FileNotFoundError, ValueError) as e:
            print(f"  ✗ {bid}: {e}")
            rc = 1
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
