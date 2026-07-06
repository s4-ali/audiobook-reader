#!/usr/bin/env bash
# Set up the Python environment. Pass --tts to also install Kokoro + PyTorch.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> Audiobook Reader setup"

if ! command -v uv >/dev/null 2>&1; then
  echo "ERROR: 'uv' not found. Install it: https://docs.astral.sh/uv/  (curl -LsSf https://astral.sh/uv/install.sh | sh)"
  exit 1
fi

# 1. Virtual environment on Python 3.13 (uv fetches it if missing).
# Reuse an existing .venv so re-running (e.g. to add --voxtral later) is additive and never
# wipes an already-installed engine stack; only create it the first time.
if [[ -d .venv ]]; then
  echo "==> Reusing existing .venv"
else
  echo "==> Creating .venv (Python 3.13)"
  uv venv --python 3.13 .venv
fi

# 2. Base dependencies.
echo "==> Installing base dependencies"
uv pip install --python .venv/bin/python -r requirements.txt

# 3. Optional heavy TTS stacks (pass either/both: --tts for Kokoro, --voxtral for Voxtral).
for arg in "$@"; do
  case "$arg" in
    --tts)
      echo "==> Installing Kokoro + PyTorch (this is a large download)"
      uv pip install --python .venv/bin/python -r requirements-tts.txt ;;
    --voxtral)
      echo "==> Installing Voxtral via mlx-audio (Apple Silicon; large model on first run)"
      uv pip install --python .venv/bin/python -r requirements-voxtral.txt ;;
  esac
done

# 4. Check system tools.
echo
echo "==> System tool check"
if command -v ffmpeg >/dev/null 2>&1; then
  echo "  ffmpeg:    OK ($(command -v ffmpeg))"
else
  echo "  ffmpeg:    MISSING — install with: brew install ffmpeg   (MP3 output; WAV used as fallback)"
fi
if command -v espeak-ng >/dev/null 2>&1 || ls /opt/homebrew/lib/libespeak-ng*.dylib >/dev/null 2>&1; then
  echo "  espeak-ng: OK"
else
  echo "  espeak-ng: MISSING — install with: brew install espeak-ng   (improves Kokoro pronunciation of rare words)"
fi

echo
echo "Done. Next:"
echo "  • Real narration deps:  ./scripts/setup.sh --tts"
echo "  • Premium voices deps:  ./scripts/setup.sh --voxtral   (Voxtral-4B, Apple Silicon)"
echo "  • Start the player:     ./scripts/run.sh   then open http://127.0.0.1:8000"
echo "  • Ingest a PDF (CLI):   ./scripts/ingest.sh path/to/book.pdf"
