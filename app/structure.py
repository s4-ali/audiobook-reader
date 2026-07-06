"""LLM-assisted book structure parsing.

A headless ``claude -p`` call runs **once per book** on a small page *sample* (never the
whole book) and returns a :class:`StructureProfile` — cleaning rules plus a corrected
chapter list. Deterministic code here then applies that profile to every page. The model
returns *rules*, never cleaned prose, so the expensive per-page work stays in fast Python
and the token cost is one bounded call per book (cached by source-content hash).

Any failure — no ``claude`` on PATH, timeout, bad JSON — yields the :data:`HEURISTIC`
sentinel, and callers fall back to the existing heuristics. This is always safe to enable.

The profile shape (all fields optional)::

    {
      "cleaning": {
        "drop_line_patterns": ["(?i)^oceanofpdf\\.com$"],  # regex, matched per line
        "drop_substrings": ["OceanofPDF.com"],             # strip from within a line
        "fix_letter_spacing": true,                        # "T H E" -> "THE"
        "drop_decorative": true,                           # ". . .", "* * *"
        "strip_page_numbers": true,
        "header_zone_max_y": 60, "footer_zone_min_y": 940  # 0..1000 top-relative (PDF)
      },
      "heading_labels": {"patterns": ["^CHAPTER\\s+\\d+$"], "strip_repeated_title": true},
      "skip_sections": {"titles": ["Cover", "Contents", "Index"], "page_ranges": [[0,1]]},
      "structure": {"toc": "trust|correct|derive",
                    "markers": [{"level":1,"title":"...","page":27}],
                    "heading_pattern": "^[A-Z][A-Z ]{3,40}$"}
    }
"""
from __future__ import annotations

import hashlib
import json
import re
import shutil
import subprocess
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Dict, List, Optional, Tuple

from . import config, textproc
from .extract import Marker

SCHEMA_VERSION = 1

# Normalized TOC entry as passed around here: (level, title, page0based).
TocEntry = Tuple[int, str, int]


# ---------------------------------------------------------------------------
# Profile
# ---------------------------------------------------------------------------

@dataclass
class StructureProfile:
    cleaning: dict = field(default_factory=dict)
    heading_labels: dict = field(default_factory=dict)
    skip_sections: dict = field(default_factory=dict)
    structure: dict = field(default_factory=lambda: {"toc": "trust"})
    source: str = "llm"

    @property
    def is_llm(self) -> bool:
        return self.source == "llm"

    def to_json(self) -> dict:
        return {"version": SCHEMA_VERSION, "source": self.source,
                "cleaning": self.cleaning, "heading_labels": self.heading_labels,
                "skip_sections": self.skip_sections, "structure": self.structure}

    @classmethod
    def from_json(cls, d: dict) -> "StructureProfile":
        st = dict(d.get("structure") or {})
        st.setdefault("toc", "trust")
        return cls(
            cleaning=dict(d.get("cleaning") or {}),
            heading_labels=dict(d.get("heading_labels") or {}),
            skip_sections=dict(d.get("skip_sections") or {}),
            structure=st,
            source=d.get("source", "llm"),
        )


# Sentinel: "no profile — use the existing heuristics". Never cached.
HEURISTIC = StructureProfile(structure={"toc": "trust"}, source="heuristic")


# ---------------------------------------------------------------------------
# Enablement
# ---------------------------------------------------------------------------

def _claude_bin() -> Optional[str]:
    return shutil.which("claude")


def enabled(smart_parse: Optional[bool] = None) -> bool:
    """Resolve whether to run the LLM profiler.

    ``smart_parse`` (from a CLI flag) overrides config when not ``None``; otherwise the
    ``STRUCTURE_LLM`` setting decides (``auto`` = on iff the ``claude`` CLI is present).
    """
    if smart_parse is False:
        return False
    setting = config.STRUCTURE_LLM
    if smart_parse is True:
        want = True
    elif setting in ("0", "off", "false", "no"):
        return False
    elif setting in ("1", "on", "true", "yes"):
        want = True
    else:  # "auto"
        want = True
    return want and _claude_bin() is not None


# ---------------------------------------------------------------------------
# Source views (used by the standalone inspector tool, app/structure_tool.py)
# ---------------------------------------------------------------------------

