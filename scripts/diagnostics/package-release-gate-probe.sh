#!/usr/bin/env bash
#
# package-release-gate-probe.sh — prove that package-release.sh fails closed, without needing a
# real Developer ID, and without going anywhere near real products.
#
# Isolation contract (checked, not assumed): every scenario runs with TRICAP_DIST_OVERRIDE
# pointing into a throwaway directory created by mktemp OUTSIDE the repository. The sentinel
# "historical release", the seeded official target, every injected failure and the local-test
# product live only there. The real build/dist is fingerprinted (file list + SHA-256) before the
# first scenario and after the last, and the probe fails unless the two manifests are
# byte-identical — including the case where build/dist does not exist at all. The probe never
# writes, moves or deletes anything under the real build/dist.
#
# Scenarios:
#    1. notarytool returns status "Invalid"          → must fail
#    2. notarytool command itself fails              → must fail
#    3. notarytool output is unparsable              → must fail
#    4. stapler fails after an Accepted verdict      → must fail
#    5. spctl rejects the mounted app                → must fail; no device/mount of this run left
#    6. SIGTERM mid-"upload"                         → must fail; trap cleans temp and mounts
#    7. the official target already exists           → must refuse before building
#    8. ALL stubs succeed (test-mode barrier)        → completes, but only TEST-PROBE.dmg exists;
#                                                      the official name never appears and
#                                                      "RELEASE PRODUCT" is never printed
#    9. two runs race one target                     → exactly one wins; loser exits non-zero;
#                                                      the winner's file is never replaced
#   10. the real --local-test path                   → DMG mounts, drag-to-install layout intact
#
# Mount-residue checks are precise: they match this run's isolated directory prefix in the mount
# table and in `hdiutil info` image paths — never a fuzzy volume-name grep.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

VERSION="$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)"
REAL_DIST="$ROOT/build/dist"
FAILURES=0

# Everything the probe creates lives under these two, both far away from the repo.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/tricap-gate-probe-XXXXXX")"
# The physical path, because the mount table and hdiutil report /private/var/... while $TMPDIR
# spells it /var/... — a fuzzy or symlinked comparison silently never matches (this probe's own
# first version had exactly that false-PASS, caught by the leftover it failed to see).
WORK_PHYS="$(cd "$WORK" && pwd -P)"
STUBS="$WORK/stubs"
ISO_DIST="$WORK/dist"        # the isolated stand-in for build/dist
mkdir -p "$STUBS" "$ISO_DIST"

cleanup() {
  # Detach anything still mounted from the isolated directory, then remove the workspace —
  # on success, failure and signals alike. set +e: a busy mountpoint must not abort the trap.
  set +e
  local i mp
  for i in 1 2 3 4 5 6 8 10; do
    /sbin/mount | grep -Fq "$WORK_PHYS" || break
    /sbin/mount | grep -F "$WORK_PHYS" | awk '{print $3}' | while read -r mp; do
      hdiutil detach -quiet -force "$mp" 2>/dev/null
    done
    sleep 0.4
  done
  rm -rf "$WORK" 2>/dev/null || { sleep 1; rm -rf "$WORK" 2>/dev/null; }
  set -e
}
on_probe_signal() {
  local signal_number="$1"
  trap - EXIT INT TERM
  cleanup
  exit $((128 + signal_number))
}
trap cleanup EXIT
trap 'on_probe_signal 2' INT
trap 'on_probe_signal 15' TERM

check() { # check <label> <condition-result: 0 pass>
  if [[ "$2" == "0" ]]; then
    echo "  PASS  $1"
  else
    echo "  FAIL  $1"
    FAILURES=$((FAILURES + 1))
  fi
}

# ---------------------------------------------------------------- real-dist fingerprint
manifest() { # <dir> — deterministic listing + content hashes, or ABSENT
  if [[ -d "$1" ]]; then
    (cd "$1" && find . -type f -print0 | sort -z | xargs -0 shasum -a 256 2>/dev/null) || true
  else
    echo "ABSENT"
  fi
}
REAL_BEFORE="$(manifest "$REAL_DIST")"
echo "== real build/dist fingerprint taken ($(printf '%s' "$REAL_BEFORE" | grep -c . ) line(s))"

OFFICIAL="$ISO_DIST/TriCap-$VERSION.dmg"
TEST_PROBE_DMG="$ISO_DIST/TriCap-$VERSION-TEST-PROBE.dmg"

