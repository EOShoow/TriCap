#!/usr/bin/env bash
#
# package-release-gate-probe.sh — prove that package-release.sh fails closed, without needing a
# real Developer ID.
#
# The release pipeline's whole promise is negative: on any failure there must be NO officially
# named DMG, no leftover temp directory, no stray mounted volume, and no damage to files that
# were already in build/dist. That promise cannot wait for a real notarization rejection to be
# tested, so this probe injects each failure with stub tools (honoured by package-release.sh
# only when TRICAP_PACKAGE_TEST=1):
#
#   1. notarytool returns status "Invalid"        → must fail
#   2. notarytool command itself fails            → must fail
#   3. notarytool output is unparsable            → must fail
#   4. stapler fails after an Accepted verdict    → must fail
#   5. spctl rejects the mounted app              → must fail (and the mount must not linger)
#   6. the official target file already exists    → must fail before building anything
#
# After every scenario it asserts: non-zero exit; build/dist/TriCap-<version>.dmg absent; no
# .pkg-tmp-* residue; no TriCap volume mounted; and a pre-seeded "historical release" file is
# byte-identical to before. Finally it runs the real --local-test path and checks the DMG mounts
# with the drag-to-install layout.
#
# Only failure paths are stubbed. There is deliberately no all-success stub scenario: a "release"
# produced by fake tools is operator fraud, and the probe must never manufacture an officially
# named artefact.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

VERSION="$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)"
DIST="$ROOT/build/dist"
OFFICIAL="$DIST/TriCap-$VERSION.dmg"
STUBS="$(mktemp -d)"
FAILURES=0

cleanup() { rm -rf "$STUBS"; }
trap cleanup EXIT

check() { # check <label> <condition-result>
  if [[ "$2" == "0" ]]; then
    echo "  PASS  $1"
  else
    echo "  FAIL  $1"
    FAILURES=$((FAILURES + 1))
  fi
}

# ---------------------------------------------------------------- stub tools
FAKE_IDENTITY="Developer ID Application: Probe Fixture (XXXXXXXXXX)"

cat > "$STUBS/security" <<EOF
#!/bin/bash
# Stub: pretends the probe's fake Developer ID identity exists in the keychain.
echo '  1) 0000000000000000000000000000000000000000 "$FAKE_IDENTITY"'
echo '     1 valid identities found'
EOF

cat > "$STUBS/codesign" <<'EOF'
#!/bin/bash
# Stub: signing and verification "succeed" without a real identity.
exit 0
EOF

cat > "$STUBS/notary-invalid" <<'EOF'
#!/bin/bash
# Stub notarytool: submission runs but the verdict is Invalid.
echo '{"id":"00000000-0000-0000-0000-000000000000","status":"Invalid","message":"Package Invalid"}'
exit 0
EOF

cat > "$STUBS/notary-crash" <<'EOF'
#!/bin/bash
# Stub notarytool: the command itself fails (network, auth, ...).
echo "Error: HTTP 401" >&2
exit 1
EOF

cat > "$STUBS/notary-garbage" <<'EOF'
#!/bin/bash
# Stub notarytool: exits 0 but the output is not parsable JSON.
echo 'Processing complete!!'
exit 0
EOF

cat > "$STUBS/notary-accepted" <<'EOF'
#!/bin/bash
echo '{"id":"00000000-0000-0000-0000-000000000000","status":"Accepted"}'
exit 0
EOF

cat > "$STUBS/stapler-fail" <<'EOF'
#!/bin/bash
echo "Error 65: failed to staple" >&2
exit 65
EOF

cat > "$STUBS/stapler-ok" <<'EOF'
#!/bin/bash
exit 0
EOF

cat > "$STUBS/spctl-reject" <<'EOF'
#!/bin/bash
echo "assessment: rejected" >&2
exit 3
EOF

cat > "$STUBS/notary-hang" <<'EOF'
#!/bin/bash
# Stub notarytool: hangs, standing in for a long upload — the window in which a user hits ^C.
sleep 300
EOF

