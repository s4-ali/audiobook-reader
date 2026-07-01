"""Command-line management for the local audiobook library — list, inspect, diagnose,
export, and delete books without opening the web UI. A thin terminal front-end over the
same modules the server uses (``library``, ``export``, ``subtitles``, ``health``).

    python -m app.cli list
    python -m app.cli info <book-id>
    python -m app.cli doctor
    python -m app.cli export <book-id> [-o DIR]
    python -m app.cli transcript <book-id> [-o FILE]
    python -m app.cli subtitles <book-id> [--chapter N] [--format srt|vtt] [-o FILE]
    python -m app.cli delete <book-id> [--yes]
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

from . import config, export, health, library, subtitles


# --------------------------------------------------------------------- helpers
def _fmt_dur(sec) -> str:
    sec = int(round(sec or 0))
    h, rem = divmod(sec, 3600)
    m, s = divmod(rem, 60)
    return f"{h}:{m:02d}:{s:02d}" if h else f"{m}:{s:02d}"


def _trunc(s: str, n: int) -> str:
    s = str(s or "")
    return s if len(s) <= n else s[: n - 1] + "…"


def _table(headers, rows) -> None:
    srows = [[str(c) for c in r] for r in rows]
    widths = [len(h) for h in headers]
    for r in srows:
        for i, c in enumerate(r):
            widths[i] = max(widths[i], len(c))
    print("  ".join(h.ljust(widths[i]) for i, h in enumerate(headers)))
    print("  ".join("-" * widths[i] for i in range(len(headers))))
    for r in srows:
        print("  ".join(c.ljust(widths[i]) for i, c in enumerate(r)))


def _manifest(book_id: str):
    m = library.get_manifest(book_id)
    if not m:
        print(f"✗ No book with id '{book_id}' in {config.BOOKS_DIR}")
    return m


# ---------------------------------------------------------------- subcommands
def cmd_list(args) -> int:
    books = library.list_books()
    if not books:
        print(f"No books in {config.BOOKS_DIR}")
        return 0
    rows = [(b.get("status", "ready"), b["id"], _trunc(b.get("title", ""), 40),
             f"{b.get('chapters_ready', 0)}/{b.get('n_chapters', 0)}",
             _fmt_dur(b.get("duration", 0)), b.get("voice", "")) for b in books]
    _table(["STATUS", "ID", "TITLE", "CH", "DURATION", "VOICE"], rows)
    print(f"\n{len(books)} book(s) · {config.LIBRARY_DIR}")
    return 0


def cmd_info(args) -> int:
    m = _manifest(args.book_id)
    if not m:
        return 1
    chapters = m.get("chapters", [])
    print(f"{m.get('title', args.book_id)}")
    if m.get("author"):
        print(f"by {m['author']}")
    print(f"  id        {m.get('id', args.book_id)}")
    print(f"  status    {m.get('status', 'ready')}  "
          f"({m.get('chapters_ready', 0)}/{m.get('chapters_total', len(chapters))} chapters)")
    print(f"  duration  {_fmt_dur(m.get('total_duration', 0))}")
    print(f"  voice     {m.get('voice', '')}  ·  engine {m.get('engine', '')}  ·  "
          f"lang {m.get('lang', '')}  ·  speed {m.get('speed', '')}")
    print(f"  format    {m.get('audio_format', '')}  ·  {m.get('n_pages', '?')} pages  ·  "
          f"toc {m.get('toc_source', '?')}")
    if m.get("source_pdf"):
        print(f"  source    {m['source_pdf']}")
    if m.get("pronunciation_rules"):
        print(f"  pronounce {m['pronunciation_rules']} rule(s) applied")
    print()
    rows = []
    for ci, ch in enumerate(chapters):
        rows.append((ci + 1, ch.get("status", "ready"), _trunc(ch.get("title", ""), 44),
                     _fmt_dur(ch.get("duration", 0)),
                     len(ch.get("sentences", [])), len(ch.get("topics", []))))
    _table(["#", "STATUS", "TITLE", "DUR", "SENT", "TOP"], rows)
    return 0


def cmd_doctor(args) -> int:
    h = health.health_report()
    t, e, a = h["tools"], h["engines"], h["audio"]
    k, pr, lib = e["kokoro"], h["pronunciation"], h["library"]
    yn = lambda b: "✓" if b else "✗"
    print(f"Audiobook Reader {h['version']}  [{h['status'].upper()}]")
    print(f"  python     {h['python']} · {h['platform']}")
    print(f"  ffmpeg     {yn(t['ffmpeg']['available'])} {t['ffmpeg'].get('version') or 'not found'}")
    print(f"  espeak-ng  {yn(t['espeak_ng']['available'])} {t['espeak_ng'].get('path') or 'not found'}")
    print(f"  engine     default={e['default']} · dummy ✓ · kokoro {yn(k['available'])} "
          f"(torch={yn(k['torch'])} kokoro={yn(k['kokoro'])} device={k['device']} mps={k['mps_available']})")
    print(f"  audio      {a['configured_format']} → {a['effective_format']} "
          f"(q{a['mp3_quality']}, {a['sample_rate']}Hz)")
    print(f"  pronounce  {'enabled' if pr['enabled'] else 'off'} · {pr['file']}")
    print(f"  library    {lib['books']} book(s), {lib['generating']} generating · {lib['path']}")
    for w in h["warnings"]:
        print(f"  ⚠ {w}")
    return 0 if h["status"] == "ok" else 1


def cmd_export(args) -> int:
    try:
        path = export.package_book(args.book_id, out_dir=Path(args.output) if args.output else None)
    except (FileNotFoundError, ValueError) as ex:
        print(f"✗ {ex}")
        return 1
    print(f"✓ {path}  ({path.stat().st_size / (1024 * 1024):.1f} MB)")
    return 0


def cmd_transcript(args) -> int:
    m = _manifest(args.book_id)
    if not m:
        return 1
    text = subtitles.to_transcript(m)
    if args.output:
        Path(args.output).write_text(text, encoding="utf-8")
        print(f"✓ wrote {args.output}  ({len(text)} chars)")
    else:
        sys.stdout.write(text)
    return 0


def cmd_subtitles(args) -> int:
    m = _manifest(args.book_id)
    if not m:
        return 1
    chapters = m.get("chapters", [])
    if args.chapter is not None:
        ci = args.chapter - 1                      # CLI takes 1-based chapter numbers
        if ci < 0 or ci >= len(chapters):
            print(f"✗ Chapter {args.chapter} out of range (1..{len(chapters)})")
            return 1
        cues = subtitles.build_cues(m, chapter_index=ci)
    else:
        cues = subtitles.build_cues(m)
    if not cues:
        print("✗ No timed text available yet")
        return 1
    body = subtitles.to_vtt(cues) if args.format == "vtt" else subtitles.to_srt(cues)
    if args.output:
        Path(args.output).write_text(body, encoding="utf-8")
        print(f"✓ wrote {args.output}  ({len(cues)} cues)")
    else:
        sys.stdout.write(body)
    return 0


def cmd_delete(args) -> int:
    import shutil
    book_dir = config.BOOKS_DIR / args.book_id
    if not book_dir.exists():
        print(f"✗ No book with id '{args.book_id}'")
        return 1
    if not args.yes:
        m = library.get_manifest(args.book_id) or {}
        try:
            ans = input(f"Delete '{m.get('title', args.book_id)}' and its audio? [y/N] ")
        except EOFError:
            ans = ""
        if ans.strip().lower() not in ("y", "yes"):
            print("Aborted.")
            return 1
    shutil.rmtree(book_dir)
    print(f"✓ Deleted {args.book_id}")
    return 0


def main(argv=None) -> int:
    p = argparse.ArgumentParser(prog="app.cli", description="Manage the local audiobook library.")
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("list", help="list all books").set_defaults(func=cmd_list)

    sp = sub.add_parser("info", help="show details for one book")
    sp.add_argument("book_id")
    sp.set_defaults(func=cmd_info)

    sub.add_parser("doctor", help="environment + dependency diagnostics").set_defaults(func=cmd_doctor)

    sp = sub.add_parser("export", help="package a 'ready' book into a .abk")
    sp.add_argument("book_id")
    sp.add_argument("-o", "--output", help="output directory (default: cwd)")
    sp.set_defaults(func=cmd_export)

    sp = sub.add_parser("transcript", help="write a plain-text transcript (stdout or -o FILE)")
    sp.add_argument("book_id")
    sp.add_argument("-o", "--output")
    sp.set_defaults(func=cmd_transcript)

    sp = sub.add_parser("subtitles", help="write .srt/.vtt subtitles (stdout or -o FILE)")
    sp.add_argument("book_id")
    sp.add_argument("--chapter", type=int, help="a single chapter (1-based); default: whole book")
    sp.add_argument("--format", choices=["srt", "vtt"], default="srt")
    sp.add_argument("-o", "--output")
    sp.set_defaults(func=cmd_subtitles)

    sp = sub.add_parser("delete", help="delete a book and its audio")
    sp.add_argument("book_id")
    sp.add_argument("--yes", action="store_true", help="skip the confirmation prompt")
    sp.set_defaults(func=cmd_delete)

    args = p.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
