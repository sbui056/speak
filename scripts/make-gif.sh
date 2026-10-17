#!/bin/sh
# Turns a screen recording into a README GIF (two-pass palette, looped).
# Usage: scripts/make-gif.sh <in.mov> <out.gif> [width=800] [from-seconds] [to-seconds]
# If the result is over 5 MB it retries at 10 fps and a narrower width.
set -eu
in=${1:?usage: make-gif.sh in.mov out.gif [width] [from] [to]}
out=${2:?usage: make-gif.sh in.mov out.gif [width] [from] [to]}
width=${3:-800}
trim=""
[ -n "${4:-}" ] && trim="-ss $4"
[ -n "${5:-}" ] && trim="$trim -to $5"
command -v ffmpeg >/dev/null || { echo "make-gif: needs ffmpeg (brew install ffmpeg)"; exit 1; }

convert() { # fps width
  # shellcheck disable=SC2086
  ffmpeg -loglevel error -y $trim -i "$in" -vf \
    "fps=$1,scale=$2:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4" \
    -loop 0 "$out"
}

convert 12 "$width"
limit=$((5 * 1024 * 1024))
if [ "$(stat -f %z "$out")" -gt "$limit" ]; then
  echo "make-gif: over 5 MB, retrying at 10 fps and 640 px"
  convert 10 640
fi
size=$(stat -f %z "$out")
echo "make-gif: $out $((size / 1024)) KB"
[ "$size" -le "$limit" ] || { echo "make-gif: still over 5 MB; trim it with the from/to arguments"; exit 1; }
