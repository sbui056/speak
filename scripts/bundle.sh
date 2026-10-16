#!/bin/sh
# Builds, signs, and installs Speak.app to ~/Applications, then relaunches it.
# The fixed bundle ID, install path, and signing identity keep permission grants
# across rebuilds. Testing permissions with the raw build binary would grant them
# to Terminal instead.
set -eu
cd "$(dirname "$0")/.."

IDENTITY=SpeakDev
APP_NAME=Speak
DEST="$HOME/Applications/$APP_NAME.app"

if ! security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
  echo "bundle: signing identity '$IDENTITY' not found. Run scripts/make-identity.sh first." >&2
  exit 1
fi

swift build -c release
bin="$(swift build -c release --show-bin-path)/$APP_NAME"

version=$(git describe --tags --always --dirty 2>/dev/null | sed 's/^v//' || true)
case "$version" in [0-9]*) ;; *) version=0.0.0 ;; esac
build=$(git rev-list --count HEAD 2>/dev/null || echo 1)

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
app="$stage/$APP_NAME.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/$APP_NAME"
sed -e "s/__VERSION__/$version/" -e "s/__BUILD__/$build/" Resources/Info.plist > "$app/Contents/Info.plist"
plutil -lint -s "$app/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$app/Contents/Resources/"; fi

codesign --force --options runtime --timestamp=none \
  --entitlements Resources/Speak.entitlements -s "$IDENTITY" "$app"
codesign --verify --strict "$app"

# Quit the running copy so the new one replaces it cleanly.
osascript -e "tell application id \"io.github.sbui056.speak\" to quit" >/dev/null 2>&1 || true
for _ in 1 2 3 4 5 6 7 8 9 10; do
  pgrep -xq "$APP_NAME" || break
  sleep 0.3
done
pkill -x "$APP_NAME" 2>/dev/null || true

mkdir -p "$HOME/Applications"
rm -rf "$DEST"
ditto "$app" "$DEST"
open "$DEST"
echo "Installed and launched $DEST ($version, build $build)"
