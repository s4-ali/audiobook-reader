"""Voxtral-4B-TTS engine (Mistral AI), run locally via MLX on Apple Silicon.

https://huggingface.co/mistralai/Voxtral-4B-TTS-2603 — a 4B multilingual TTS model
(20 preset voices, 9 languages, 24 kHz). We load the MLX-quantized community build
(``mlx-community/Voxtral-4B-TTS-2603-mlx-4bit`` by default) through ``mlx-audio``.

Like ``KokoroEngine``, the heavy deps (mlx / mlx-audio) are imported lazily inside
``__init__`` so the rest of the app runs — and imports this module — without them and
on non-Apple platforms. The model is loaded once and reused for every sentence.

NOTE: MLX runs on Metal (GPU), not CoreML/ANE, so it is unaffected by CoreML issues.
NOTE: the weights are CC BY-NC 4.0 (non-commercial); Kokoro (Apache-2.0) stays the default.
"""
from __future__ import annotations

import inspect
import re
import sys
from typing import Optional

import numpy as np

from .base import TTSEngine

# The 20 built-in presets (English + 8 more languages). Not exhaustive validation —
# an id we don't list is still passed through to the model (it may accept more).
PRESET_VOICES = (
    "casual_male", "casual_female", "cheerful_female", "neutral_male", "neutral_female",
    "fr_male", "fr_female", "es_male", "es_female", "de_male", "de_female",
    "it_male", "it_female", "pt_male", "pt_female", "nl_male", "nl_female",
    "ar_male", "hi_male", "hi_female",
)

# Kokoro voice ids look like "af_heart" / "am_adam" / "bf_emma" — [lang][gender]_name.
# The CLI/config default voice is Kokoro's (`af_heart`), so detect that shape and swap in
# the Voxtral preset instead, letting `--engine voxtral` work without also passing --voice.
_KOKORO_VOICE_RE = re.compile(r"^[abefhijpz][fm]_")


class VoxtralEngine(TTSEngine):
    name = "voxtral"

    def __init__(self, voice: str = "casual_male", model_repo: Optional[str] = None,
                 speed: float = 1.0, default_voice: str = "casual_male"):
        if not voice or _KOKORO_VOICE_RE.match(voice):
            voice = default_voice or "casual_male"
        if voice not in PRESET_VOICES:
            print(f"  · voxtral: '{voice}' is not a known preset voice; trying it anyway "
                  f"(presets: {', '.join(PRESET_VOICES)})", file=sys.stderr)
        self.voice = voice
        self.speed = speed
        self.model_repo = model_repo or "mlx-community/Voxtral-4B-TTS-2603-mlx-4bit"
        self.sample_rate = 24000  # Voxtral outputs 24 kHz — same as the rest of the pipeline

        try:
            from mlx_audio.tts.utils import load
        except ImportError as ex:
            raise RuntimeError(
                "The 'voxtral' engine needs mlx-audio (Apple Silicon only). Install it with "
                "`./scripts/setup.sh --voxtral` or `pip install -U mlx-audio`. "
                f"(import error: {ex})"
            ) from ex

        # Loads once (and downloads the quantized weights on first run), then reused per
        # sentence — a fresh load per sentence would be ruinous for a 4B model.
        self.model = load(self.model_repo)

        # Voxtral's documented API is generate(text=, voice=). Only forward `speed` if this
        # build actually accepts it, so an unsupported kwarg never breaks synthesis.
        try:
            params = inspect.signature(self.model.generate).parameters
            self._supports_speed = "speed" in params
        except (TypeError, ValueError):
            self._supports_speed = False

    def synth(self, text: str) -> np.ndarray:
        text = text.strip()
        if not text:
            return np.zeros(1, dtype=np.float32)

        kwargs = {"text": text, "voice": self.voice}
        if self._supports_speed and self.speed and self.speed != 1.0:
            kwargs["speed"] = self.speed

        chunks = []
        for result in self.model.generate(**kwargs):  # may stream several chunks
            audio = self._to_numpy(getattr(result, "audio", None))
            if audio is not None and audio.size:
                chunks.append(audio)
        if not chunks:
            return np.zeros(1, dtype=np.float32)
        return np.concatenate(chunks)

    @staticmethod
    def _to_numpy(audio) -> Optional[np.ndarray]:
        if audio is None:
            return None
        # Normalize an mlx.core.array / torch.Tensor / list to float32 mono PCM.
        try:
            import mlx.core as mx
            if isinstance(audio, mx.array):
                audio = np.array(audio)
        except Exception:
            pass
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
            "voice": self.voice, "lang": "", "speed": self.speed,
            "device": "mlx", "model": self.model_repo,
        }
