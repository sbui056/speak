#!/bin/sh
# Rewrite quality check: runs the fixed dictations in scripts/corpus/rewrite.json
# through the real on-device model (Concise and Polished, exactly as a session
# would), then summarizes. Needs Apple Intelligence on. Re-run after any prompt
# change or macOS update and compare with an earlier report.
# A case may set "language" (e.g. "es_ES"), as a session passes it. Rejected replies
# end with raw=<reply>.
# Usage: scripts/corpus.sh [report-file]   (default: print only)
set -eu
cd "$(dirname "$0")/.."
report=${1:-}

swift build -c debug >/dev/null
bin="$(swift build -c debug --show-bin-path)/Speak"
out=$(mktemp -t speak-corpus)
trap 'rm -f "$out"' EXIT
SPEAK_CORPUS=scripts/corpus/rewrite.json "$bin" >"$out" 2>/dev/null
grep -q . "$out" || { echo "corpus: no results" >&2; exit 1; }
grep -v -E "^ok	" "$out" || true
awk -F '\t' '
  function sort(a, n,   i, j, t) { for (i = 2; i <= n; i++) { t = a[i]; for (j = i - 1; j >= 1 && a[j] > t; j--) a[j + 1] = a[j]; a[j + 1] = t } }
  function median(a, n) { sort(a, n); return (n % 2) ? a[(n + 1) / 2] : (a[n / 2] + a[n / 2 + 1]) / 2 }
  /^corpus:/ { print; next }
  { m = $2; verdict[m, $1]++; modes[m] = 1
    f = $4; sub(/^first=/, "", f); sub(/s$/, "", f); if (f != "-") first[m, ++nf[m]] = f + 0
    t = $5; sub(/^total=/, "", t); sub(/s$/, "", t); total[m, ++nt[m]] = t + 0 }
  END {
    for (m in modes) {
      for (i = 1; i <= nf[m]; i++) a[i] = first[m, i]; mf = nf[m] ? median(a, nf[m]) : 0
      for (i = 1; i <= nt[m]; i++) b[i] = total[m, i]; mt = median(b, nt[m])
      printf "%-9s ok=%d unfixed=%d dropped=%d answered=%d fallback=%d  median first=%.3fs total=%.3fs\n", m,
        verdict[m, "ok"], verdict[m, "unfixed"], verdict[m, "dropped"], verdict[m, "answered"], verdict[m, "fallback"], mf, mt
    }
  }' "$out" | sort
if [ -n "$report" ]; then cp "$out" "$report"; echo "full report: $report"; fi
