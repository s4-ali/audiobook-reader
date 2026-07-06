"""System self-check: report whether the external tools and Python packages the pipeline
needs are present, plus a library + config summary. Powers ``GET /api/health`` and the CLI
``doctor`` command. Cheap and import-only — it never loads the TTS model.
"""
from __future__ import annotations

import importlib.util
import platform
import shutil
import subprocess
from typing import List, Optional

from . import config, library
from .audio import have_ffmpeg


def _which(*names: str) -> Optional[str]:
    for n in names:
        p = shutil.which(n)
        if p:
            return p
    return None


def _ffmpeg_version() -> Optional[str]:
    if not have_ffmpeg():
        return None
    try:
        out = subprocess.run(["ffmpeg", "-version"], capture_output=True, text=True, timeout=4)
        first = (out.stdout or out.stderr or "").splitlines()
        parts = first[0].split() if first else []
        # "ffmpeg version 6.1.1 Copyright ..." -> "6.1.1"
        return parts[2] if len(parts) >= 3 and parts[0] == "ffmpeg" else (first[0] if first else None)
    except Exception:
        return None


def _module_present(name: str) -> bool:
    try:
        return importlib.util.find_spec(name) is not None
    except Exception:
        return False


def _mps_available() -> Optional[bool]:
    if not _module_present("torch"):
        return None
    try:
        import torch
        return bool(torch.backends.mps.is_available())
    except Exception:
        return None


def _version() -> str:
    try:
        import app
        return getattr(app, "__version__", "0.0.0")
    except Exception:
        return "0.0.0"


def health_report() -> dict:
    """Structured diagnostics. ``status`` is 'ok' or 'warn' (with human-readable warnings)."""
    espeak = _which("espeak-ng", "espeak")
    ffmpeg_ok = have_ffmpeg()
    torch_ok = _module_present("torch")
    kokoro_ok = _module_present("kokoro")
    kokoro_ready = torch_ok and kokoro_ok       # the real engine needs both
    mlx_audio_ok = _module_present("mlx_audio")  # the Voxtral engine needs this (Apple Silicon)

    fmt = config.AUDIO_FORMAT.lower()
    effective_fmt = fmt if (fmt != "mp3" or ffmpeg_ok) else "wav"

    books = library.list_books()
    generating = sum(1 for b in books if b.get("status") == "generating")

    warnings: List[str] = []
    if config.DEFAULT_ENGINE == "kokoro" and not kokoro_ready:
        missing = ", ".join(m for m, ok in (("torch", torch_ok), ("kokoro", kokoro_ok)) if not ok)
        warnings.append(f"Default engine is 'kokoro' but {missing} not installed — run "
                        f"./scripts/setup.sh --tts, or ingest with --engine dummy to test.")
    if config.DEFAULT_ENGINE == "voxtral" and not mlx_audio_ok:
        warnings.append("Default engine is 'voxtral' but mlx-audio not installed — run "
                        "./scripts/setup.sh --voxtral (Apple Silicon), or ingest with "
                        "--engine dummy/kokoro.")
    if fmt == "mp3" and not ffmpeg_ok:
        warnings.append("ffmpeg not found — audio is written as WAV instead of MP3 "
                        "(install: brew install ffmpeg).")
    if config.DEFAULT_ENGINE == "kokoro" and kokoro_ready and not espeak:
        warnings.append("espeak-ng not found — pronunciation falls back for some words "
                        "(install: brew install espeak-ng).")

    return {
        "status": "warn" if warnings else "ok",
        "version": _version(),
        "python": platform.python_version(),
        "platform": platform.platform(),
        "tools": {
            "ffmpeg": {"available": ffmpeg_ok, "version": _ffmpeg_version()},
            "espeak_ng": {"available": espeak is not None, "path": espeak},
        },
        "engines": {
            "default": config.DEFAULT_ENGINE,
            "dummy": True,
            "kokoro": {"available": kokoro_ready, "torch": torch_ok, "kokoro": kokoro_ok,
                       "device": config.KOKORO_DEVICE, "mps_available": _mps_available()},
            "voxtral": {"available": mlx_audio_ok, "mlx_audio": mlx_audio_ok,
                        "repo": config.VOXTRAL_REPO},
        },
        "audio": {"configured_format": fmt, "effective_format": effective_fmt,
                  "mp3_bitrate": config.MP3_BITRATE, "sample_rate": config.SAMPLE_RATE},
        "defaults": {"voice": config.DEFAULT_VOICE, "lang": config.DEFAULT_LANG,
                     "speed": config.DEFAULT_SPEED},
        "pronunciation": {"file": str(config.PRONUNCIATION_FILE),
                          "enabled": config.PRONUNCIATION_FILE.exists()},
        "library": {"path": str(config.LIBRARY_DIR), "books": len(books), "generating": generating},
        "warnings": warnings,
    }
