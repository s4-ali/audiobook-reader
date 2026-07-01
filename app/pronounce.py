"""User pronunciation dictionary: substitutions applied to the *spoken* text just
before TTS, so names and jargon are narrated correctly. The on-screen text and all
timings/search keep the original words — only the audio uses the replacement.

The dictionary lives at ``$PRONUNCIATION_FILE`` (default ``library/pronunciation.json``)
and is optional: with no file (the default) this is a no-op. Two formats are accepted:

    { "Kokoro": "koh koh roh", "TTS": "T T S", "naive": "nigh-eve" }

    [ {"from": "Dr\\.", "to": "Doctor", "regex": true},
      {"from": "GPT-4", "to": "G P T four"} ]

Object keys match whole words, case-insensitively (longer keys first, so ``GPT`` doesn't
pre-empt ``GPT-4``). List rules add per-rule control (``regex``, ``ignore_case``,
``whole_word``); a regex rule's ``to`` may use backreferences. ``//`` and ``#`` full-line
comments are tolerated so the file can be self-documenting.
"""
from __future__ import annotations

import json
import re
from pathlib import Path
from typing import List, Optional, Pattern, Tuple

from . import config

# (compiled pattern, replacement, is_literal). Literal rules substitute the replacement
# verbatim (no backslash/backref interpretation); regex rules treat it as a template.
Rule = Tuple[Pattern, str, bool]

_cache: dict = {}   # str(path) -> (mtime, rules)


def _strip_comments(raw: str) -> str:
    return "\n".join(ln for ln in raw.splitlines()
                     if not ln.lstrip().startswith(("//", "#")))


def _boundaryize(key: str, whole_word: bool) -> str:
    pat = re.escape(key)
    if not whole_word:
        return pat
    left = r"(?<!\w)" if re.match(r"\w", key) else ""
    right = r"(?!\w)" if re.search(r"\w\Z", key) else ""
    return left + pat + right


def _compile(frm: str, to: str, *, regex: bool, ignore_case: bool,
             whole_word: bool) -> Optional[Rule]:
    flags = re.IGNORECASE if ignore_case else 0
    try:
        pattern = frm if regex else _boundaryize(frm, whole_word)
        return (re.compile(pattern, flags), to, not regex)
    except re.error:
        return None


def _rules_from_data(data) -> List[Rule]:
    rules: List[Rule] = []
    if isinstance(data, dict):
        for k in sorted((k for k in data if k), key=len, reverse=True):
            r = _compile(str(k), str(data[k]), regex=False, ignore_case=True, whole_word=True)
            if r:
                rules.append(r)
    elif isinstance(data, list):
        for item in data:
            if not isinstance(item, dict) or not item.get("from"):
                continue
            r = _compile(str(item["from"]), str(item.get("to", "")),
                         regex=bool(item.get("regex", False)),
                         ignore_case=bool(item.get("ignore_case", True)),
                         whole_word=bool(item.get("whole_word", True)))
            if r:
                rules.append(r)
    return rules


def load_rules(path: Optional[Path] = None) -> List[Rule]:
    """Load + compile the pronunciation rules (cached by file mtime). ``[]`` if no file."""
    p = Path(path) if path else config.PRONUNCIATION_FILE
    try:
        mtime = p.stat().st_mtime
    except OSError:
        return []
    cached = _cache.get(str(p))
    if cached and cached[0] == mtime:
        return cached[1]
    try:
        data = json.loads(_strip_comments(p.read_text(encoding="utf-8")))
    except Exception:
        return []
    rules = _rules_from_data(data)
    _cache[str(p)] = (mtime, rules)
    return rules


def apply(text: str, rules: Optional[List[Rule]]) -> str:
    """Apply the rules in order, returning the spoken form of ``text``."""
    if not rules or not text:
        return text
    for pattern, repl, literal in rules:
        text = pattern.sub((lambda m, r=repl: r) if literal else repl, text)
    return text


def spoken(text: str, rules: Optional[List[Rule]] = None) -> str:
    """Convenience: the text as it should be spoken (default dictionary applied)."""
    return apply(text, load_rules() if rules is None else rules)
