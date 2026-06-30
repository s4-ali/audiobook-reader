#!/usr/bin/env bash
# Ingest a PDF (or all PDFs in library/inbox/) into a narrated audiobook.
#   ./scripts/ingest.sh book.pdf --voice af_heart --speed 1.0
#   ./scripts/ingest.sh                # processes every PDF in library/inbox/
set -euo pipefail
cd "$(dirname "$0")/.."
exec .venv/bin/python -m app.ingest "$@"
