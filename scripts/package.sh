#!/usr/bin/env bash
# Builds, signs, notarizes and staples a distributable HerdX.dmg.
#
#   HERDX_VERSION=1.2.3 ./scripts/package.sh
#
# The app is notarized and stapled before it goes into the disk image, and the
# disk image is then notarized and stapled in turn. Only stapling the .dmg would
# leave the copy in /Applications relying on an online Gatekeeper check, which
# is exactly the machine-with-no-network case that makes an app look broken on
# first launch.
#
# Signing identity:
#   HERDX_SIGN_IDENTITY   "Developer ID Application: ..." or its SHA-1.
#                         Auto-detected when exactly one is in the keychain.
#   HERDX_KEYCHAIN        keychain to sign from (CI uses a throwaway one).
#
# Notarization credentials, in the order they are tried:
#   HERDX_NOTARY_PROFILE  a `notarytool store-credentials` profile (local use)
#   HERDX_API_KEY_PATH + HERDX_API_KEY_ID + HERDX_API_ISSUER   App Store
#                         Connect API key (what CI uses: no Apple ID, no 2FA,
#                         revocable on its own)
#   HERDX_APPLE_ID + HERDX_APPLE_PASSWORD + HERDX_TEAM_ID      app-specific
#                         password
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${HERDX_VERSION:-0.1.0}"
APP="$ROOT/build/HerdX.app"
DMG="$ROOT/build/HerdX-$VERSION.dmg"

# --- identity ---------------------------------------------------------------

KEYCHAIN_ARGS=""
[ -n "${HERDX_KEYCHAIN:-}" ] && KEYCHAIN_ARGS="--keychain $HERDX_KEYCHAIN"

IDENTITY="${HERDX_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  # `security find-identity` prints `  1) <sha1> "Developer ID Application: ..."`
  FOUND="$(security find-identity -v -p codesigning ${HERDX_KEYCHAIN:-} \
    | grep "Developer ID Application" || true)"
  COUNT="$(printf '%s' "$FOUND" | grep -c . || true)"
  if [ "$COUNT" != 1 ]; then
    echo "set HERDX_SIGN_IDENTITY: found $COUNT Developer ID Application identities" >&2
    printf '%s\n' "$FOUND" >&2
    exit 1
  fi
  IDENTITY="$(printf '%s' "$FOUND" | sed -n 's/.*) \([0-9A-F]*\) ".*/\1/p')"
fi
echo "==> signing as $IDENTITY"

# --- notarization credentials -----------------------------------------------

if [ -n "${HERDX_NOTARY_PROFILE:-}" ]; then
  NOTARY_AUTH="--keychain-profile $HERDX_NOTARY_PROFILE"
elif [ -n "${HERDX_API_KEY_PATH:-}" ]; then
  NOTARY_AUTH="--key $HERDX_API_KEY_PATH --key-id $HERDX_API_KEY_ID --issuer $HERDX_API_ISSUER"
elif [ -n "${HERDX_APPLE_ID:-}" ]; then
  NOTARY_AUTH="--apple-id $HERDX_APPLE_ID --password $HERDX_APPLE_PASSWORD --team-id $HERDX_TEAM_ID"
else
  echo "no notarization credentials; see the header of $0" >&2
  exit 1
fi

# Submits one file and waits; stapling is the caller's job, because what gets
# submitted and what gets stapled are not always the same file. notarytool exits
# non-zero on Invalid, but the reason is only in the log, and a release that
# fails here with "Invalid" and nothing else is the single most time-wasting
# outcome of this script.
notarize() {
  local what="$1" out id status
  echo "==> notarizing $(basename "$what")"
  out="$(xcrun notarytool submit "$what" $NOTARY_AUTH --wait --output-format json)"
  # plutil reads JSON, so this needs nothing that is not already on a Mac.
  id="$(printf '%s' "$out" | plutil -extract id raw -o - - 2>/dev/null || true)"
  status="$(printf '%s' "$out" | plutil -extract status raw -o - - 2>/dev/null || true)"
  if [ "$status" != "Accepted" ]; then
    echo "notarization $status for $(basename "$what") (submission $id):" >&2
    xcrun notarytool log "$id" $NOTARY_AUTH >&2 || true
    exit 1
  fi
}

# --- build ------------------------------------------------------------------

HERDX_UNIVERSAL=1 HERDX_VERSION="$VERSION" "$ROOT/scripts/bundle.sh" release

# --- sign and notarize the app ----------------------------------------------

# No entitlements: HerdX has no nested code, loads no plugins and JITs nothing.
# It spawns ssh and tar, which the hardened runtime does not restrict — those
# are separate processes with their own signatures, not injected code.
codesign --force --timestamp --options runtime $KEYCHAIN_ARGS \
  --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

# notarytool takes an archive, not a bundle; the ditto form is the one that
# preserves the signature.
ZIP="$ROOT/build/HerdX-$VERSION.zip"
rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"
notarize "$ZIP"
# The staple goes on the app, never on the zip: a zip cannot carry a ticket, and
# `stapler staple` on one fails outright, which would abort the release here.
xcrun stapler staple "$APP"
rm -f "$ZIP"

# --- disk image --------------------------------------------------------------

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/HerdX.app"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -volname "HerdX $VERSION" -srcfolder "$STAGE" \
  -fs HFS+ -format UDZO -ov -quiet "$DMG"

codesign --force --timestamp $KEYCHAIN_ARGS --sign "$IDENTITY" "$DMG"
notarize "$DMG"
xcrun stapler staple "$DMG"

# --- verify what actually ships ---------------------------------------------

echo "==> verifying"
xcrun stapler validate "$APP"
xcrun stapler validate "$DMG"
# The question that matters is not "is it signed" but "will Gatekeeper run it".
spctl --assess --type execute --verbose=2 "$APP"

echo "OK $DMG ($(lipo -archs "$APP/Contents/MacOS/HerdX"))"
