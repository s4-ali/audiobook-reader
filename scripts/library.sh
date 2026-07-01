#!/usr/bin/env bash
# Manage the local audiobook library from the terminal.
#   ./scripts/library.sh list                                  # all books
#   ./scripts/library.sh info <book-id>                        # details + chapter table
#   ./scripts/library.sh doctor                                # dependency/health check
#   ./scripts/library.sh export <book-id> [-o DIR]             # package a .abk
#   ./scripts/library.sh transcript <book-id> [-o FILE]        # plain-text transcript
#   ./scripts/library.sh subtitles <book-id> [--chapter N] [--format srt|vtt] [-o FILE]
#   ./scripts/library.sh delete <book-id> [--yes]
set -euo pipefail
cd "$(dirname "$0")/.."
exec .venv/bin/python -m app.cli "$@"
