#!/usr/bin/env bash
# Start the web player + API at http://127.0.0.1:8000
set -euo pipefail
cd "$(dirname "$0")/.."
HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-8000}"
echo "==> Audiobook Reader running at http://$HOST:$PORT"
exec .venv/bin/python -m uvicorn app.server:app --host "$HOST" --port "$PORT" "$@"
