#!/bin/sh
# Checks scripts/latency.sh against a small saved log: per-mode latency, stage
# medians, memory, and the utterance-length buckets with keep-guard rejections.
# The fixture also has a rejection whose dictation never finished (not counted)
# and a timing line with no mic line before it (counted as without a length).
set -eu
cd "$(dirname "$0")/.."
expected='literal   preview=false n=2    median=0.130s p90=0.140s
          stage medians: finalize=0.115s cleanup=0.001s modwait=0.000s paste=0.002s
polished  preview=false n=4    median=0.700s p90=2.000s
          stage medians: finalize=0.100s cleanup=0.001s first=0.300s rewrite=0.600s modwait=0.000s paste=0.002s
memory    peak=42.5MB idle=42.5MB (latest of 1) growth=+1.0MB over 1 sessions (pid 100)
length    literal preview=false utterance median=3.0s p90=3.0s (1 without a length)
          3-6s   n=1    median=0.120s p90=0.120s rejected=0
length    polished preview=false utterance median=4.8s p90=25.0s
          <3s    n=1    median=0.400s p90=0.400s rejected=0
          3-6s   n=2    median=0.700s p90=0.800s rejected=1
          20s+   n=1    median=2.000s p90=2.000s rejected=0'
actual=$(scripts/latency.sh --file scripts/fixtures/latency.log)
if [ "$actual" != "$expected" ]; then
  echo "test-latency: output differs from expected:" >&2
  printf '%s\n' "$expected" > "${TMPDIR:-/tmp}/latency-expected.$$"
  printf '%s\n' "$actual" | diff "${TMPDIR:-/tmp}/latency-expected.$$" - >&2 || true
  rm -f "${TMPDIR:-/tmp}/latency-expected.$$"
  exit 1
fi
echo "test-latency: OK"
