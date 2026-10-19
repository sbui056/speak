#!/bin/sh
# Scores a dictation run against the expected sentences: target-word hits,
# control words that got worse, and WER. See scripts/accuracy.py for formats.
# Usage: scripts/accuracy.sh <expected> <got>
exec python3 -I "$(dirname "$0")/accuracy.py" "$@"
