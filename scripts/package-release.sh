#!/usr/bin/env bash
#
# package-release.sh — wrap TriCap.app in the distributable DMG.
#
# The DMG contains TriCap.app and an /Applications symlink (the standard drag-to-install layout).
# All products land in build/dist/, which is gitignored: generated artefacts are never committed.
#
# Two modes, chosen explicitly — there is no in-between:
#
#   RELEASE (default)  ./scripts/package-release.sh
#     Requires a Developer ID Application identity and a notarytool keychain profile. Signs with
#     Hardened Runtime and a secure timestamp, notarizes, staples, and verifies with codesign and
#     spctl. If ANY prerequisite is missing the script FAILS CLOSED: no product is produced that
#     could be mistaken for a distributable one.
#
#   LOCAL TEST         ./scripts/package-release.sh --local-test
#     Produces build/dist/TriCap-<version>-LOCAL-TEST-adhoc.dmg from the ad-hoc-signed build.
#     The name says what it is. It will not pass Gatekeeper on another machine, and nothing in
#     this repository attempts to bypass Gatekeeper — that is the point.
#
# Credentials policy: this script NEVER accepts, reads, echoes or stores credentials. Signing uses
# an identity already present in the keychain, referenced by name via CODESIGN_IDENTITY_RELEASE.
# Notarization uses a keychain profile created once, interactively, by the user:
#     xcrun notarytool store-credentials <profile-name>
# and referenced here only by its NAME via TRICAP_NOTARY_PROFILE. Do not paste passwords, API
# keys or team IDs into this script, its arguments, or CI logs.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

MODE="release"
if [[ "${1:-}" == "--local-test" ]]; then
  MODE="local-test"
elif [[ -n "${1:-}" ]]; then
  echo "usage: $0 [--local-test]" >&2
  exit 2
fi

VERSION="$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)"
DIST="$ROOT/build/dist"
STAGING="$DIST/staging"
APP_SRC="$ROOT/build/release/TriCap.app"

fail() { echo "!! $1" >&2; exit 1; }

# ---------------------------------------------------------------- release-mode gates (fail closed)
if [[ "$MODE" == "release" ]]; then
  IDENTITY="${CODESIGN_IDENTITY_RELEASE:-}"
  PROFILE="${TRICAP_NOTARY_PROFILE:-}"

  [[ -n "$IDENTITY" ]] || fail "CODESIGN_IDENTITY_RELEASE is not set.
   Release packaging needs a 'Developer ID Application' identity in the keychain.
   No identity → no release product. For a machine-local build use: $0 --local-test"

  case "$IDENTITY" in
    "Developer ID Application"*) ;;
    *) fail "CODESIGN_IDENTITY_RELEASE must be a 'Developer ID Application' identity (got: $IDENTITY).
   Mac App Store and Apple Development identities cannot be notarized for direct distribution." ;;
  esac

  security find-identity -v -p codesigning | grep -Fq "$IDENTITY" \
    || fail "the identity '$IDENTITY' is not present in the keychain (security find-identity)."

  [[ -n "$PROFILE" ]] || fail "TRICAP_NOTARY_PROFILE is not set.
   Create one interactively with: xcrun notarytool store-credentials <name>
   and pass the NAME only. This script never handles the credentials themselves."
fi

# ---------------------------------------------------------------- build
echo "==> building the release app bundle"
./scripts/build-app.sh release >/dev/null
[[ -d "$APP_SRC" ]] || fail "expected $APP_SRC after build-app.sh"

rm -rf "$DIST"
mkdir -p "$STAGING"
cp -R "$APP_SRC" "$STAGING/TriCap.app"

# ---------------------------------------------------------------- sign
if [[ "$MODE" == "release" ]]; then
  echo "==> codesign (Developer ID, Hardened Runtime, secure timestamp)"
  codesign --force --deep --options runtime --timestamp \
    --sign "$IDENTITY" "$STAGING/TriCap.app"
  DMG="$DIST/TriCap-$VERSION.dmg"
else
  echo "==> keeping the ad-hoc signature (LOCAL TEST build)"
  DMG="$DIST/TriCap-$VERSION-LOCAL-TEST-adhoc.dmg"
fi

echo "==> codesign --verify --deep --strict"
codesign --verify --deep --strict --verbose=2 "$STAGING/TriCap.app"

# ---------------------------------------------------------------- DMG with drag-to-install layout
echo "==> building DMG"
ln -s /Applications "$STAGING/Applications"
hdiutil create -quiet -volname "TriCap" -srcfolder "$STAGING" -format UDZO -ov "$DMG"
rm -rf "$STAGING"

# ---------------------------------------------------------------- notarize + staple (release only)
if [[ "$MODE" == "release" ]]; then
  echo "==> notarytool submit (waits for the verdict)"
  xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait \
    || fail "notarization was not accepted; the DMG must not be distributed. See: xcrun notarytool log"

  echo "==> stapling"
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"

  echo "==> Gatekeeper assessment"
  ASSESS_DIR="$(mktemp -d)"
  hdiutil attach -quiet -nobrowse -mountpoint "$ASSESS_DIR" "$DMG"
  spctl --assess --type execute --verbose=2 "$ASSESS_DIR/TriCap.app" \
    || { hdiutil detach -quiet "$ASSESS_DIR"; fail "spctl rejected the app; do not distribute."; }
  hdiutil detach -quiet "$ASSESS_DIR"
  echo "==> RELEASE PRODUCT: $DMG"
else
  cat <<EOF
==> LOCAL TEST PRODUCT: $DMG
    Ad-hoc signature, arm64 only, NOT notarized. Gatekeeper on any other machine will
    refuse it, and should. Do not upload this file anywhere.
EOF
fi
