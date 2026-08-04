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
#     inside the mounted image. Only then is the name claimed — with a hard link, whose EEXIST
#     failure is kernel-atomic, so no exists-check-then-move window exists and concurrent runs
#     cannot overwrite each other.
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
# Test seams (all honoured ONLY when TRICAP_PACKAGE_TEST=1; ignored otherwise):
#   - the external verdict tools can be overridden by the gate probe
#     (scripts/diagnostics/package-release-gate-probe.sh); without the flag the absolute system
#     paths are used, so a poisoned PATH cannot substitute the real tools;
#   - TRICAP_DIST_OVERRIDE relocates build/dist into the probe's isolated directory, so the
#     probe can never touch real products; normal runs always use the real build/dist.
# Test mode also has a HARD BARRIER on the official name: even if every stub reports success,
# a TRICAP_PACKAGE_TEST=1 run can only ever produce TriCap-<version>-TEST-PROBE.dmg and never
# prints "RELEASE PRODUCT". Faked verdicts therefore cannot manufacture anything that could be
# mistaken for a distributable artefact.
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
TEST_MODE=0
if [[ "${TRICAP_PACKAGE_TEST:-}" == "1" ]]; then
  TEST_MODE=1
  SECURITY_BIN="${TRICAP_SECURITY:-/usr/bin/security}"
  CODESIGN_BIN="${TRICAP_CODESIGN:-/usr/bin/codesign}"
  SPCTL_BIN="${TRICAP_SPCTL:-/usr/sbin/spctl}"
  read -r -a NOTARY_CMD <<< "${TRICAP_NOTARYTOOL:-xcrun notarytool}"
  read -r -a STAPLE_CMD <<< "${TRICAP_STAPLER:-xcrun stapler}"
  echo "NOTE: TRICAP_PACKAGE_TEST=1 — tool overrides are honoured; this run can only produce TEST-PROBE artefacts." >&2
else
  SECURITY_BIN="/usr/bin/security"
  CODESIGN_BIN="/usr/bin/codesign"
  SPCTL_BIN="/usr/sbin/spctl"
  NOTARY_CMD=(xcrun notarytool)
  STAPLE_CMD=(xcrun stapler)
fi

VERSION="$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)"
# The dist directory is overridable ONLY in test mode, so the gate probe can run every scenario
# inside an isolated throwaway directory. A normal run ignores the override unconditionally:
# real products always live in the real build/dist, and nothing a caller exports can move them.
if [[ "$TEST_MODE" == "1" && -n "${TRICAP_DIST_OVERRIDE:-}" ]]; then
  DIST="$TRICAP_DIST_OVERRIDE"
else
  DIST="$ROOT/build/dist"
fi
APP_SRC="$ROOT/build/release/TriCap.app"

fail() { echo "!! $1" >&2; exit 1; }

# ---------------------------------------------------------------- cleanup trap
# Everything this run creates lives under $TMP_ROOT until the final rename; the trap removes it
# on every exit path and detaches any volume this run mounted. It deliberately knows nothing
# about the rest of build/dist.
TMP_ROOT=""
MOUNTPOINT=""

# Detach a mountpoint and only return once the kernel agrees it is gone. `hdiutil detach` can
# report success while the unmount is still completing, and a `rm -rf` racing that window
# deletes the backing image out from under a live volume and leaves an undeletable mountpoint
# behind — observed, not theorised. The mount table is compared by PHYSICAL path, because it
# prints /private/var/... where $TMPDIR says /var/... .
detach_mountpoint() { # <mountpoint> — returns 0 once unmounted
  local mp="$1" phys i
  phys="$(cd "$mp" 2>/dev/null && pwd -P)" || phys="$mp"
  for i in 1 2 3 4 5 6 8 10; do
    /sbin/mount | grep -Fq " $phys " || return 0
    if [[ "$i" -le 2 ]]; then
      hdiutil detach -quiet "$mp" 2>/dev/null || true
    else
      hdiutil detach -quiet -force "$mp" 2>/dev/null || true
    fi
    sleep 0.4
  done
  ! /sbin/mount | grep -Fq " $phys "
}

