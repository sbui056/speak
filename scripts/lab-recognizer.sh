#!/bin/sh
# Recognizer accuracy on synthetic speech: speaks scripts/lab/sentences.txt with
# four system voices at two rates (`say`, on-device), runs each through the real
# transcriber and Literal cleanup (debug build), and scores the target words.
# No microphone and no recording of anyone's voice; the temporary WAVs are deleted.
# Usage: scripts/lab-recognizer.sh [tsv-file]   (default: score only)
set -eu
cd "$(dirname "$0")/.."
sentences=scripts/lab/sentences.txt
swift build -c debug >/dev/null
bin="$(swift build -c debug --show-bin-path)/Speak"
out=${1:-$(mktemp -t speak-lab)}
[ -n "${1:-}" ] || trap 'rm -f "$out"' EXIT
SPEAK_LAB=$sentences "$bin" 2>/dev/null >"$out" || true
grep '^lab: ' "$out" >&2 && sed -i '' '/^lab: /d' "$out"
grep -q . "$out" || { echo "lab: no results" >&2; exit 1; }
exec python3 -I scripts/accuracy.py --lab "$sentences" "$out"
