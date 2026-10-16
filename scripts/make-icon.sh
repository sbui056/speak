#!/bin/sh
# Regenerates Resources/AppIcon.icns from Resources/draw-icon.swift.
# bundle.sh copies the .icns into the app when it exists.
set -eu
cd "$(dirname "$0")/.."

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
set=$work/AppIcon.iconset
mkdir "$set"

swift Resources/draw-icon.swift "$work/icon-1024.png"
for s in 16 32 128 256 512; do
  sips -z $s $s "$work/icon-1024.png" --out "$set/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d "$work/icon-1024.png" --out "$set/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$set" -o Resources/AppIcon.icns
echo "Wrote Resources/AppIcon.icns"
