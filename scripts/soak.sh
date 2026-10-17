#!/bin/sh
# Memory soak: runs a debug build in fake mode through N dictations (default 100)
# with a fake hotkey and paste target (nothing is typed anywhere; the HUD does
# show), then reports the footprint before and after and runs `leaks` on it.
# Fails only on leaks allocated from Speak's own code: macOS frameworks leak a
# fixed few at launch (an AppIntents XPC connection cycle) that Speak can't fix.
# Usage: scripts/soak.sh [count]
set -eu
cd "$(dirname "$0")/.."
count=${1:-100}

swift build -c debug >/dev/null
bin="$(swift build -c debug --show-bin-path)/Speak"
out=$(mktemp -t speak-soak)
trap 'kill "$pid" 2>/dev/null || true; rm -f "$out"' EXIT

SPEAK_FAKE=1 SPEAK_SOAK="$count" MallocStackLogging=1 "$bin" >"$out" 2>/dev/null &
pid=$!
echo "soak: pid $pid, $count dictations (about $((count * 7 / 10 + 10)) s)…"

# Up to 3 s per dictation before giving up.
limit=$((count * 3 + 30)); waited=0
until grep -q "^soak done" "$out"; do
  if ! kill -0 "$pid" 2>/dev/null; then echo "soak: Speak exited early" >&2; exit 1; fi
  if [ "$waited" -ge "$limit" ]; then echo "soak: timed out after ${limit}s" >&2; exit 1; fi
  sleep 1; waited=$((waited + 1))
done
grep "^soak done" "$out"

# Allocation stacks (MallocStackLogging) tell Speak's leaks from the frameworks'.
leaks "$pid" >"$out.leaks" 2>&1 || true
grep -E "^Process .*: [0-9]+ leaks? for" "$out.leaks" || { tail -5 "$out.leaks"; exit 1; }
own=$(awk '
  /^STACK OF [0-9]+ INSTANCES? OF/ { n = $3; ours = 0; inblock = 1; next }
  inblock && /^====/ { if (ours) total += n; inblock = 0; next }
  inblock && $2 == "Speak" { ours = 1 }
  END { print total + 0 }' "$out.leaks")
echo "leaks from Speak code: $own"
rm -f "$out.leaks"
[ "$own" -eq 0 ]