chmod +x "$STUBS"/*

# ---------------------------------------------------------------- fixtures
mkdir -p "$DIST"
HISTORICAL="$DIST/TriCap-0.0.9.dmg"
echo "pretend this shipped last month" > "$HISTORICAL"
HISTORICAL_SUM="$(shasum -a 256 "$HISTORICAL" | cut -d' ' -f1)"

run_scenario() { # run_scenario <label> <notary-stub> <stapler-stub> <spctl-path>
  local label="$1" notary="$2" stapler="$3" spctl="$4"
  echo "== scenario: $label"

  set +e
  TRICAP_PACKAGE_TEST=1 \
  CODESIGN_IDENTITY_RELEASE="$FAKE_IDENTITY" \
  TRICAP_NOTARY_PROFILE="probe-profile-name-only" \
  TRICAP_SECURITY="$STUBS/security" \
  TRICAP_CODESIGN="$STUBS/codesign" \
  TRICAP_NOTARYTOOL="$STUBS/$notary" \
  TRICAP_STAPLER="$STUBS/$stapler" \
  TRICAP_SPCTL="$spctl" \
    ./scripts/package-release.sh > "$STUBS/out-$label.log" 2>&1
  local exit_code=$?
  set -e

  check "$label: exits non-zero (got $exit_code)" "$([[ $exit_code -ne 0 ]]; echo $?)"
  check "$label: no official TriCap-$VERSION.dmg" "$([[ ! -e "$OFFICIAL" ]]; echo $?)"
  check "$label: no temp residue in build/dist" \
        "$(compgen -G "$DIST/.pkg-tmp-*" > /dev/null && echo 1 || echo 0)"
  check "$label: no TriCap volume left mounted" \
        "$(/sbin/mount | grep -q "/TriCap" && echo 1 || echo 0)"
  check "$label: historical release untouched" \
        "$([[ "$(shasum -a 256 "$HISTORICAL" | cut -d' ' -f1)" == "$HISTORICAL_SUM" ]]; echo $?)"
}

# 1–3: the notarization verdict path
run_scenario "notary-rejected"   "notary-invalid" "stapler-ok"   "/usr/sbin/spctl"
run_scenario "notary-crash"      "notary-crash"   "stapler-ok"   "/usr/sbin/spctl"
run_scenario "notary-unparsable" "notary-garbage" "stapler-ok"   "/usr/sbin/spctl"
# 4: staple fails after Accepted
run_scenario "staple-fail"       "notary-accepted" "stapler-fail" "/usr/sbin/spctl"
# 5: spctl rejects the mounted app
run_scenario "spctl-reject"      "notary-accepted" "stapler-ok"   "$STUBS/spctl-reject"

# 6: interrupted mid-notarization (SIGTERM while the "upload" hangs) → the trap must clean up
echo "== scenario: interrupted"
TRICAP_PACKAGE_TEST=1 \
CODESIGN_IDENTITY_RELEASE="$FAKE_IDENTITY" \
TRICAP_NOTARY_PROFILE="probe-profile-name-only" \
TRICAP_SECURITY="$STUBS/security" \
TRICAP_CODESIGN="$STUBS/codesign" \
TRICAP_NOTARYTOOL="$STUBS/notary-hang" \
  ./scripts/package-release.sh > "$STUBS/out-interrupted.log" 2>&1 &
PKG_PID=$!
# Wait until this run's temp directory exists (the DMG is being built / "uploaded")…
for _ in $(seq 1 120); do
  compgen -G "$DIST/.pkg-tmp-*" > /dev/null && break
  sleep 0.5
done
check "interrupted: temp workspace observed while running" \
      "$(compgen -G "$DIST/.pkg-tmp-*" > /dev/null; echo $?)"
# …then interrupt it, as a user or CI timeout would.
kill -TERM "$PKG_PID" 2>/dev/null || true
set +e; wait "$PKG_PID"; interrupted_code=$?; set -e
sleep 1
check "interrupted: exits non-zero (got $interrupted_code)" "$([[ $interrupted_code -ne 0 ]]; echo $?)"
check "interrupted: no official TriCap-$VERSION.dmg" "$([[ ! -e "$OFFICIAL" ]]; echo $?)"
check "interrupted: temp workspace cleaned up by the trap" \
      "$(compgen -G "$DIST/.pkg-tmp-*" > /dev/null && echo 1 || echo 0)"
check "interrupted: historical release untouched" \
      "$([[ "$(shasum -a 256 "$HISTORICAL" | cut -d' ' -f1)" == "$HISTORICAL_SUM" ]]; echo $?)"

# 7: the official target already exists → refuse before building
echo "== scenario: target-exists"
echo "an artefact that must never be overwritten" > "$OFFICIAL"
OFFICIAL_SUM="$(shasum -a 256 "$OFFICIAL" | cut -d' ' -f1)"
set +e
TRICAP_PACKAGE_TEST=1 \
CODESIGN_IDENTITY_RELEASE="$FAKE_IDENTITY" \
TRICAP_NOTARY_PROFILE="probe-profile-name-only" \
TRICAP_SECURITY="$STUBS/security" \
  ./scripts/package-release.sh > "$STUBS/out-target-exists.log" 2>&1
exit_code=$?
set -e
check "target-exists: exits non-zero (got $exit_code)" "$([[ $exit_code -ne 0 ]]; echo $?)"
check "target-exists: refuses before building (message names the file)" \
      "$(grep -q "already exists" "$STUBS/out-target-exists.log"; echo $?)"
check "target-exists: existing file byte-identical" \
      "$([[ "$(shasum -a 256 "$OFFICIAL" | cut -d' ' -f1)" == "$OFFICIAL_SUM" ]]; echo $?)"
check "target-exists: historical release untouched" \
      "$([[ "$(shasum -a 256 "$HISTORICAL" | cut -d' ' -f1)" == "$HISTORICAL_SUM" ]]; echo $?)"
rm -f "$OFFICIAL"

# ---------------------------------------------------------------- the real local-test path
echo "== scenario: local-test (real, no stubs)"
./scripts/package-release.sh --local-test > "$STUBS/out-local-test.log" 2>&1
LOCAL_DMG="$DIST/TriCap-$VERSION-LOCAL-TEST-adhoc.dmg"
check "local-test: exits zero" "0"
check "local-test: product name contains LOCAL-TEST-adhoc" "$([[ -f "$LOCAL_DMG" ]]; echo $?)"
check "local-test: no official TriCap-$VERSION.dmg appeared" "$([[ ! -e "$OFFICIAL" ]]; echo $?)"
check "local-test: historical release untouched" \
      "$([[ "$(shasum -a 256 "$HISTORICAL" | cut -d' ' -f1)" == "$HISTORICAL_SUM" ]]; echo $?)"

MNT="$(mktemp -d)"
hdiutil attach -quiet -nobrowse -mountpoint "$MNT" "$LOCAL_DMG"
check "local-test: DMG contains TriCap.app" "$([[ -d "$MNT/TriCap.app" ]]; echo $?)"
check "local-test: DMG contains /Applications symlink" \
      "$([[ "$(readlink "$MNT/Applications")" == "/Applications" ]]; echo $?)"
/usr/bin/codesign --verify --deep --strict "$MNT/TriCap.app"
check "local-test: app inside DMG passes codesign --verify" "$?"
hdiutil detach -quiet "$MNT"
rmdir "$MNT" 2>/dev/null || true

rm -f "$HISTORICAL"

echo
if [[ $FAILURES -eq 0 ]]; then
  echo "ALL GATE CHECKS PASSED"
else
  echo "$FAILURES GATE CHECK(S) FAILED"
  exit 1
fi
