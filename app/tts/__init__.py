"""TTS engine factory."""
from __future__ import annotations

from .. import config
from .base import TTSEngine


def make_engine(engine: str = None, voice: str = None, lang: str = None,
                speed: float = None, device: str = None) -> TTSEngine:
    engine = (engine or config.DEFAULT_ENGINE).lower()
    voice = voice or config.DEFAULT_VOICE
    lang = lang or config.DEFAULT_LANG
    speed = config.DEFAULT_SPEED if speed is None else speed
    device = device or config.KOKORO_DEVICE

    if engine == "dummy":
        from .dummy_engine import DummyEngine
        return DummyEngine(sample_rate=config.SAMPLE_RATE, voice=voice)
    if engine == "kokoro":
        from .kokoro_engine import KokoroEngine
        return KokoroEngine(lang=lang, voice=voice, speed=speed, device=device)
    if engine == "voxtral":
        from .voxtral_engine import VoxtralEngine
        return VoxtralEngine(voice=voice, model_repo=config.VOXTRAL_REPO,
                             speed=speed, default_voice=config.VOXTRAL_VOICE)
    raise ValueError(f"Unknown TTS engine: {engine!r} (use 'kokoro', 'voxtral', or 'dummy')")


__all__ = ["TTSEngine", "make_engine"]
