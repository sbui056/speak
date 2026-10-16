#!/bin/sh
# Runs the SpeakCore test suite. With only the Command Line Tools installed, the
# Testing framework lives outside the default search paths, so point the compiler,
# linker, and runtime at it. With Xcode selected (as on CI) a plain run works.
set -eu
cd "$(dirname "$0")/.."

dev=$(xcode-select -p)
case "$dev" in
  */CommandLineTools)
    F="$dev/Library/Developer"
    exec swift test \
      -Xswiftc -F -Xswiftc "$F/Frameworks" \
      -Xlinker -F -Xlinker "$F/Frameworks" \
      -Xlinker -rpath -Xlinker "$F/Frameworks" \
      -Xlinker -rpath -Xlinker "$F/usr/lib" \
      "$@"
    ;;
  *)
    exec swift test "$@"
    ;;
esac
