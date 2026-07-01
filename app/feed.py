"""Expose each audiobook as a podcast RSS feed (chapters = serial episodes), so it can be
subscribed to in any podcast app over the LAN — gaining native offline download, variable
speed and resume for free. Enclosure URLs point at the very same ``/media/<id>/<audio>``
files the web player streams, so nothing is duplicated on disk.
"""
from __future__ import annotations

import struct
import zlib
from datetime import datetime
from email.utils import formatdate
from typing import Optional
from xml.sax.saxutils import escape, quoteattr

from . import config


def _ready(ch: dict) -> bool:
    return ch.get("status", "ready") == "ready"


def _base_ts(manifest: dict) -> float:
    try:
        return datetime.fromisoformat(manifest.get("created") or "").timestamp()
    except Exception:
        return 0.0


def _mime(audio: str) -> str:
    return "audio/mpeg" if audio.lower().endswith(".mp3") else "audio/wav"


def _dur(sec) -> str:
    sec = int(round(sec or 0))
    h, rem = divmod(sec, 3600)
    m, s = divmod(rem, 60)
    return f"{h:d}:{m:02d}:{s:02d}" if h else f"{m:d}:{s:02d}"


def build_feed(manifest: dict, base_url: str, book_id: str) -> str:
    base = base_url.rstrip("/")
    title = manifest.get("title") or book_id
    author = manifest.get("author") or "Audiobook Reader"
    book_dir = config.BOOKS_DIR / book_id
    base_ts = _base_ts(manifest)
    self_url = f"{base}/api/books/{book_id}/feed.xml"
    cover_url = f"{base}/api/books/{book_id}/cover.png"
    desc = f"{title} by {author} — narrated locally with Kokoro-82M."

    items = []
    n = 0
    for ci, ch in enumerate(manifest.get("chapters", [])):
        if not _ready(ch) or not ch.get("audio"):
            continue
        n += 1
        audio = ch["audio"]
        try:
            length = (book_dir / audio).stat().st_size
        except OSError:
            length = 0
        ep_url = f"{base}/media/{book_id}/{audio}"
        # Ascending pubDate (ch1 earliest) + serial type → podcast apps present in order.
        pub = formatdate((base_ts + ci * 60) if base_ts else None, usegmt=True)
        guid = f"{book_id}-{ch.get('id', ci)}"
        items.append(
            "    <item>\n"
            f"      <title>{escape(ch.get('title') or f'Chapter {ci + 1}')}</title>\n"
            f"      <itunes:episode>{n}</itunes:episode>\n"
            "      <itunes:episodeType>serial</itunes:episodeType>\n"
            f"      <enclosure url={quoteattr(ep_url)} length=\"{length}\" type=\"{_mime(audio)}\"/>\n"
            f"      <guid isPermaLink=\"false\">{escape(guid)}</guid>\n"
            f"      <pubDate>{pub}</pubDate>\n"
            f"      <itunes:duration>{_dur(ch.get('duration', 0))}</itunes:duration>\n"
            f"      <itunes:author>{escape(author)}</itunes:author>\n"
            "    </item>"
        )

    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd" '
        'xmlns:atom="http://www.w3.org/2005/Atom">\n'
        "  <channel>\n"
        f"    <title>{escape(title)}</title>\n"
        f"    <link>{escape(base)}</link>\n"
        f"    <atom:link href={quoteattr(self_url)} rel=\"self\" type=\"application/rss+xml\"/>\n"
        "    <language>en</language>\n"
        f"    <itunes:author>{escape(author)}</itunes:author>\n"
        f"    <description>{escape(desc)}</description>\n"
        f"    <itunes:summary>{escape(desc)}</itunes:summary>\n"
        "    <itunes:explicit>false</itunes:explicit>\n"
        f"    <itunes:image href={quoteattr(cover_url)}/>\n"
        f"    <image><url>{escape(cover_url)}</url><title>{escape(title)}</title>"
        f"<link>{escape(base)}</link></image>\n"
        '    <itunes:category text="Books"/>\n'
        + "\n".join(items) + "\n"
        "  </channel>\n"
        "</rss>\n"
    )


# --- Dependency-free cover PNG (solid accent square) so picky apps accept the feed ----
def _png_solid(w: int, h: int, rgb) -> bytes:
    row = b"\x00" + bytes(rgb) * w           # filter byte 0 + W RGB pixels
    comp = zlib.compress(row * h, 9)

    def chunk(typ: bytes, data: bytes) -> bytes:
        return (struct.pack(">I", len(data)) + typ + data
                + struct.pack(">I", zlib.crc32(typ + data) & 0xFFFFFFFF))

    sig = b"\x89PNG\r\n\x1a\n"
    ihdr = struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)   # 8-bit, color type 2 (RGB)
    return sig + chunk(b"IHDR", ihdr) + chunk(b"IDAT", comp) + chunk(b"IEND", b"")


def cover_png(manifest: Optional[dict] = None) -> bytes:
    return _png_solid(600, 600, (203, 166, 247))          # Catppuccin mauve
