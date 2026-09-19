#!/usr/bin/env bash
# Assembles HerdX.app around the SwiftPM executable.
#
# A bundle is not optional here: an unbundled binary cannot own a menu bar or
# reliably activate, both of which this app needs.
#
#   ./scripts/bundle.sh                 debug, host arch
#   ./scripts/bundle.sh release         release, host arch
#   HERDX_UNIVERSAL=1 ./scripts/bundle.sh release    release, arm64 + x86_64
#
# Environment:
#   HERDX_UNIVERSAL=1   build a fat arm64 + x86_64 app (release distribution)
#   HERDX_VERSION       CFBundleShortVersionString, default 0.1.0
#   HERDX_BUILD         CFBundleVersion, default HERDX_VERSION
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-debug}"
APP="$ROOT/build/HerdX.app"
VERSION="${HERDX_VERSION:-0.1.0}"
BUILD_NUMBER="${HERDX_BUILD:-$VERSION}"
UNIVERSAL="${HERDX_UNIVERSAL:-0}"

# Plain strings, not arrays: /bin/bash on macOS (and on the CI runners) is 3.2,
# where expanding an empty array trips `set -u`. No flag here contains a space.
CARGO_FLAGS=""
[ "$CONFIG" = release ] && CARGO_FLAGS="--release"
SWIFT_FLAGS=""

if [ "$UNIVERSAL" = 1 ]; then
  # SwiftPM will happily emit a fat executable, but it links one libherdr_core.a
  # for both slices, so the staticlib has to be fat too. cargo cannot do that in
  # one pass: build each slice, then lipo them into a directory of our own.
  #
  # The pairs carry both spellings because Rust and SwiftPM disagree: aarch64
  # against arm64. Handing SwiftPM the Rust name is not an error it reports — it
  # builds the other slice and returns a thin binary that lipo calls fine.
  for pair in aarch64-apple-darwin:arm64 x86_64-apple-darwin:x86_64; do
    target="${pair%%:*}"
    cargo build --manifest-path "$ROOT/Cargo.toml" -p herdr-core \
      --target "$target" $CARGO_FLAGS
    SWIFT_FLAGS="$SWIFT_FLAGS --arch ${pair##*:}"
  done
  CORE_LIB_DIR="$ROOT/target/universal/$CONFIG"
  mkdir -p "$CORE_LIB_DIR"
  lipo -create -output "$CORE_LIB_DIR/libherdr_core.a" \
    "$ROOT/target/aarch64-apple-darwin/$CONFIG/libherdr_core.a" \
    "$ROOT/target/x86_64-apple-darwin/$CONFIG/libherdr_core.a"
else
  cargo build --manifest-path "$ROOT/Cargo.toml" -p herdr-core $CARGO_FLAGS
  CORE_LIB_DIR="$ROOT/target/$CONFIG"
fi

# Ask SwiftPM where it will put the binary rather than guessing: a universal
# build lands under .build/apple/Products/<Config> and a thin one under
# .build/<triple>/<config>, and which of those is current has changed with the
# toolchain before now.
BIN_DIR="$(cd "$ROOT/HerdX" && HERDX_CORE_LIB_DIR="$CORE_LIB_DIR" \
  swift build -c "$CONFIG" $SWIFT_FLAGS --show-bin-path)"
BUILT="$BIN_DIR/HerdX"

# SwiftPM does not know about libherdr_core.a: it arrives through a raw `-L`
# flag, so it is not a tracked input and a Rust-only change leaves the old
# code linked in with no warning. Removing the product forces a relink.
rm -f "$BUILT"
(cd "$ROOT/HerdX" && HERDX_CORE_LIB_DIR="$CORE_LIB_DIR" \
  swift build -c "$CONFIG" $SWIFT_FLAGS)

[ -x "$BUILT" ] || { echo "swift build produced no binary at $BUILT" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILT" "$APP/Contents/MacOS/HerdX"

# The binary links herdr's Apache-2.0 sources (see NOTICE), and section 4(a)
# asks that recipients of the *artifact* get the licence — a copy sitting in the
# repo does nothing for someone who only ever sees the .dmg.
cp "$ROOT/LICENSE" "$ROOT/NOTICE" "$APP/Contents/Resources/"

# Committed rather than drawn here: see scripts/icon.sh. Missing is worth
# stopping for — an app that ships the generic bundle icon looks broken, and
# nothing else in the build would say a word about it.
[ -f "$ROOT/assets/HerdX.icns" ] || {
  echo "assets/HerdX.icns is missing; run scripts/icon.sh" >&2
  exit 1
}
cp "$ROOT/assets/HerdX.icns" "$APP/Contents/Resources/"

# herdr's own notification audio, so both clients make the same noise for the
# same thing. From the pinned submodule rather than a copy of a copy; see NOTICE.
mkdir -p "$APP/Contents/Resources/sounds"
for sound in done request; do
  src="$ROOT/vendor/herdr/assets/sounds/$sound.mp3"
  [ -f "$src" ] || { echo "missing $src; is the submodule checked out?" >&2; exit 1; }
  cp "$src" "$APP/Contents/Resources/sounds/"
done

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>HerdX</string>
  <key>CFBundleDisplayName</key><string>HerdX</string>
  <key>CFBundleIdentifier</key><string>dev.herdr.herdx</string>
  <key>CFBundleExecutable</key><string>HerdX</string>
  <key>CFBundleIconFile</key><string>HerdX</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

ARCHS="$(lipo -archs "$APP/Contents/MacOS/HerdX")"
if [ "$UNIVERSAL" = 1 ]; then
  case " $ARCHS " in
    *" arm64 "*) ;; *) echo "universal build is missing arm64: $ARCHS" >&2; exit 1 ;;
  esac
  case " $ARCHS " in
    *" x86_64 "*) ;; *) echo "universal build is missing x86_64: $ARCHS" >&2; exit 1 ;;
  esac
fi

echo "built $APP ($VERSION, $ARCHS)"