def pdf_line_geometry(page) -> List[dict]:
    """Per-line geometry for one PyMuPDF page: y normalized 0 (top)..1000 (bottom)."""
    height = float(page.rect.height) or 1.0
    out: List[dict] = []
    d = page.get_text("dict")
    for block in d.get("blocks", []):
        for line in block.get("lines", []):
            spans = line.get("spans", [])
            txt = "".join(s.get("text", "") for s in spans).strip()
            if not txt:
                continue
            size = max((s.get("size", 0.0) for s in spans), default=0.0)
            bold = any("bold" in (s.get("font", "").lower()) for s in spans)
            y0 = line.get("bbox", (0, 0, 0, 0))[1]
            out.append({"y": int(max(0, min(1000, y0 / height * 1000))),
                        "size": round(float(size), 1), "bold": bool(txt and bold),
                        "text": txt})
    return out


def load_views(path: str | Path):
    """Load a source into (raw_pages, geometry, toc, meta) — for the inspector tool.

    Mirrors what the extractors feed to :func:`profile_book` so the model sees the same
    page formatting whether a page comes from the seed sample or an on-demand lookup.
    """
    path = Path(path)
    ext = path.suffix.lower()
    if ext == ".pdf":
        import fitz  # PyMuPDF
        doc = fitz.open(path)
        raw_pages = [doc.load_page(i).get_text("text") for i in range(doc.page_count)]
        geometry = [pdf_line_geometry(doc.load_page(i)) for i in range(doc.page_count)]
        toc = [(max(1, int(l)), (t or "").strip(), max(0, p - 1))
               for l, t, p in (doc.get_toc(simple=True) or []) if (t or "").strip()]
        meta = {"title": (doc.metadata or {}).get("title") or path.stem,
                "author": (doc.metadata or {}).get("author") or "",
                "ext": "pdf", "n_pages": doc.page_count}
        doc.close()
        return raw_pages, geometry, toc, meta
    if ext == ".epub":
        from . import epub_extract
        book, raw_pages, name_to_index, meta = epub_extract.load_spine(path)
        toc = epub_extract.toc_entries(book, name_to_index)
        return raw_pages, None, toc, meta
    raise ValueError(f"Unsupported file type {ext!r}")


# ---------------------------------------------------------------------------
# Sample building (deterministic; keeps the token budget bounded)
# ---------------------------------------------------------------------------

def _sample_indices(n: int, toc: List[TocEntry]) -> List[int]:
    idx = set(range(min(6, n)))                      # front matter
    for lvl, _title, page in toc:
        if lvl == 1 and 0 <= page < n and len(idx) < 6 + 8:
            idx.add(page)                            # how each chapter starts
    mid = n // 2
    for d in (-1, 0, 1):                             # steady-state body
        if 0 <= mid + d < n:
            idx.add(mid + d)
    idx.update(range(max(0, n - 3), n))              # back matter
    return sorted(i for i in idx if 0 <= i < n)


def _page_view(idx: int, raw_text: str, geo: Optional[List[dict]], body_cap: int) -> str:
    body = raw_text.strip()
    if len(body) > body_cap:
        body = body[:body_cap] + " …[truncated]"
    parts = [f"--- PAGE {idx} ---"]
    if geo:
        def fmt(l):
            return f"  [y{l['y']:03d} s{l['size']:04.1f}{'B' if l['bold'] else ' '}] {l['text']}"
        head, tail = geo[:4], geo[-4:]
        parts.append("TOP:")
        parts += [fmt(l) for l in head]
        if len(geo) > 4:
            parts.append("BOTTOM:")
            parts += [fmt(l) for l in tail]
    parts.append("TEXT:")
    parts.append(body)
    return "\n".join(parts)


def build_sample(raw_pages: List[str], geometry: Optional[List[List[dict]]],
                 toc: List[TocEntry], meta: dict) -> str:
    n = len(raw_pages)
    lines = [
        f"BOOK: {meta.get('title', '?')} by {meta.get('author') or 'unknown'}"
        f"  ({meta.get('ext', '?')}, {n} pages)",
        "",
        "EMBEDDED TABLE OF CONTENTS (as extracted — may be wrong or empty):",
    ]
    if toc:
        for lvl, title, page in toc:
            lines.append(f"  {'  ' * max(0, lvl - 1)}[p{page}] {title}")
    else:
        lines.append("  (none)")
    lines.append("")

    indices = _sample_indices(n, toc)
    # Front matter + chapter-start pages are the most valuable; fill them first, then
    # spend whatever budget remains on body/back-matter pages.
    priority = [i for i in indices if i < 6 or any(l == 1 and p == i for l, _t, p in toc)]
    rest = [i for i in indices if i not in priority]
    budget = config.STRUCTURE_SAMPLE_BUDGET
    used = sum(len(x) for x in lines)
    views: Dict[int, str] = {}
    for i in priority + rest:
        cap = 1800 if i in priority else 1000
        v = _page_view(i, raw_pages[i], geometry[i] if geometry else None, cap)
        if used + len(v) > budget and views:
            continue
        views[i] = v
        used += len(v)
    for i in sorted(views):
        lines.append(views[i])
        lines.append("")
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# The headless call
# ---------------------------------------------------------------------------