release_resources() {
  # Detach unconditionally when a mountpoint was assigned (an earlier version consulted the
  # mount table with the symlinked /var path, never matched, skipped the detach, and rm -rf
  # clawed at a live read-only volume). detach_mountpoint blocks until the volume is truly
  # gone, so the rm below cannot race the unmount.
  if [[ -n "$MOUNTPOINT" ]]; then
    detach_mountpoint "$MOUNTPOINT" || true
  fi
  if [[ -n "$TMP_ROOT" && -d "$TMP_ROOT" ]]; then
    rm -rf "$TMP_ROOT" 2>/dev/null || { sleep 1; rm -rf "$TMP_ROOT" 2>/dev/null || true; }
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

  OFFICIAL_DMG="$DIST/TriCap-$VERSION.dmg"
  # Refuse to shadow a file that may already have shipped. Deleting or replacing a published
  # artefact is a human decision, not a packaging side effect. Checked in test mode too, so the
  # refusal logic itself stays testable.
  [[ -e "$OFFICIAL_DMG" ]] && fail "$OFFICIAL_DMG already exists.
   Refusing to overwrite a previously produced release artefact. Move it away deliberately
   (or bump CFBundleShortVersionString) and re-run."
  if [[ "$TEST_MODE" == "1" ]]; then
    # HARD BARRIER: a test-mode run never owns the official name, no matter what the stubs said.
    FINAL_DMG="$DIST/TriCap-$VERSION-TEST-PROBE.dmg"
  else
    FINAL_DMG="$OFFICIAL_DMG"
  fi
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
  detach_mountpoint "$MOUNTPOINT" || fail "could not unmount the assessment volume."
  MOUNTPOINT=""
fi

# ---------------------------------------------------------------- promote (kernel-atomic claim)
# `ln` creates a hard link and fails with EEXIST atomically in the kernel — unlike an exists
# check followed by `mv`, which a concurrent run can slip between (TOCTOU), and unlike `mv -n`,
# whose no-clobber is a userspace pre-check. TMP_ROOT lives under $DIST, so source and target
# are always on one volume. Exactly one of any number of racing runs can win the name; every
# loser exits non-zero and its temp artefact is removed by the trap.
claim_exclusively() { # <src> <dst>
  if ! ln "$1" "$2" 2>/dev/null; then
    fail "could not claim $2 — it already exists (another run may have produced it). Refusing to overwrite."
  fi
  rm -f -- "$1"
}

if [[ "$MODE" == "release" ]]; then
  if [[ "$TEST_MODE" == "1" ]]; then
    # Structural barrier, not just naming: this branch cannot mint the official name or the
    # release banner even if a future edit breaks the FINAL_DMG assignment above.
    [[ "$FINAL_DMG" == *"-TEST-PROBE.dmg" ]] \
      || fail "test mode attempted to promote to a non-TEST-PROBE name; refusing."
    claim_exclusively "$TMP_DMG" "$FINAL_DMG"
    echo "==> TEST-PROBE PRODUCT (stubbed verdicts, NOT a release, do not distribute): $FINAL_DMG"
  else
    claim_exclusively "$TMP_DMG" "$FINAL_DMG"
    echo "==> RELEASE PRODUCT: $FINAL_DMG"
  fi
else
  # A local-test artefact may replace an older local-test artefact — never anything else. The
  # claim is still exclusive; only this run's own stale product is cleared first.
  rm -f -- "$FINAL_DMG"
  claim_exclusively "$TMP_DMG" "$FINAL_DMG"
  cat <<EOF
==> LOCAL TEST PRODUCT: $FINAL_DMG
    Ad-hoc signature, arm64 only, NOT notarized. Gatekeeper on any other machine will
    refuse it, and should. Do not upload this file anywhere.
EOF
fi
