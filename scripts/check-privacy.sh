#!/bin/sh
# Fails if the code could send data off the machine, log transcript text publicly,
# write audio to disk, or if the core module reaches the system directly instead of through protocols.
set -u
cd "$(dirname "$0")/.."

fail=0
report() { echo "check-privacy: $1" >&2; fail=1; }

# 1. No networking code anywhere in the app.
if hits=$(grep -rnE '^[[:space:]]*(@preconcurrency[[:space:]]+)?import[[:space:]]+Network\b|URLSession|NWConnection|NWListener|CFSocket|CFStream' Sources); then
  report "networking code found:"; echo "$hits" >&2
fi

# 2. No network entitlements.
if grep -qE 'network\.(client|server)' Resources/Speak.entitlements; then
  report "network entitlement found in Resources/Speak.entitlements"
fi

# 3. Transcript-like values must never be logged with .public privacy.
#    Only enums, numbers, and durations may be public.
if hits=$(grep -rnEi '\\\((transcript|text|literal|delivered|partial|term|terms|word|words|cleaned|rewrite|prompt)[^)]*privacy:[[:space:]]*\.public' Sources); then
  report "transcript-like value logged as .public:"; echo "$hits" >&2
fi

# 4. SpeakCore stays free of UI and system frameworks.
if [ -d Sources/SpeakCore ] && hits=$(grep -rnE '^[[:space:]]*(@preconcurrency[[:space:]]+)?import[[:space:]]+(AppKit|SwiftUI|AVFoundation|AVFAudio|Speech|FoundationModels|Cocoa)\b' Sources/SpeakCore); then
  report "SpeakCore imports a system UI/media framework:"; echo "$hits" >&2
fi

# 5. Audio is never written to disk: the mic and speech adapters do no file I/O.
if hits=$(grep -nE 'AVAudioFile|AVAudioRecorder|FileManager|FileHandle|write\(to|\.write\(|fopen|createFile' Sources/Speak/EngineAudioSource.swift Sources/Speak/SpeechEngine.swift); then
  report "file I/O in the audio path:"; echo "$hits" >&2
fi

if [ "$fail" -ne 0 ]; then exit 1; fi
echo "check-privacy: OK"