_INSTRUCTIONS = """You analyze a book's extracted text and output a STRUCTURE PROFILE (JSON) \
that a deterministic script applies to clean the book for text-to-speech narration.

You are given the embedded table of contents (possibly wrong/empty) and a SAMPLE of pages \
(NOT the whole book). For PDFs each page lists its TOP and BOTTOM lines with geometry — y \
is vertical position 0=top..1000=bottom, s is font size, B=bold — then the page TEXT. Use \
geometry to recognize running headers/footers.

Identify everything that must NOT be narrated as prose, and fix the chapter structure:
- running headers/footers repeated across pages (book title, chapter title, author);
- page numbers; watermarks appended to lines (e.g. "OceanofPDF.com");
- letter-spacing artifacts like "T H E  T I P P I N G"; decorative separators (". . .", "* * *");
- chapter heading LABELS read aloud ("CHAPTER 1", "THE NEW RULES");
- non-narratable sections (Cover, Contents, Copyright, Dedication, Index, About the Author);
- whether the table of contents is correct, needs correcting, or must be derived.

If the sample is ambiguous you MAY inspect more pages (0-based index) by running:
    {tool} page <N>
    {tool} find "<text>"

Output ONLY a JSON object — no prose, no markdown fences — with this shape (all keys optional):
{schema}

Rules:
- drop_line_patterns are Python regexes matched with re.search against each stripped line; \
anchor with ^...$ so you don't nuke body text. Make header patterns tolerant of OCR drift \
and letter-spacing (use \\s* between letters).
- header_zone_max_y / footer_zone_min_y are 0..1000 top-relative bands (PDF only); set them \
only when headers/footers sit in a consistent band.
- skip_sections.titles should exactly match TOC / heading titles.
- structure.toc = "trust" if the embedded TOC chapter entries are right; "correct" with \
markers[] (level/title/page, 0-based) to fix titles or drop non-chapters; "derive" with a \
heading_pattern when there is no usable TOC.
- Be conservative: add a rule only when the sample clearly supports it.

SAMPLE FOLLOWS:
"""

_SCHEMA_HINT = """{
  "cleaning": {"drop_line_patterns": ["..."], "drop_substrings": ["..."],
               "fix_letter_spacing": true, "drop_decorative": true, "strip_page_numbers": true,
               "header_zone_max_y": 60, "footer_zone_min_y": 940},
  "heading_labels": {"patterns": ["^CHAPTER\\\\s+\\\\d+$"], "strip_repeated_title": true},
  "skip_sections": {"titles": ["Cover", "Contents", "Index"], "page_ranges": [[0, 1]]},
  "structure": {"toc": "trust", "markers": [{"level": 1, "title": "...", "page": 0}],
                "heading_pattern": "^[A-Z][A-Z ]{3,40}$"}
}"""


def _run_claude(prompt: str, source_path: Path) -> Optional[str]:
    """Invoke headless ``claude -p``; return the model's text (``.result``) or None."""
    claude = _claude_bin()
    if not claude:
        return None
    venv_py = Path(config.ROOT) / ".venv" / "bin" / "python"
    tool_prefix = f"{venv_py} -m app.structure_tool {source_path}"
    cmd = [claude, "-p", prompt, "--output-format", "json",
           "--allowedTools", f"Bash({tool_prefix} *)",
           "--disallowedTools", "Read Write Edit WebFetch WebSearch"]
    if config.STRUCTURE_MODEL:
        cmd += ["--model", config.STRUCTURE_MODEL]
    try:
        proc = subprocess.run(cmd, cwd=str(config.ROOT), capture_output=True, text=True,
                              timeout=config.STRUCTURE_TIMEOUT)
    except (subprocess.TimeoutExpired, OSError):
        return None
    if proc.returncode != 0:
        return None
    try:
        env = json.loads(proc.stdout)
    except json.JSONDecodeError:
        return None
    if env.get("is_error"):
        return None
    return env.get("result")


