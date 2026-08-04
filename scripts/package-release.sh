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
#     spctl. If ANY prerequisite or verification fails the script FAILS CLOSED: no product is
#     produced that could be mistaken for a distributable one.
#
#   LOCAL TEST         ./scripts/package-release.sh --local-test
#     Produces build/dist/TriCap-<version>-LOCAL-TEST-adhoc.dmg from the ad-hoc-signed build.
#     The name says what it is. It will not pass Gatekeeper on another machine, and nothing in
#     this repository attempts to bypass Gatekeeper — that is the point.
#
# Fail-closed mechanics (the part a reviewer should check):
#   - The DMG is built under a unique temporary directory inside build/dist and carries a
#     temporary name. The official TriCap-<version>.dmg path does not exist until notarization
#     has come back "Accepted", the staple has validated, and Gatekeeper has assessed the app
#     inside the mounted image. Only then is the file renamed into place — one atomic rename on
#     the same volume.
#   - An EXIT/INT/TERM trap detaches any volume this run mounted and deletes this run's
#     temporary directory, on every failure, signal and normal path. Nothing else in build/dist
#     is ever touched: earlier release products and unrelated files survive every outcome.
#   - notarytool output is parsed as JSON and the final status must literally be "Accepted".
#     A non-Accepted status, unparsable output, or a failed command all exit non-zero with no
#     officially-named product on disk.
#   - If the official target file already exists, the script refuses to run rather than
#     silently overwrite a previously shipped artefact.
#
# Credentials policy: this script NEVER accepts, reads, echoes or stores credentials. Signing
# uses an identity already present in the keychain, referenced by name via
# CODESIGN_IDENTITY_RELEASE. Notarization uses a keychain profile created once, interactively:
#     xcrun notarytool store-credentials <profile-name>
# and referenced here only by its NAME via TRICAP_NOTARY_PROFILE. Do not paste passwords, API
# keys or team IDs into this script, its arguments, or CI logs.
#
# Test seams: the external verdict tools can be overridden for the failure-injection probe
# (scripts/diagnostics/package-release-gate-probe.sh), and ONLY when TRICAP_PACKAGE_TEST=1 is
# also set. Without that flag the overrides are ignored and the absolute system paths are used,
# so a poisoned PATH cannot substitute the real tools. Running the harness with all-success
# stubs would be operator fraud, not a script defect — the probe injects failures only.
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

# ---------------------------------------------------------------- tools (absolute; test seam)
if [[ "${TRICAP_PACKAGE_TEST:-}" == "1" ]]; then
  SECURITY_BIN="${TRICAP_SECURITY:-/usr/bin/security}"
  CODESIGN_BIN="${TRICAP_CODESIGN:-/usr/bin/codesign}"
  SPCTL_BIN="${TRICAP_SPCTL:-/usr/sbin/spctl}"
  read -r -a NOTARY_CMD <<< "${TRICAP_NOTARYTOOL:-xcrun notarytool}"
  read -r -a STAPLE_CMD <<< "${TRICAP_STAPLER:-xcrun stapler}"
  echo "NOTE: TRICAP_PACKAGE_TEST=1 — tool overrides are honoured; any artefact from this run is a test artefact." >&2
else
  SECURITY_BIN="/usr/bin/security"
  CODESIGN_BIN="/usr/bin/codesign"
  SPCTL_BIN="/usr/sbin/spctl"
  NOTARY_CMD=(xcrun notarytool)
  STAPLE_CMD=(xcrun stapler)
fi

VERSION="$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)"
DIST="$ROOT/build/dist"
APP_SRC="$ROOT/build/release/TriCap.app"

fail() { echo "!! $1" >&2; exit 1; }

# ---------------------------------------------------------------- cleanup trap
# Everything this run creates lives under $TMP_ROOT until the final rename; the trap removes it
# on every exit path and detaches any volume this run mounted. It deliberately knows nothing
# about the rest of build/dist.
TMP_ROOT=""
MOUNTPOINT=""
release_resources() {
  if [[ -n "$MOUNTPOINT" ]] && /sbin/mount | grep -Fq " $MOUNTPOINT "; then
    hdiutil detach -quiet -force "$MOUNTPOINT" 2>/dev/null || true
  fi
  if [[ -n "$TMP_ROOT" && -d "$TMP_ROOT" ]]; then
    rm -rf "$TMP_ROOT"
  fi
}
on_exit() {
  local code=$?
  release_resources
  exit "$code"
}
# Signals get their own handlers: a shared handler that re-read `$?` reported the last command's
# status — usually 0 — so a ^C or a CI timeout during the upload looked like SUCCESS to the
# caller. The gate probe's interruption scenario caught exactly that. Exit 128+signal, always.
on_signal() {
  trap - EXIT
  release_resources
  exit $((128 + $1))
}
trap on_exit EXIT
trap 'on_signal 2' INT
trap 'on_signal 15' TERM

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

  "$SECURITY_BIN" find-identity -v -p codesigning | grep -Fq "$IDENTITY" \
    || fail "the identity '$IDENTITY' is not present in the keychain (security find-identity)."

  [[ -n "$PROFILE" ]] || fail "TRICAP_NOTARY_PROFILE is not set.
   Create one interactively with: xcrun notarytool store-credentials <name>
   and pass the NAME only. This script never handles the credentials themselves."

  FINAL_DMG="$DIST/TriCap-$VERSION.dmg"
  # Refuse to shadow a file that may already have shipped. Deleting or replacing a published
  # artefact is a human decision, not a packaging side effect.
  [[ -e "$FINAL_DMG" ]] && fail "$FINAL_DMG already exists.
   Refusing to overwrite a previously produced release artefact. Move it away deliberately
   (or bump CFBundleShortVersionString) and re-run."
