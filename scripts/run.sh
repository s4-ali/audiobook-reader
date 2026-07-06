#!/usr/bin/env bash
# Start the web player + API. Defaults to http://127.0.0.1:8000 (local only).
# For phone access, run with HOST=0.0.0.0 so devices on the same Wi-Fi can reach it.
set -euo pipefail
cd "$(dirname "$0")/.."
export HOST="${HOST:-127.0.0.1}"   # exported so app/config.py can read it back (pairing)
export PORT="${PORT:-8000}"
echo "==> Audiobook Reader"
.venv/bin/python -m app.netinfo || true   # print reachable URLs; never block startup
exec .venv/bin/python -m uvicorn app.server:app --host "$HOST" --port "$PORT" "$@"