def _parse_profile(text: Optional[str]) -> StructureProfile:
    if not text:
        return HEURISTIC
    s = text.strip()
    # Tolerate accidental ```json fences or leading prose before the object.
    if "```" in s:
        m = re.search(r"```(?:json)?\s*(.*?)```", s, re.DOTALL)
        if m:
            s = m.group(1).strip()
    if not s.startswith("{"):
        i = s.find("{")
        if i < 0:
            return HEURISTIC
        s = s[i:]
    try:
        data = json.loads(s)
    except json.JSONDecodeError:
        # Last resort: grab the outermost {...} span.
        try:
            data = json.loads(s[: s.rindex("}") + 1])
        except (json.JSONDecodeError, ValueError):
            return HEURISTIC
    if not isinstance(data, dict):
        return HEURISTIC
    prof = StructureProfile.from_json(data)
    prof.source = "llm"
    return prof


# ---------------------------------------------------------------------------
# Caching (by source-content hash)
# ---------------------------------------------------------------------------

def _cache_key(source_path: Path) -> str:
    h = hashlib.sha1()
    h.update(f"v{SCHEMA_VERSION}:{config.STRUCTURE_MODEL}:".encode())
    try:
        h.update(source_path.read_bytes())
    except OSError:
        h.update(str(source_path).encode())
    return h.hexdigest()


def _cache_path(key: str) -> Path:
    return config.STRUCTURE_CACHE_DIR / f"{key}.json"


def _cache_load(key: str) -> Optional[StructureProfile]:
    p = _cache_path(key)
    if not p.exists():
        return None
    try:
        return StructureProfile.from_json(json.loads(p.read_text(encoding="utf-8")))
    except (OSError, json.JSONDecodeError):
        return None


def _cache_store(key: str, prof: StructureProfile) -> None:
    try:
        config.STRUCTURE_CACHE_DIR.mkdir(parents=True, exist_ok=True)
        _cache_path(key).write_text(json.dumps(prof.to_json(), ensure_ascii=False, indent=1),
                                    encoding="utf-8")
    except OSError:
        pass


def profile_book(source_path: str | Path, raw_pages: List[str],
                 geometry: Optional[List[List[dict]]], toc: List[TocEntry], meta: dict,
                 *, reprofile: bool = False) -> StructureProfile:
    """Return a StructureProfile for the book, or :data:`HEURISTIC` on any failure."""
    source_path = Path(source_path)
    if not raw_pages:
        return HEURISTIC
    key = _cache_key(source_path)
    if not reprofile:
        cached = _cache_load(key)
        if cached is not None:
            return cached
    prompt = (_INSTRUCTIONS.format(tool=f".venv/bin/python -m app.structure_tool {source_path}",
                                   schema=_SCHEMA_HINT)
              + "\n" + build_sample(raw_pages, geometry, toc, meta))
    prof = _parse_profile(_run_claude(prompt, source_path))
    if prof.is_llm:
        _cache_store(key, prof)
    return prof


# ---------------------------------------------------------------------------
# Applying the profile — cleaning
# ---------------------------------------------------------------------------

_LETTER_RUN = re.compile(r"(?:\b[^\W\d_]\b ){2,}\b[^\W\d_]\b")
_DECORATIVE = re.compile(r"^[.•·*_=~\-–—\s]{2,}$")


def _collapse_letter_spacing(line: str) -> str:
    return _LETTER_RUN.sub(lambda m: m.group(0).replace(" ", ""), line)


def _zone_drop_set(geo: Optional[List[dict]], cl: dict) -> set:
    hmax, fmin = cl.get("header_zone_max_y"), cl.get("footer_zone_min_y")
    if not geo or (hmax is None and fmin is None):
        return set()
    out = set()
    for l in geo:
        y = l["y"]
        if (hmax is not None and y <= hmax) or (fmin is not None and y >= fmin):
            k = textproc.normalize_for_match(l["text"])
            if k:
                out.add(k)
    return out