no_mount_residue() { # 0 when nothing from this probe's workspace is mounted or attached
  # Checked by physical-path prefix in the mount table AND by backing-image path in
  # `hdiutil info` — never by volume name.
  if /sbin/mount | grep -Fq "$WORK_PHYS"; then return 1; fi
  if hdiutil info | grep -Fq "$WORK_PHYS"; then return 1; fi
  return 0
}

# ---------------------------------------------------------------- stub tools
FAKE_IDENTITY="Developer ID Application: Probe Fixture (XXXXXXXXXX)"

cat > "$STUBS/security" <<'EOF'
#!/bin/bash
echo '  1) 0000000000000000000000000000000000000000 "Developer ID Application: Probe Fixture (XXXXXXXXXX)"'
echo '     1 valid identities found'
# Keep writing well beyond a pipe buffer. The production script must consume the complete
# command output before matching it; an old `security | grep -q` implementation intermittently
# killed this producer with SIGPIPE under pipefail and misreported the valid identity as absent.
for i in {1..4096}; do echo '     additional non-matching identity diagnostic'; done
EOF
cat > "$STUBS/codesign" <<'EOF'
#!/bin/bash
exit 0
EOF
cat > "$STUBS/notary-invalid" <<'EOF'
#!/bin/bash
echo '{"id":"00000000-0000-0000-0000-000000000000","status":"Invalid","message":"Package Invalid"}'
exit 0
EOF
cat > "$STUBS/notary-crash" <<'EOF'
#!/bin/bash
echo "Error: HTTP 401" >&2
exit 1
EOF
cat > "$STUBS/notary-garbage" <<'EOF'
#!/bin/bash
echo 'Processing complete!!'
exit 0
EOF
cat > "$STUBS/notary-accepted" <<'EOF'
#!/bin/bash
echo '{"id":"00000000-0000-0000-0000-000000000000","status":"Accepted"}'
exit 0
EOF
cat > "$STUBS/notary-accepted-slow" <<'EOF'
#!/bin/bash
sleep 6
echo '{"id":"00000000-0000-0000-0000-000000000000","status":"Accepted"}'
exit 0
EOF
cat > "$STUBS/notary-hang" <<'EOF'
#!/bin/bash
# Replace the stub shell rather than spawning a grandchild, so the package script's tracked child
# PID is the actual long-running process that must be terminated and reaped on SIGTERM.
: "${TRICAP_PROBE_NOTARY_STARTED:?missing probe start marker path}"
: > "$TRICAP_PROBE_NOTARY_STARTED"
exec sleep 300
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
chmod +x "$STUBS"/*

# The sentinel that every scenario must leave byte-identical — inside the ISOLATED dist only.
HISTORICAL="$ISO_DIST/TriCap-0.0.9.dmg"
echo "pretend this shipped last month" > "$HISTORICAL"
HISTORICAL_SUM="$(shasum -a 256 "$HISTORICAL" | cut -d' ' -f1)"

packaged_env() { # packaged_env <notary-stub> <stapler-stub> <spctl-path>
  # Emits the env-var assignments for one scenario, consumed by env(1).
  printf '%s\n' \
    "TRICAP_PACKAGE_TEST=1" \
    "TRICAP_DIST_OVERRIDE=$ISO_DIST" \
    "CODESIGN_IDENTITY_RELEASE=$FAKE_IDENTITY" \
    "TRICAP_NOTARY_PROFILE=probe-profile-name-only" \
    "TRICAP_SECURITY=$STUBS/security" \
    "TRICAP_CODESIGN=$STUBS/codesign" \
    "TRICAP_NOTARYTOOL=$STUBS/$1" \
    "TRICAP_PROBE_NOTARY_STARTED=$WORK/notary-started" \
    "TRICAP_STAPLER=$STUBS/$2" \
    "TRICAP_SPCTL=$3"
}

run_packaged() { # run_packaged <notary-stub> <stapler-stub> <spctl-path> <logfile>
  local log="$4"
  local -a envs=()
  while IFS= read -r line; do envs+=("$line"); done < <(packaged_env "$1" "$2" "$3")
  env "${envs[@]}" ./scripts/package-release.sh > "$log" 2>&1
}

run_packaged_bg() { # same, but $! is the SCRIPT's pid — `exec` sheds the wrapper subshell, so a
                    # signal sent to $! reaches the script's own trap, not a shell in between.
  local log="$4"
  local -a envs=()
  while IFS= read -r line; do envs+=("$line"); done < <(packaged_env "$1" "$2" "$3")
  ( exec env "${envs[@]}" ./scripts/package-release.sh > "$log" 2>&1 ) &
}

assert_failure_scenario() { # <label> <exit-code> <logfile> <expected-gate-message>
  local label="$1" exit_code="$2" log="$3" expected="$4"
  check "$label: exits non-zero (got $exit_code)" "$([[ $exit_code -ne 0 ]]; echo $?)"
  # A non-zero exit alone is not coverage: an identity or build failure before the requested
  # gate would otherwise make every injected scenario look green. Require the gate-specific
  # failure text emitted only after that stage was actually reached.
  check "$label: reached its intended gate ('$expected')" \
        "$(grep -Fq "$expected" "$log"; echo $?)"
  check "$label: no official TriCap-$VERSION.dmg in isolated dist" "$([[ ! -e "$OFFICIAL" ]]; echo $?)"
  check "$label: no TEST-PROBE artefact either" "$([[ ! -e "$TEST_PROBE_DMG" ]]; echo $?)"
  check "$label: no temp residue in isolated dist" \
        "$(compgen -G "$ISO_DIST/.pkg-tmp-*" > /dev/null && echo 1 || echo 0)"
  check "$label: no mount/device residue from this run" "$(no_mount_residue; echo $?)"
  check "$label: historical sentinel untouched" \
        "$([[ "$(shasum -a 256 "$HISTORICAL" | cut -d' ' -f1)" == "$HISTORICAL_SUM" ]]; echo $?)"
}

scenario_fail() { # <label> <notary> <stapler> <spctl-path> <expected-gate-message>
  local label="$1" log="$WORK/out-$1.log"
  echo "== scenario: $label"
  set +e
  run_packaged "$2" "$3" "$4" "$log"
  local code=$?
  set -e
  assert_failure_scenario "$label" "$code" "$log" "$5"
}

# 1–5: injected verdict failures
scenario_fail "notary-rejected"   "notary-invalid"  "stapler-ok"   "/usr/sbin/spctl"      "notarization status is 'Invalid'"
scenario_fail "notary-crash"      "notary-crash"    "stapler-ok"   "/usr/sbin/spctl"      "notarytool submit failed"
scenario_fail "notary-unparsable" "notary-garbage"  "stapler-ok"   "/usr/sbin/spctl"      "notarization status is '<unparsable>'"
scenario_fail "staple-fail"       "notary-accepted" "stapler-fail" "/usr/sbin/spctl"      "stapler staple failed"
scenario_fail "spctl-reject"      "notary-accepted" "stapler-ok"   "$STUBS/spctl-reject" "spctl rejected the app"

# 6: SIGTERM mid-"upload" — the trap must clean up and exit 128+15
echo "== scenario: interrupted"
rm -f "$WORK/notary-started"
set +e
run_packaged_bg "notary-hang" "stapler-ok" "/usr/sbin/spctl" "$WORK/out-interrupted.log"
PKG_PID=$!
reached_upload=0
for _ in $(seq 1 240); do
  if [[ -e "$WORK/notary-started" ]]; then
    reached_upload=1
    break
  fi
  sleep 0.5
done
check "interrupted: notary child confirmed running before SIGTERM" \
      "$([[ $reached_upload -eq 1 ]]; echo $?)"
kill -TERM "$PKG_PID" 2>/dev/null || true
wait "$PKG_PID"; interrupted_code=$?
set -e
sleep 1
assert_failure_scenario "interrupted" "$interrupted_code" "$WORK/out-interrupted.log" "notarytool submit"

# 7: official target already exists (in the ISOLATED dist) → refuse before building
echo "== scenario: target-exists"
echo "an artefact that must never be overwritten" > "$OFFICIAL"
OFFICIAL_SUM="$(shasum -a 256 "$OFFICIAL" | cut -d' ' -f1)"
set +e
TRICAP_PACKAGE_TEST=1 \
TRICAP_DIST_OVERRIDE="$ISO_DIST" \
CODESIGN_IDENTITY_RELEASE="$FAKE_IDENTITY" \
TRICAP_NOTARY_PROFILE="probe-profile-name-only" \
TRICAP_SECURITY="$STUBS/security" \
  ./scripts/package-release.sh > "$WORK/out-target-exists.log" 2>&1
exit_code=$?
set -e
check "target-exists: exits non-zero (got $exit_code)" "$([[ $exit_code -ne 0 ]]; echo $?)"
check "target-exists: refuses before building (message names the file)" \
      "$(grep -q "already exists" "$WORK/out-target-exists.log"; echo $?)"
check "target-exists: existing file byte-identical" \
      "$([[ "$(shasum -a 256 "$OFFICIAL" | cut -d' ' -f1)" == "$OFFICIAL_SUM" ]]; echo $?)"
check "target-exists: historical sentinel untouched" \
      "$([[ "$(shasum -a 256 "$HISTORICAL" | cut -d' ' -f1)" == "$HISTORICAL_SUM" ]]; echo $?)"
rm -f "$OFFICIAL"

# 8: ALL stubs succeed — the test-mode barrier. The run may complete, but only as TEST-PROBE.
echo "== scenario: all-success-barrier"
set +e
run_packaged "notary-accepted" "stapler-ok" "$STUBS/codesign" "$WORK/out-barrier.log"
barrier_code=$?
set -e
check "all-success-barrier: completes under stubs (got $barrier_code)" "$([[ $barrier_code -eq 0 ]]; echo $?)"
check "all-success-barrier: official TriCap-$VERSION.dmg NEVER appears" "$([[ ! -e "$OFFICIAL" ]]; echo $?)"
check "all-success-barrier: product is explicitly TEST-PROBE" "$([[ -f "$TEST_PROBE_DMG" ]]; echo $?)"
check "all-success-barrier: 'RELEASE PRODUCT' is never printed" \
      "$(grep -q "RELEASE PRODUCT" "$WORK/out-barrier.log" && echo 1 || echo 0)"
check "all-success-barrier: TEST-PROBE banner printed instead" \
      "$(grep -q "TEST-PROBE PRODUCT" "$WORK/out-barrier.log"; echo $?)"
check "all-success-barrier: no mount/device residue" "$(no_mount_residue; echo $?)"
check "all-success-barrier: historical sentinel untouched" \
      "$([[ "$(shasum -a 256 "$HISTORICAL" | cut -d' ' -f1)" == "$HISTORICAL_SUM" ]]; echo $?)"
rm -f "$TEST_PROBE_DMG"

# 9: two runs race one target — kernel-atomic claim. Which run wins is timing (the "slow" run's
#    stub sleep races the other's incremental build), so the assertions are order-independent:
#    exactly one winner, the loser names the claim failure, and the winner's file — snapshotted
#    the moment it first appears — is never replaced afterwards.
echo "== scenario: concurrent-claim"
set +e
run_packaged_bg "notary-accepted-slow" "stapler-ok" "$STUBS/codesign" "$WORK/out-race-A.log"
RACE_A=$!
for _ in $(seq 1 240); do
  grep -q "notarytool submit" "$WORK/out-race-A.log" 2>/dev/null && break
  sleep 0.5
done
run_packaged_bg "notary-accepted" "stapler-ok" "$STUBS/codesign" "$WORK/out-race-B.log"
RACE_B=$!

# The claim is one atomic link: the file appears with its full content, so hash at first sight.
WINNER_SUM=""; WINNER_INODE=""
for _ in $(seq 1 600); do
  if [[ -f "$TEST_PROBE_DMG" ]]; then
    WINNER_SUM="$(shasum -a 256 "$TEST_PROBE_DMG" | cut -d' ' -f1)"
    WINNER_INODE="$(stat -f %i "$TEST_PROBE_DMG")"
    break
  fi
  sleep 0.2
done
wait "$RACE_A"; race_a_code=$?
wait "$RACE_B"; race_b_code=$?
set -e
winners=0
[[ $race_a_code -eq 0 ]] && winners=$((winners + 1))
[[ $race_b_code -eq 0 ]] && winners=$((winners + 1))
if [[ $race_a_code -eq 0 ]]; then LOSER_LOG="$WORK/out-race-B.log"; WINNER_LOG="$WORK/out-race-A.log"
else LOSER_LOG="$WORK/out-race-A.log"; WINNER_LOG="$WORK/out-race-B.log"; fi

check "concurrent-claim: exactly one winner (A=$race_a_code, B=$race_b_code)" \
      "$([[ $winners -eq 1 ]]; echo $?)"
check "concurrent-claim: the winner announced a TEST-PROBE product" \
      "$(grep -q "TEST-PROBE PRODUCT" "$WINNER_LOG"; echo $?)"
check "concurrent-claim: the loser names the claim failure" \
      "$(grep -q "could not claim" "$LOSER_LOG"; echo $?)"
check "concurrent-claim: winner's file was snapshotted at first appearance" \
      "$([[ -n "$WINNER_INODE" ]]; echo $?)"
check "concurrent-claim: winner's file never replaced (same inode)" \
      "$([[ "$(stat -f %i "$TEST_PROBE_DMG")" == "$WINNER_INODE" ]]; echo $?)"
check "concurrent-claim: winner's content byte-identical" \
      "$([[ "$(shasum -a 256 "$TEST_PROBE_DMG" | cut -d' ' -f1)" == "$WINNER_SUM" ]]; echo $?)"
check "concurrent-claim: no temp residue" \
      "$(compgen -G "$ISO_DIST/.pkg-tmp-*" > /dev/null && echo 1 || echo 0)"
check "concurrent-claim: no mount/device residue" "$(no_mount_residue; echo $?)"
check "concurrent-claim: historical sentinel untouched" \
      "$([[ "$(shasum -a 256 "$HISTORICAL" | cut -d' ' -f1)" == "$HISTORICAL_SUM" ]]; echo $?)"
rm -f "$TEST_PROBE_DMG"

# 10: the real local-test path, still inside the isolated dist
echo "== scenario: local-test (real tools, isolated dist)"
TRICAP_PACKAGE_TEST=1 \
TRICAP_DIST_OVERRIDE="$ISO_DIST" \
  ./scripts/package-release.sh --local-test > "$WORK/out-local-test.log" 2>&1
LOCAL_DMG="$ISO_DIST/TriCap-$VERSION-LOCAL-TEST-adhoc.dmg"
check "local-test: exits zero" "0"
check "local-test: product name contains LOCAL-TEST-adhoc" "$([[ -f "$LOCAL_DMG" ]]; echo $?)"
check "local-test: no official name appeared" "$([[ ! -e "$OFFICIAL" ]]; echo $?)"
MNT="$WORK/mnt-local"
mkdir -p "$MNT"
hdiutil attach -quiet -nobrowse -mountpoint "$MNT" "$LOCAL_DMG"
check "local-test: DMG contains TriCap.app" "$([[ -d "$MNT/TriCap.app" ]]; echo $?)"
check "local-test: DMG contains /Applications symlink" \
      "$([[ "$(readlink "$MNT/Applications")" == "/Applications" ]]; echo $?)"
/usr/bin/codesign --verify --deep --strict "$MNT/TriCap.app"
check "local-test: app inside DMG passes codesign --verify" "$?"
hdiutil detach -quiet "$MNT" || hdiutil detach -quiet -force "$MNT" || true
check "local-test: historical sentinel untouched" \
      "$([[ "$(shasum -a 256 "$HISTORICAL" | cut -d' ' -f1)" == "$HISTORICAL_SUM" ]]; echo $?)"

# ---------------------------------------------------------------- final global sweep
# Belt and braces after every scenario's own checks: nothing from this probe's workspace may be
# mounted or attached, and no packaging temp directory may survive anywhere in the isolated dist.
echo "== final residue sweep"
for _ in 1 2 3 4 5; do no_mount_residue && break; sleep 0.5; done
check "final: no mount/device residue anywhere in the workspace" "$(no_mount_residue; echo $?)"
check "final: no .pkg-tmp-* anywhere in the isolated dist" \
      "$(compgen -G "$ISO_DIST/.pkg-tmp-*" > /dev/null && echo 1 || echo 0)"

# ---------------------------------------------------------------- the real build/dist is intact
echo "== real build/dist after all scenarios"
REAL_AFTER="$(manifest "$REAL_DIST")"
check "real build/dist manifest and hashes byte-identical" \
      "$([[ "$REAL_BEFORE" == "$REAL_AFTER" ]]; echo $?)"

echo
if [[ $FAILURES -eq 0 ]]; then
  echo "ALL GATE CHECKS PASSED"
else
  echo "$FAILURES GATE CHECK(S) FAILED"
  exit 1
fi
