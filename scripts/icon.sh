#!/usr/bin/env bash
# Regenerates assets/HerdX.icns from scripts/icon.swift.
#
# Not part of the build: the icon changes once in a blue moon, and making every
# `swift build` shell out to AppKit to redraw ten PNGs would cost more than it
# is worth. Run this when the drawing changes, and commit the result.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ICONSET="$(mktemp -d)/HerdX.iconset"
OUT="$ROOT/assets/HerdX.icns"

mkdir -p "$ICONSET" "$ROOT/assets"
swift "$ROOT/scripts/icon.swift" "$ICONSET"
iconutil --convert icns "$ICONSET" --output "$OUT"
rm -rf "$(dirname "$ICONSET")"

echo "wrote $OUT"
