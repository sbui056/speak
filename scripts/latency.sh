#!/bin/sh
# Prints release-to-text latency (median and p90) per mode from Speak's own
# timing log lines. Usage: scripts/latency.sh [window], e.g. 3d (default 7d).
# Previewed rewrites are listed separately: they stop the clock when the preview opens.
set -eu
window=${1:-7d}
/usr/bin/log show --last "$window" --predicate 'subsystem == "io.github.sbui056.speak" AND category == "session"' 2>/dev/null |
  sed -n 's/.*timing dictation mode=\([a-z]*\) preview=\([a-z]*\) \([0-9.]*\)s.*/\1 \2 \3/p' |
  sort -k1,1 -k2,2 -k3,3n |
  awk '
    function report(key, n) {
      if (n == 0) return
      m = (n % 2) ? v[(n + 1) / 2] : (v[n / 2] + v[n / 2 + 1]) / 2
      p = int(0.9 * n + 0.999999); if (p < 1) p = 1
      split(key, k, " ")
      printf "%-9s preview=%-5s n=%-4d median=%.3fs p90=%.3fs\n", k[1], k[2], n, m, v[p]
    }
    { key = $1 " " $2
      if (key != prev) { report(prev, n); n = 0; prev = key }
      v[++n] = $3 }
    END { report(prev, n); if (NR == 0) print "no timing lines in the last '"$window"'" }'
