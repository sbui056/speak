#!/bin/sh
# Prints release-to-text latency (median and p90) per mode from Speak's own
# timing log lines, the median of each stage, and the memory footprint, then the
# same latency split by utterance length (how long the key was held) with the
# number of rewrites the keep guard rejected in each length bucket.
# Usage: scripts/latency.sh [window] [--start '<time>'] [--file <log>]
#   window   e.g. 3d (default 7d)
#   --start  from a fixed time instead, e.g. one build's install time:
#            --start "$(stat -f '%Sm' -t '%Y-%m-%d %H:%M:%S' ~/Applications/Speak.app)"
#   --file   read a saved `log show` output (or - for stdin) instead of the system log
# Only the bundled app counts, so soak runs of the debug build (scripts/soak.sh)
# never skew it. Previewed rewrites are listed separately: they stop the clock
# when the preview opens, and what happens after the user accepts is reported as "handoff".
set -eu
window=7d start= file=
while [ $# -gt 0 ]; do
  case "$1" in
    --start) start=${2:?--start needs a time}; shift 2 ;;
    --file) file=${2:?--file needs a path}; shift 2 ;;
    -*) echo "usage: scripts/latency.sh [window] [--start '<time>'] [--file <log>]" >&2; exit 2 ;;
    *) window=$1; shift ;;
  esac
done
# The session category has the timing and memory lines; audio has each utterance's
# length ("mic closed … captured_ms=N"), and rewrite has the keep-guard rejections.
predicate='subsystem == "io.github.sbui056.speak" AND category IN {"session", "audio", "rewrite"} AND processImagePath ENDSWITH ".app/Contents/MacOS/Speak"'
span="in the last $window"
[ -n "$start" ] && span="since $start"
[ -n "$file" ] && span="in $file"
if [ -n "$file" ]; then cat -- "$file"
elif [ -n "$start" ]; then /usr/bin/log show --start "$start" --predicate "$predicate" 2>/dev/null
else /usr/bin/log show --last "$window" --predicate "$predicate" 2>/dev/null
fi |
  awk -v span="$span" '
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
    BEGIN {
      nstages = split("finalize cleanup first rewrite activate modwait paste", order, " ")
      # Utterance-length buckets: upper bounds in ms (the last one is open-ended).
      nbuckets = split("3000 6000 10000 20000", upper, " ") + 1
      split("<3s 3-6s 6-10s 10-20s 20s+", bname, " ")
    }
    function bucket(ms,   b) { for (b = 1; b < nbuckets; b++) if (ms < upper[b] + 0) return b; return nbuckets }
    # Each dictation logs its length when the mic closes, then any keep-guard
    # rejection, then its timing line, so they are joined per process in that order.
    / mic closed .*captured_ms=/ {
      for (j = 1; j <= NF; j++) if ($j ~ /^captured_ms=/) { ms = $j; sub(/^captured_ms=/, "", ms); heard[$6] = ms + 0 }
      rejected[$6] = 0
    }
    / rewrite rejected by the guard / { rejected[$6] = 1 }
    / timing dictation mode=/ {
      for (i = 1; i <= NF; i++) if ($i == "dictation") break
      split($(i + 1), m, "="); split($(i + 2), p, "=")
      g = m[2] " " p[2]
      if (!(g in seen)) { seen[g] = 1; groups[++ngroups] = g }
      total = $(i + 3); sub(/s$/, "", total)
      tot[g, ++n[g]] = total + 0
      if ($6 in heard) {
        b = bucket(heard[$6]); ulen[g, ++nlen[g]] = heard[$6] / 1000
        btot[g, b, ++bn[g, b]] = total + 0; brej[g, b] += rejected[$6]
      } else unknown[g]++
      delete heard[$6]; rejected[$6] = 0
      for (j = i + 4; j <= NF; j++) if (split($j, kv, "=") == 2) { sub(/s$/, "", kv[2]); val[g, kv[1], ++cnt[g, kv[1]]] = kv[2] + 0 }
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
      if (ngroups == 0) print "no timing lines " span
      # Groups in a fixed order (sorted by mode, then preview) for stable output.
      for (a = 1; a <= ngroups; a++) for (b = a + 1; b <= ngroups; b++) if (groups[b] < groups[a]) { t = groups[a]; groups[a] = groups[b]; groups[b] = t }
      for (a = 1; a <= ngroups; a++) {
        g = groups[a]; split(g, k, " ")
        for (i = 1; i <= n[g]; i++) { x[i] = tot[g, i]; y[i] = tot[g, i] }
        printf "%-9s preview=%-5s n=%-4d median=%.3fs p90=%.3fs\n", k[1], k[2], n[g], median(x, n[g]), p90(y, n[g])
        s = stages(g); if (s != "") printf "          stage medians:%s\n", s
      }
      if (nh) printf "handoff   n=%-4d stage medians:%s\n", nh, stages("handoff")
      if (peak > 0) {
        printf "memory    peak=%.1fMB", peak
        if (nidle) printf " idle=%.1fMB (latest of %d)", idle, nidle
        if (nsess > 1) printf " growth=%+.1fMB over %d sessions (pid %s)", last - first, nsess - 1, lastpid
        printf "\n"
      }
      # By utterance length, appended so the lines above still compare with older outputs.
      for (a = 1; a <= ngroups; a++) {
        g = groups[a]; split(g, k, " ")
        if (!nlen[g]) continue
        for (i = 1; i <= nlen[g]; i++) { x[i] = ulen[g, i]; y[i] = ulen[g, i] }
        printf "length    %s preview=%s utterance median=%.1fs p90=%.1fs", k[1], k[2], median(x, nlen[g]), p90(y, nlen[g])
        if (unknown[g]) printf " (%d without a length)", unknown[g]
        printf "\n"
        for (b = 1; b <= nbuckets; b++) {
          c = bn[g, b]; if (!c) continue
          for (i = 1; i <= c; i++) { x[i] = btot[g, b, i]; y[i] = btot[g, b, i] }
          printf "          %-6s n=%-4d median=%.3fs p90=%.3fs rejected=%d\n", bname[b], c, median(x, c), p90(y, c), brej[g, b]
        }
      }
    }'
