#!/usr/bin/env python
"""Re-encode existing chapter MP3s from VBR to CBR, in place.

Older books were encoded VBR (libmp3lame -q:a). VBR MP3s have variable-size frames, so
players (browser <audio>, ExoPlayer/just_audio) can't compute an exact byte offset for a
timestamp — they interpolate the coarse Xing TOC and land seeks seconds off, which desynced
the karaoke highlight and sent click-to-seek to the wrong sentence.

CBR gives every frame the same byte size => an exact time<->byte mapping => frame-accurate
seeking. Re-encoding is *content-preserving* (same duration, same sample timeline), so the
manifest's sentence timings stay valid and TTS does NOT need to re-run.

    .venv/bin/python scripts/reencode_cbr.py [book-id ...]   # default: every book

It skips files already CBR, and only replaces a file after verifying the re-encode's
duration matches the original (so a bad transcode can never corrupt a book's timings).
"""
from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from app import config  # noqa: E402

DURATION_TOLERANCE_S = 0.25  # a content-preserving re-encode changes duration by << this


def _duration(path: Path) -> float:
    out = subprocess.run(
        ["ffprobe", "-hide_banner", "-v", "error", "-show_entries",
         "format=duration", "-of", "csv=p=0", str(path)],
        capture_output=True, text=True)
    try:
        return float(out.stdout.strip())
    except ValueError:
        return -1.0


def _is_vbr(path: Path) -> bool:
    """True if the MP3 carries a Xing (VBR) header; False for an Info (CBR) header."""
    head = path.read_bytes()[:4000]
    if b"Info" in head:
        return False
    return b"Xing" in head


def reencode(path: Path) -> str:
    if not _is_vbr(path):
        return "skip (already CBR)"
    src_dur = _duration(path)
    tmp = path.with_suffix(".cbr.tmp.mp3")
    proc = subprocess.run(
        ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", str(path),
         "-c:a", "libmp3lame", "-b:a", str(config.MP3_BITRATE), str(tmp)],
        capture_output=True, text=True)
    if proc.returncode != 0:
        tmp.unlink(missing_ok=True)
        return f"FAILED ffmpeg: {proc.stderr[:200]}"
    new_dur = _duration(tmp)
    if src_dur < 0 or abs(new_dur - src_dur) > DURATION_TOLERANCE_S:
        tmp.unlink(missing_ok=True)
        return f"FAILED duration drift {src_dur:.3f} -> {new_dur:.3f}s (kept original)"
    os.replace(tmp, path)
    return f"CBR ok ({src_dur:.1f}s preserved)"


def main(argv=None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    books_dir = config.BOOKS_DIR
    ids = argv or sorted(d.name for d in books_dir.iterdir() if d.is_dir())
    total = converted = 0
    for bid in ids:
        bdir = books_dir / bid
        if not bdir.is_dir():
            print(f"  ? {bid}: no such book")
            continue
        mp3s = sorted(bdir.glob("*.mp3"))
        if not mp3s:
            continue
        print(f"► {bid}  ({len(mp3s)} mp3)")
        for mp3 in mp3s:
            total += 1
            result = reencode(mp3)
            if result.startswith("CBR ok"):
                converted += 1
            print(f"    {mp3.name}: {result}")
    print(f"\nDone. {converted}/{total} file(s) converted to CBR.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
