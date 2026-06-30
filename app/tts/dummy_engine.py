"""A fake TTS engine: produces quiet tone whose length matches the text.

Lets you exercise the whole ingest -> player pipeline (timings, seeking,
highlighting, search) without downloading torch + the Kokoro model.
"""
from __future__ import annotations

import numpy as np

from .base import TTSEngine

_WORDS_PER_SEC = 2.9  # ~175 wpm, close to natural narration pace


class DummyEngine(TTSEngine):
    name = "dummy"

    def __init__(self, sample_rate: int = 24000, voice: str = "dummy", **_):
        self.sample_rate = sample_rate
        self.voice = voice

    def synth(self, text: str) -> np.ndarray:
        words = max(1, len(text.split()))
        dur = max(0.35, words / _WORDS_PER_SEC)
        n = int(dur * self.sample_rate)
        t = np.arange(n, dtype=np.float32) / self.sample_rate
        # Soft low tone with gentle fades so consecutive sentences are audible.
        freq = 150.0 + (hash(text) % 60)
        wave = 0.03 * np.sin(2 * np.pi * freq * t).astype(np.float32)
        fade = min(n, int(0.02 * self.sample_rate))
        if fade:
            env = np.ones(n, dtype=np.float32)
            env[:fade] = np.linspace(0, 1, fade)
            env[-fade:] = np.linspace(1, 0, fade)
            wave *= env
        return wave

    def info(self) -> dict:
        return {"engine": self.name, "sample_rate": self.sample_rate, "voice": self.voice}
