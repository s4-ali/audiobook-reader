#!/usr/bin/env bash
# Package a completed audiobook into a single .abk file (for the mobile app).
#   ./scripts/export.sh <book-id>            # writes <book-id>.abk to the cwd
#   ./scripts/export.sh                       # packages every "ready" book
#   ./scripts/export.sh <book-id> -o ~/Desktop
set -euo pipefail
cd "$(dirname "$0")/.."
exec .venv/bin/python -m app.export "$@"