else
  FINAL_DMG="$DIST/TriCap-$VERSION-LOCAL-TEST-adhoc.dmg"
fi

# ---------------------------------------------------------------- build
echo "==> building the release app bundle"
./scripts/build-app.sh release >/dev/null
[[ -d "$APP_SRC" ]] || fail "expected $APP_SRC after build-app.sh"

mkdir -p "$DIST"
TMP_ROOT="$(mktemp -d "$DIST/.pkg-tmp-XXXXXX")"
STAGING="$TMP_ROOT/staging"
TMP_DMG="$TMP_ROOT/TriCap-unverified.dmg"
mkdir -p "$STAGING"
cp -R "$APP_SRC" "$STAGING/TriCap.app"

# ---------------------------------------------------------------- sign
if [[ "$MODE" == "release" ]]; then
  echo "==> codesign (Developer ID, Hardened Runtime, secure timestamp)"
  "$CODESIGN_BIN" --force --deep --options runtime --timestamp \
    --sign "$IDENTITY" "$STAGING/TriCap.app"
else
  echo "==> keeping the ad-hoc signature (LOCAL TEST build)"
fi

echo "==> codesign --verify --deep --strict"
"$CODESIGN_BIN" --verify --deep --strict --verbose=2 "$STAGING/TriCap.app"

# ---------------------------------------------------------------- DMG with drag-to-install layout
echo "==> building DMG (temporary name until verified)"
ln -s /Applications "$STAGING/Applications"
hdiutil create -quiet -volname "TriCap" -srcfolder "$STAGING" -format UDZO -ov "$TMP_DMG"

# ---------------------------------------------------------------- notarize + staple (release only)
if [[ "$MODE" == "release" ]]; then
  echo "==> notarytool submit (waits for the verdict)"
  SUBMIT_JSON="$TMP_ROOT/notary-result.json"
  "${NOTARY_CMD[@]}" submit "$TMP_DMG" --keychain-profile "$PROFILE" --wait \
      --output-format json > "$SUBMIT_JSON" \
    || fail "notarytool submit failed; nothing was produced. See: xcrun notarytool log"

  STATUS="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("status",""))' \
      "$SUBMIT_JSON" 2>/dev/null || true)"
  [[ "$STATUS" == "Accepted" ]] \
    || fail "notarization status is '${STATUS:-<unparsable>}', not 'Accepted'; the DMG must not be distributed.
   See: xcrun notarytool log"

  echo "==> stapling"
  "${STAPLE_CMD[@]}" staple "$TMP_DMG" || fail "stapler staple failed; nothing was produced."
  "${STAPLE_CMD[@]}" validate "$TMP_DMG" || fail "stapler validate failed; nothing was produced."

  echo "==> Gatekeeper assessment of the app inside the mounted image"
  MOUNTPOINT="$TMP_ROOT/mnt"
  mkdir -p "$MOUNTPOINT"
  hdiutil attach -quiet -nobrowse -mountpoint "$MOUNTPOINT" "$TMP_DMG"
  "$SPCTL_BIN" --assess --type execute --verbose=2 "$MOUNTPOINT/TriCap.app" \
    || fail "spctl rejected the app; do not distribute."
  hdiutil detach -quiet "$MOUNTPOINT"
  MOUNTPOINT=""
fi

# ---------------------------------------------------------------- promote (atomic, same volume)
if [[ "$MODE" == "release" ]]; then
  # Re-check: a parallel run may have produced it while this one worked.
  [[ -e "$FINAL_DMG" ]] && fail "$FINAL_DMG appeared while packaging; refusing to overwrite it."
  mv "$TMP_DMG" "$FINAL_DMG"
  echo "==> RELEASE PRODUCT: $FINAL_DMG"
else
  # A local-test artefact may replace an older local-test artefact — never anything else.
  rm -f "$FINAL_DMG"
  mv "$TMP_DMG" "$FINAL_DMG"
  cat <<EOF
==> LOCAL TEST PRODUCT: $FINAL_DMG
    Ad-hoc signature, arm64 only, NOT notarized. Gatekeeper on any other machine will
    refuse it, and should. Do not upload this file anywhere.
EOF
fi
