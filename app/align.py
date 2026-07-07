"""Forced alignment: recover per-sentence timings from continuously-synthesized audio.

The Voxtral render path (``app/ingest.py``) synthesizes a whole paragraph in one call so
prosody flows across sentence boundaries (fixing the "every sentence is a different note"
problem). But the manifest still needs per-sentence ``s``/``e`` timings for karaoke
highlighting + click-to-seek. This module recovers them by *forced alignment*: given the
audio and the exact known text, find when each word was spoken.

It uses torchaudio's multilingual MMS_FA CTC aligner, which ships with the torch/kokoro
stack already installed (the ~300 MB model downloads once on first use). Everything here is
best-effort: any failure returns ``None`` and the caller falls back to per-sentence synth.
"""
from __future__ import annotations

import importlib.util
import re
import threading
from typing import List, Optional, Tuple

import numpy as np

_model = None
_tokenizer = None
_aligner = None
_bundle_sr = 16000
_load_failed = False
_load_lock = threading.Lock()   # the server can run concurrent Voxtral ingests

# The aligner alphabet is lowercase latin; strip everything else for the alignment pass.
# (The manifest keeps the original sentence text; this normalized form is only used to
# place known words in time.)
_NONWORD = re.compile(r"[^a-z' ]+")


def available() -> bool:
    """True if the forced-alignment stack is importable (cheap — no model load/download)."""
    try:
        return importlib.util.find_spec("torchaudio") is not None
    except Exception:
        return False


def _ensure_loaded() -> bool:
    global _model, _tokenizer, _aligner, _bundle_sr, _load_failed
    if _model is not None:
        return True
    if _load_failed:
        return False
    with _load_lock:                         # double-checked: one loader even under threads
        if _model is not None:
            return True
        if _load_failed:
            return False
        try:
            import torch  # noqa: F401  (needed by torchaudio)
            import torchaudio

            bundle = torchaudio.pipelines.MMS_FA
            _model = bundle.get_model()      # downloads ~300 MB once, then cached
            _tokenizer = bundle.get_tokenizer()
            _aligner = bundle.get_aligner()
            _bundle_sr = bundle.sample_rate
            return True
        except Exception:
            _load_failed = True
            return False


def warmup() -> bool:
    """Force-load (and download) the aligner model. Returns success."""
    return _ensure_loaded()


def _norm_words(text: str) -> List[str]:
    return [w for w in _NONWORD.sub(" ", text.lower()).split() if w]


def align_sentences(pcm: np.ndarray, sample_rate: int,
                    sentence_texts: List[str]) -> Optional[List[Tuple[float, float]]]:
    """Recover per-sentence ``(start_sec, end_sec)`` on the audio's own timeline.

    ``pcm`` is one continuous buffer whose spoken content is exactly ``sentence_texts`` in
    order. Returns one (start, end) per input sentence, or ``None`` if alignment is
    unavailable or fails (caller then falls back to per-sentence synthesis).
    """
    if pcm is None or len(pcm) == 0 or not sentence_texts:
        return None
    if not _ensure_loaded():
        return None
    try:
        import torch
        import torchaudio

        # Flat word list with per-word sentence ownership.
        flat_words: List[str] = []
        owners: List[int] = []
        for si, text in enumerate(sentence_texts):
            for w in _norm_words(text):
                flat_words.append(w)
                owners.append(si)
        if not flat_words:
            return None

        wav = torch.from_numpy(np.asarray(pcm, dtype=np.float32)).unsqueeze(0)
        if sample_rate != _bundle_sr:
            wav = torchaudio.functional.resample(wav, sample_rate, _bundle_sr)
        with torch.inference_mode():
            emission, _ = _model(wav)
            token_spans = _aligner(emission[0], _tokenizer(flat_words))
        if len(token_spans) != len(flat_words):
            return None
        ratio = wav.size(1) / emission.size(1)            # samples per emission frame

        def w_start(i: int) -> float:
            return token_spans[i][0].start * ratio / _bundle_sr

        def w_end(i: int) -> float:
            return token_spans[i][-1].end * ratio / _bundle_sr

        # First / last flat-word index owned by each sentence.
        n = len(sentence_texts)
        first: List[Optional[int]] = [None] * n
        last: List[Optional[int]] = [None] * n
        for i, si in enumerate(owners):
            if first[si] is None:
                first[si] = i
            last[si] = i

        out: List[Tuple[float, float]] = []
        prev_e = 0.0
        for si in range(n):
            fi, li = first[si], last[si]
            if fi is None:                                 # sentence had no alignable words
                out.append((prev_e, prev_e))               # zero-width; highlight passes through
                continue
            s = w_start(fi)
            e = max(w_end(li), s)
            out.append((s, e))
            prev_e = e
        return out
    except Exception:
        return None
