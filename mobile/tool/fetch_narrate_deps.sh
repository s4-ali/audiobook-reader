#!/usr/bin/env bash
# Fetch the on-device TTS runtime the Narrate feature links against (sherpa-onnx Android AAR).
# It isn't published to Maven Central and is too big to commit, so it lives git-ignored in
# android/app/libs/. Run once before `flutter build apk`.
set -euo pipefail
VERSION=1.13.8
cd "$(dirname "$0")/../android/app"
mkdir -p libs
out="libs/sherpa-onnx-$VERSION.aar"
if [ -f "$out" ]; then echo "already present: $out"; exit 0; fi
curl -fL --progress-bar -o "$out.part" \
  "https://github.com/k2-fsa/sherpa-onnx/releases/download/v$VERSION/sherpa-onnx-$VERSION.aar"
mv "$out.part" "$out"
echo "fetched $out"