def _clean_page(raw: str, geo: Optional[List[dict]], cl: dict) -> str:
    """Clean one page under the profile's cleaning rules (mirrors textproc.clean_page)."""
    raw = textproc._dehyphenate(textproc.normalize_unicode(raw))
    patterns = [re.compile(p) for p in cl.get("drop_line_patterns", []) if _safe_re(p)]
    substrings = cl.get("drop_substrings", []) or []
    zone = _zone_drop_set(geo, cl)
    fix_spacing = cl.get("fix_letter_spacing", False)
    decorative = cl.get("drop_decorative", False)
    strip_nums = cl.get("strip_page_numbers", True)

    kept: List[str] = []
    for ln in raw.splitlines():
        s = ln.strip()
        if not s:
            kept.append("")
            continue
        for sub in substrings:
            if sub:
                s = s.replace(sub, " ")
        s = re.sub(r"[ \t]+", " ", s).strip()
        if not s:
            continue
        if decorative and _DECORATIVE.match(s):
            continue
        if strip_nums and textproc._PAGE_NUM_RE.match(s):
            continue
        if any(p.search(s) for p in patterns):
            continue
        if zone and textproc.normalize_for_match(s) in zone:
            continue
        if fix_spacing:
            s = _collapse_letter_spacing(s)
        kept.append(s)

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


def _safe_re(pattern: str) -> bool:
    try:
        re.compile(pattern)
        return True
    except re.error:
        return False


def apply_cleaning(raw_pages: List[str], geometry: Optional[List[List[dict]]],
                   profile: StructureProfile) -> List[str]:
    cl = dict(profile.cleaning or {})
    # Heading-label patterns ("CHAPTER 1", "ONE", roman numerals) are structural labels,
    # never descriptive prose, so drop them everywhere — not just at chapter starts. Doing
    # it here (before offsets) keeps timings aligned and catches labels that the segmenter
    # would otherwise leave stranded at the end of the previous chapter.
    labels = (profile.heading_labels or {}).get("patterns") or []
    if labels:
        cl["drop_line_patterns"] = list(cl.get("drop_line_patterns", [])) + list(labels)
    geo = geometry or [None] * len(raw_pages)
    return [_clean_page(raw_pages[i], geo[i], cl) for i in range(len(raw_pages))]


# ---------------------------------------------------------------------------
# Applying the profile — structure (markers)
# ---------------------------------------------------------------------------

def _find_page(pages: List[str], title: str) -> int:
    want = textproc.normalize_for_match(title)
    if want:
        for i, text in enumerate(pages):
            if want[:40] in textproc.normalize_for_match(text):
                return i
    return 0


def _scan_headings(pages: List[str], pattern: str) -> List[Tuple[int, str, int]]:
    if not pattern or not _safe_re(pattern):
        return []
    rx = re.compile(pattern)
    out: List[Tuple[int, str, int]] = []
    for pi, text in enumerate(pages):
        for para in text.split("\n"):
            s = para.strip()
            if s and 2 <= len(s) <= 90 and rx.search(s):
                out.append((1, s, pi))
    return out


def build_markers(profile: StructureProfile, pages: List[str], page_offsets: List[int],
                  locate: Callable[[str, int], int]) -> Optional[List[Marker]]:
    """Markers from the profile, or ``None`` to keep the caller's embedded TOC ("trust").

    ``locate(title, page)`` -> char offset into linear_text (format-specific; reuses the
    extractor's existing offset helpers).
    """
    st = profile.structure or {}
    mode = st.get("toc", "trust")
    if mode == "trust":
        return None

    items: List[Tuple[int, str, Optional[int]]] = []
    if mode == "correct":
        for m in st.get("markers", []) or []:
            title = (m.get("title") or "").strip()
            if title:
                items.append((max(1, int(m.get("level", 1))), title, m.get("page")))
    elif mode == "derive":
        items = [(l, t, p) for l, t, p in _scan_headings(pages, st.get("heading_pattern", ""))]
    if not items:
        return None

    markers: List[Marker] = []
    for level, title, page in items:
        if page is None or not (0 <= page < len(pages)):
            page = _find_page(pages, title)
        markers.append(Marker(level=level, title=title, page=page,
                              offset=locate(title, page)))
    markers.sort(key=lambda m: m.offset)
    if mode == "derive":
        # Pattern scanning can double-hit a repeated heading; drop near-duplicates.
        # (A curated "correct" list is trusted verbatim — no dedup there.)
        deduped: List[Marker] = []
        for m in markers:
            if deduped and abs(m.offset - deduped[-1].offset) < 200:
                continue
            deduped.append(m)
        markers = deduped
    return markers or None


# ---------------------------------------------------------------------------
# Applying the profile — heading-label stripping + section skipping (used by ingest)
# ---------------------------------------------------------------------------

