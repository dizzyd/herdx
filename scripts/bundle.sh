#!/usr/bin/env bash
# Assembles HerdX.app around the SwiftPM executable.
#
# A bundle is not optional here: an unbundled binary cannot own a menu bar or
# reliably activate, both of which this app needs.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-debug}"
APP="$ROOT/build/HerdX.app"

if [ "$CONFIG" = release ]; then
  cargo build --manifest-path "$ROOT/Cargo.toml" -p herdr-core --release
else
  cargo build --manifest-path "$ROOT/Cargo.toml" -p herdr-core
fi
# SwiftPM does not know about libherdr_core.a: it arrives through a raw `-L`
# flag, so it is not a tracked input and a Rust-only change leaves the old
# code linked in with no warning. Removing the product forces a relink.
rm -f "$ROOT/HerdX/.build/$CONFIG/HerdX"
(cd "$ROOT/HerdX" && swift build -c "$CONFIG")

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/HerdX/.build/$CONFIG/HerdX" "$APP/Contents/MacOS/HerdX"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>HerdX</string>
  <key>CFBundleDisplayName</key><string>HerdX</string>
  <key>CFBundleIdentifier</key><string>dev.herdr.herdx</string>
  <key>CFBundleExecutable</key><string>HerdX</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

echo "built $APP"
