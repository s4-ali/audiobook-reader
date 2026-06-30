"""Kokoro-82M TTS engine (https://huggingface.co/hexgrad/Kokoro-82M).

Lazily imports torch + kokoro so the rest of the app runs without them.
On Apple Silicon it prefers MPS with CPU fallback for unsupported ops.
"""
from __future__ import annotations

import os
import warnings
from typing import Optional

import numpy as np

from .base import TTSEngine

# Harmless first-run noise from torch/kokoro internals on MPS.
for _msg in (".*was resized.*", ".*weight_norm.*is deprecated.*",
             ".*dropout option adds dropout.*", ".*Defaulting repo_id.*"):
    warnings.filterwarnings("ignore", message=_msg)

_ESPEAK_CANDIDATES = [
    "/opt/homebrew/lib/libespeak-ng.dylib",
    "/opt/homebrew/lib/libespeak-ng.1.dylib",
    "/usr/local/lib/libespeak-ng.dylib",
    "/usr/lib/libespeak-ng.so.1",
]


def _configure_espeak() -> None:
    if os.environ.get("PHONEMIZER_ESPEAK_LIBRARY"):
        return
    for path in _ESPEAK_CANDIDATES:
        if os.path.exists(path):
            os.environ["PHONEMIZER_ESPEAK_LIBRARY"] = path
            break


class KokoroEngine(TTSEngine):
    name = "kokoro"

    def __init__(self, lang: str = "a", voice: str = "af_heart",
                 speed: float = 1.0, device: str = "auto"):
        os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")
        os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")
        _configure_espeak()

        import torch
        from kokoro import KPipeline

        if device == "auto":
            device = "mps" if torch.backends.mps.is_available() else "cpu"
        self.device = device
        self.lang = lang
        self.voice = voice
        self.speed = speed
        self.sample_rate = 24000

        try:
            self.pipe = KPipeline(lang_code=lang, device=device)
        except TypeError:
            # Older kokoro without a device kwarg.
            self.pipe = KPipeline(lang_code=lang)
            try:
                self.pipe.model = self.pipe.model.to(device)
            except Exception:
                self.device = "cpu"
        # Warm the voice (downloads the voicepack once).
        try:
            self.pipe.load_voice(voice)
        except Exception:
            pass

    def synth(self, text: str) -> np.ndarray:
        text = text.strip()
        if not text:
            return np.zeros(1, dtype=np.float32)

        chunks = []
        for result in self.pipe(text, voice=self.voice, speed=self.speed):
            audio = result[-1]  # (graphemes, phonemes, audio)
            audio = self._to_numpy(audio)
            if audio is not None and audio.size:
                chunks.append(audio)
        if not chunks:
            return np.zeros(1, dtype=np.float32)
        return np.concatenate(chunks)

    @staticmethod
    def _to_numpy(audio) -> Optional[np.ndarray]:
        if audio is None:
            return None
        try:
            import torch
            if isinstance(audio, torch.Tensor):
                audio = audio.detach().to("cpu").numpy()
        except Exception:
            pass
        return np.asarray(audio, dtype=np.float32).reshape(-1)

    def info(self) -> dict:
        return {
            "engine": self.name, "sample_rate": self.sample_rate,
            "voice": self.voice, "lang": self.lang,
            "speed": self.speed, "device": getattr(self, "device", "cpu"),
        }
