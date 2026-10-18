#!/bin/sh
# Prints release-to-text latency (median and p90) per mode from Speak's own
# timing log lines, the median of each stage, and the memory footprint.
# Usage: scripts/latency.sh [window], e.g. 3d (default 7d). Only the bundled app
# counts, so soak runs of the debug build (scripts/soak.sh) never skew it.
# Previewed rewrites are listed separately: they stop the clock when the preview
# opens, and what happens after the user accepts is reported as "handoff".
# Rewrites started at release on the partial transcript get extra rows,
# "spec=hit" (reply used) and "spec=miss" (thrown away and asked again).
set -eu
window=${1:-7d}
/usr/bin/log show --last "$window" --predicate 'subsystem == "io.github.sbui056.speak" AND category == "session" AND processImagePath ENDSWITH ".app/Contents/MacOS/Speak"' 2>/dev/null |
  awk -v window="$window" '
    function sort(a, n,   i, j, t) {
      for (i = 2; i <= n; i++) { t = a[i]; for (j = i - 1; j >= 1 && a[j] > t; j--) a[j + 1] = a[j]; a[j + 1] = t }
    }
    function median(a, n) { sort(a, n); return (n % 2) ? a[(n + 1) / 2] : (a[n / 2] + a[n / 2 + 1]) / 2 }
    function p90(a, n,   p) { sort(a, n); p = int(0.9 * n + 0.999999); if (p < 1) p = 1; return a[p] }
    # Median of one stage within one group, or "" when that stage never ran.
    function stage(g, s,   i, n, a) {
      n = 0
      for (i = 1; i <= cnt[g, s]; i++) a[++n] = val[g, s, i]
      return n ? sprintf(" %s=%.3fs", s, median(a, n)) : ""
    }
    function stages(g,   out, k) {
      out = ""
      for (k = 1; k <= nstages; k++) out = out stage(g, order[k])
      return out
    }
    function record(g, i,   j, total, kv) {
      if (!(g in seen)) { seen[g] = 1; groups[++ngroups] = g }
      total = $(i + 3); sub(/s$/, "", total)
      tot[g, ++n[g]] = total + 0
      for (j = i + 4; j <= NF; j++) if ($j !~ /^spec=/ && split($j, kv, "=") == 2) { sub(/s$/, "", kv[2]); val[g, kv[1], ++cnt[g, kv[1]]] = kv[2] + 0 }
    }
    BEGIN { nstages = split("finalize cleanup first rewrite activate modwait paste", order, " ") }
    / timing dictation mode=/ {
      for (i = 1; i <= NF; i++) if ($i == "dictation") break
      split($(i + 1), m, "="); split($(i + 2), p, "=")
      spec = ""
      for (j = i + 4; j <= NF; j++) if ($j ~ /^spec=/) spec = $j
      record(m[2] " " p[2], i)
      # Rewrites started at release on the partial transcript also get their own row.
      if (spec != "") record(m[2] " " p[2] " " spec, i)
    }
    / timing handoff / {
      g = "handoff"; nh++
      for (j = 1; j <= NF; j++) if (split($j, kv, "=") == 2) { sub(/s$/, "", kv[2]); val[g, kv[1], ++cnt[g, kv[1]]] = kv[2] + 0 }
    }
    / memory footprint=/ {
      pid = $6
      for (j = 1; j <= NF; j++) {
        if ($j ~ /^footprint=/) { mb = $j; sub(/^footprint=/, "", mb); sub(/MB$/, "", mb); mb += 0 }
        if ($j ~ /^after=/) { after = $j; sub(/^after=/, "", after) }
      }
      if (mb > peak) peak = mb
      if (after == "idle") { idle = mb; nidle++ }
      # Growth is measured within the most recent run, from its first to its last session.
      if (after == "session") {
        if (pid != lastpid) { first = mb; nsess = 0; lastpid = pid }
        last = mb; nsess++
      }
    }
    END {
      if (ngroups == 0) print "no timing lines in the last " window
      # Groups in a fixed order (sorted by mode, then preview) for stable output.
      for (a = 1; a <= ngroups; a++) for (b = a + 1; b <= ngroups; b++) if (groups[b] < groups[a]) { t = groups[a]; groups[a] = groups[b]; groups[b] = t }
      for (a = 1; a <= ngroups; a++) {
        g = groups[a]; split(g, k, " ")
        for (i = 1; i <= n[g]; i++) { x[i] = tot[g, i]; y[i] = tot[g, i] }
        printf "%-9s preview=%-5s n=%-4d median=%.3fs p90=%.3fs%s\n", k[1], k[2], n[g], median(x, n[g]), p90(y, n[g]), k[3] ? "  " k[3] : ""
        s = stages(g); if (s != "") printf "          stage medians:%s\n", s
      }
      if (nh) printf "handoff   n=%-4d stage medians:%s\n", nh, stages("handoff")
      if (peak > 0) {
        printf "memory    peak=%.1fMB", peak
        if (nidle) printf " idle=%.1fMB (latest of %d)", idle, nidle
        if (nsess > 1) printf " growth=%+.1fMB over %d sessions (pid %s)", last - first, nsess - 1, lastpid
        printf "\n"
      }
    }'
