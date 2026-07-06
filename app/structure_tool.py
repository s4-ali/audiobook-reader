"""Read-only page inspector the headless profiler (``app/structure.py``) can call.

    python -m app.structure_tool <source> page <N>       # one page: text + geometry
    python -m app.structure_tool <source> find "<text>"  # pages whose text contains <text>

Pages are 0-based. Output is plain text meant for the model to read. Kept tiny so it
loads fast when invoked repeatedly as a tool during a single profiling call.
"""
from __future__ import annotations

import sys

from . import structure, textproc


def main(argv=None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    if len(argv) < 2:
        print("usage: structure_tool <source> (page <N> | find <text>)")
        return 2
    source, cmd = argv[0], argv[1]
    try:
        raw_pages, geometry, _toc, _meta = structure.load_views(source)
    except Exception as e:  # noqa: BLE001 - surface any load error to the model as text
        print(f"error: {e}")
        return 1
    n = len(raw_pages)

    if cmd == "page":
        if len(argv) < 3 or not argv[2].lstrip("-").isdigit():
            print("usage: page <N>   (0-based page index)")
            return 2
        i = int(argv[2])
        if not (0 <= i < n):
            print(f"error: page {i} out of range 0..{n - 1}")
            return 1
        print(structure._page_view(i, raw_pages[i], geometry[i] if geometry else None, 4000))
        return 0

    if cmd == "find":
        q = " ".join(argv[2:]).strip()
        needle = textproc.normalize_for_match(q)
        if not needle:
            print("usage: find <text>")
            return 2
        hits = [i for i, t in enumerate(raw_pages)
                if needle in textproc.normalize_for_match(t)]
        if not hits:
            print(f"no pages contain {q!r}")
            return 0
        print(f"pages containing {q!r}: {hits}")
        for i in hits[:5]:
            snippet = " ".join(raw_pages[i].split())[:200]
            print(f"  p{i}: {snippet}")
        return 0

    print(f"unknown command {cmd!r} (use 'page' or 'find')")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
