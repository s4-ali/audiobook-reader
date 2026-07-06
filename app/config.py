"""Central configuration. Everything is overridable via environment variables."""
from __future__ import annotations

import os
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# --- Filesystem layout -------------------------------------------------------
LIBRARY_DIR = Path(os.environ.get("AUDIOBOOK_LIBRARY", ROOT / "library")).resolve()
INBOX_DIR = LIBRARY_DIR / "inbox"      # drop PDFs here
BOOKS_DIR = LIBRARY_DIR / "books"      # generated audiobooks live here
WEB_DIR = ROOT / "web"                 # static frontend

# --- TTS defaults ------------------------------------------------------------
DEFAULT_ENGINE = os.environ.get("TTS_ENGINE", "kokoro")  # "kokoro" | "voxtral" | "dummy"
DEFAULT_VOICE = os.environ.get("KOKORO_VOICE", "af_heart")
DEFAULT_LANG = os.environ.get("KOKORO_LANG", "a")        # a=US English, b=UK English, ...
DEFAULT_SPEED = float(os.environ.get("KOKORO_SPEED", "1.0"))
# CPU is empirically faster than MPS for this 82M model on Apple Silicon
# (less kernel-launch overhead; istft runs on CPU anyway). Override with "mps"/"auto".
KOKORO_DEVICE = os.environ.get("KOKORO_DEVICE", "cpu")   # cpu | mps | auto
SAMPLE_RATE = 24000                                       # Kokoro is fixed at 24 kHz

# Voxtral-4B-TTS (Mistral) — optional premium engine, run locally via MLX (Apple Silicon).
# Also 24 kHz, so it fits the pipeline unchanged. Weights are CC BY-NC 4.0 (non-commercial);
# heavier + slower than Kokoro. See app/tts/voxtral_engine.py. Enable with TTS_ENGINE=voxtral
# or `--engine voxtral`; install with `./scripts/setup.sh --voxtral`.
VOXTRAL_REPO = os.environ.get("VOXTRAL_REPO", "mlx-community/Voxtral-4B-TTS-2603-mlx-4bit")
VOXTRAL_VOICE = os.environ.get("VOXTRAL_VOICE", "casual_male")  # a Voxtral preset, not a Kokoro id

# --- Audio output ------------------------------------------------------------
AUDIO_FORMAT = os.environ.get("AUDIO_FORMAT", "mp3")     # "mp3" | "wav"
# CBR (constant bitrate), NOT VBR. Every MP3 frame is then the same byte size, so a player
# maps a timestamp to an exact byte/frame offset instead of interpolating the coarse Xing
# TOC that VBR forces on it. VBR MP3 seeking in browsers (<audio>.currentTime) and in
# ExoPlayer/just_audio lands seconds off, which desynced the karaoke highlight and made
# click-to-seek jump to the wrong sentence. 64k mono @ 24 kHz is transparent for speech.
MP3_BITRATE = os.environ.get("MP3_BITRATE", "64k")       # libmp3lame -b:a (CBR)
SENTENCE_GAP_MS = int(os.environ.get("SENTENCE_GAP_MS", "90"))
PARAGRAPH_GAP_MS = int(os.environ.get("PARAGRAPH_GAP_MS", "320"))

# --- Pronunciation dictionary ------------------------------------------------
# Optional JSON map of spoken-form replacements applied just before TTS (audio only;
# on-screen text, search and timings keep the original words). Absent by default = no-op.
# See app/pronounce.py and library/pronunciation.example.json for the format.
PRONUNCIATION_FILE = Path(os.environ.get(
    "PRONUNCIATION_FILE", LIBRARY_DIR / "pronunciation.json")).resolve()

# --- Chapter segmentation ----------------------------------------------------
# When a PDF has no usable table of contents we split into ~this many words/chapter.
WORDS_PER_FALLBACK_CHAPTER = int(os.environ.get("WORDS_PER_FALLBACK_CHAPTER", "1400"))
# Minimum chars of front-matter before the first heading to keep it as its own chapter.
MIN_FRONTMATTER_CHARS = 600


def ensure_dirs() -> None:
    for d in (INBOX_DIR, BOOKS_DIR):
        d.mkdir(parents=True, exist_ok=True)