def _title_matches(title: str, wanted: List[str]) -> bool:
    t = textproc.normalize_for_match(title)
    if not t:
        return False
    for w in wanted:
        nw = textproc.normalize_for_match(w)
        if not nw:
            continue
        # Exact, or a long-enough phrase contained in the title. The length guard keeps
        # short words ("index") from nuking real chapters ("index of terms").
        if t == nw or (len(nw) >= 6 and nw in t):
            return True
    return False


def should_skip_section(profile: StructureProfile, title: str, page: int) -> bool:
    ss = profile.skip_sections or {}
    if _title_matches(title, ss.get("titles", []) or []):
        return True
    for rng in ss.get("page_ranges", []) or []:
        try:
            lo, hi = int(rng[0]), int(rng[1])
        except (TypeError, ValueError, IndexError):
            continue
        if lo <= page <= hi:
            return True
    return False


def strip_heading_labels(profile: StructureProfile, text: str, title: str) -> int:
    """How many leading chars of a chapter body are heading LABELS to drop from narration.

    Returns a char count; the caller trims ``text[:n]`` and advances the chapter's start
    offset by ``n`` so downstream timings/offsets stay aligned. Only leading label-like
    paragraphs are considered (the chapter title, "CHAPTER 1", roman numerals, etc.).
    """
    hl = profile.heading_labels or {}
    patterns = [re.compile(p) for p in hl.get("patterns", []) if _safe_re(p)]
    # Stripping a leading paragraph that IS the chapter title (or a label) is always safe,
    # so it isn't gated on the LLM's strip_repeated_title hint — that flag only ever means
    # "yes, do this", and omitting it shouldn't leave the title narrated.
    ntitle = textproc.normalize_for_match(title) if title else ""
    if not patterns and not ntitle:
        return 0

    # (1) Drop leading standalone label / exact-title paragraphs.
    cut = 0
    checked = 0
    while checked < 3:  # only the first few short paragraphs can be labels
        rest = text[cut:]
        m = re.match(r"\s*([^\n]+?)\s*(?:\n\n|\n|$)", rest)
        if not m:
            break
        para = m.group(1).strip()
        if not para or len(para) > 90:
            break
        is_label = any(p.search(para) for p in patterns)
        if not is_label and ntitle:
            np = textproc.normalize_for_match(para)
            is_label = np == ntitle or (len(ntitle) >= 4 and np in ntitle)
        if not is_label:
            break
        cut += m.end()
        checked += 1

    # (2) Strip a verbatim title still glued to the first body paragraph — e.g. a drop-cap
    # merges "The Three Rules of Epidemics" into "The Three Rules of Epidemics n the mid-…".
    # Normalize the title's unicode (curly quotes, dashes, ligatures) so it compares against
    # the already-normalized body — otherwise "Author's Note" (curly) misses its body copy.
    tl = textproc.normalize_unicode((title or "").strip())
    if tl and len(tl) >= 4:
        rest = text[cut:]
        lead = len(rest) - len(rest.lstrip())
        body = rest[lead:]
        if len(body) > len(tl) and body[:len(tl)].lower() == tl.lower():
            after = body[len(tl):]
            if after[:1] in (" ", "\n", "\t", ".", ",", ":", ";", "-"):
                cut += lead + len(tl)
                while cut < len(text) and text[cut] in " \n\t.,:;-":
                    cut += 1

    # (3) A drop cap can weld an ALL-CAPS chapter subtitle to the body:
    # "CONNECTORS , MAVENS , AND SALESMEN n the afternoon…". Strip the leading caps run
    # only when it is followed by the tell-tale lone drop-cap letter ("n the") — a shape
    # real prose never starts with, so this stays safe without a per-book rule.
    if ntitle:
        rest = text[cut:]
        lead = len(rest) - len(rest.lstrip())
        para = rest[lead:].split("\n", 1)[0]
        consumed = caps_words = last_end = 0
        for tok in para.split(" "):
            letters = re.sub(r"[^A-Za-z]", "", tok)
            if letters and tok == tok.upper() and len(letters) >= 2:     # ALL-CAPS word
                caps_words += 1
                consumed += len(tok) + 1
                last_end = consumed
            elif tok and not re.search(r"[A-Za-z]", tok):                # punctuation only
                consumed += len(tok) + 1
            else:
                break
        if caps_words >= 2 and re.match(r"[a-z]\s", para[last_end:]):
            cut += lead + last_end
            while cut < len(text) and text[cut] in " \n\t":
                cut += 1
    return cut
