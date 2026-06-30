"""Audio assembly: concatenate per-sentence PCM and encode to MP3/WAV."""
from __future__ import annotations

import shutil
import subprocess
from pathlib import Path
from typing import List

import numpy as np

from .config import MP3_QUALITY, SAMPLE_RATE


def silence(ms: int, sr: int = SAMPLE_RATE) -> np.ndarray:
    return np.zeros(int(sr * ms / 1000.0), dtype=np.float32)


def have_ffmpeg() -> bool:
    return shutil.which("ffmpeg") is not None


def concat(parts: List[np.ndarray]) -> np.ndarray:
    if not parts:
        return np.zeros(0, dtype=np.float32)
    return np.concatenate([np.asarray(p, dtype=np.float32).reshape(-1) for p in parts])


def _peak_normalize(audio: np.ndarray, target: float = 0.95) -> np.ndarray:
    peak = float(np.max(np.abs(audio))) if audio.size else 0.0
    if peak > target:
        audio = audio * (target / peak)
    return audio


def write_audio(audio: np.ndarray, out_path: Path, sr: int = SAMPLE_RATE,
                fmt: str = "mp3") -> Path:
    """Write float32 mono PCM to ``out_path`` as mp3 (via ffmpeg) or wav."""
    audio = _peak_normalize(np.asarray(audio, dtype=np.float32).reshape(-1))
    out_path = Path(out_path)
    out_path.parent.mkdir(parents=True, exist_ok=True)

    if fmt == "mp3" and have_ffmpeg():
        return _encode_mp3(audio, out_path, sr)
    # WAV fallback (no external deps beyond soundfile).
    if out_path.suffix.lower() != ".wav":
        out_path = out_path.with_suffix(".wav")
    import soundfile as sf
    sf.write(str(out_path), audio, sr, subtype="PCM_16")
    return out_path


def _encode_mp3(audio: np.ndarray, out_path: Path, sr: int) -> Path:
    if out_path.suffix.lower() != ".mp3":
        out_path = out_path.with_suffix(".mp3")
    cmd = [
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
        "-f", "f32le", "-ar", str(sr), "-ac", "1", "-i", "pipe:0",
        "-c:a", "libmp3lame", "-q:a", str(MP3_QUALITY), str(out_path),
    ]
    proc = subprocess.run(cmd, input=audio.tobytes(), stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE)
    if proc.returncode != 0:
        raise RuntimeError(f"ffmpeg failed: {proc.stderr.decode(errors='ignore')[:500]}")
    return out_path


def duration_seconds(audio: np.ndarray, sr: int = SAMPLE_RATE) -> float:
    return len(audio) / float(sr)
