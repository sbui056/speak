#!/bin/sh
# Window memory check: runs a debug build in fake mode, opens and closes Settings,
# Dictionary, and History N times each (default 3; the windows flash on screen),
# and prints the footprint before, while open, and after each close. Fails if a
# closed window or its SwiftUI views are still alive. The footprint doesn't fall
# back to the start: the first SwiftUI window loads framework caches for good.
# Usage: scripts/window-memory.sh [rounds]
set -eu
cd "$(dirname "$0")/.."
rounds=${1:-3}

swift build -c debug >/dev/null
bin="$(swift build -c debug --show-bin-path)/Speak"
out=$(mktemp -t speak-windows)
trap 'kill "$pid" 2>/dev/null && { wait "$pid" 2>/dev/null || true; }; rm -f "$out"' EXIT

SPEAK_FAKE=1 SPEAK_WINDOWS="$rounds" "$bin" >"$out" 2>/dev/null &
pid=$!

limit=$((rounds * 10 + 30)); waited=0
until grep -q "^windows done" "$out"; do
  if ! kill -0 "$pid" 2>/dev/null; then echo "windows: Speak exited early" >&2; exit 1; fi
  if [ "$waited" -ge "$limit" ]; then echo "windows: timed out after ${limit}s" >&2; exit 1; fi
  sleep 1; waited=$((waited + 1))
done
grep "^windows " "$out" | grep -v "^windows done"

status=0
awk '
  /^windows baseline/ { split($4, a, "="); base = a[2] + 0 }
  /^windows closed/   { split($4, a, "="); last = a[2] + 0; if ($5 != "freed=true") alive++ }
  /^windows alive=/   { split($2, a, "="); alive += a[2] }
  END {
    growth = last - base
    printf "windows: start %.1f MB, after last close %.1f MB (%+.1f MB), still alive after close: %d\n", base, last, growth, alive
    exit alive > 0 ? 1 : 0
  }' "$out" || status=$?
exit "$status"
