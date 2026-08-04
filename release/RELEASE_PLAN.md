# TriCap release plan

Version-controlled (deliberately **not** under `build/`, which every build overwrites). This file
is the single place that says what stands between the current tree and a public GitHub Release.

**Public release status: `BLOCKED`.** See [blockers](#release-blockers). Nothing may be uploaded,
no tag or release created, and no Gatekeeper workaround is acceptable, until every blocker clears.

## What the product is right now

| Fact | Value |
|---|---|
| Version | 0.1.0 (`CFBundleShortVersionString`) |
| Declared minimum | macOS 14.0 (`LSMinimumSystemVersion`) — a build setting, **not** a tested claim |
| Architecture actually built | Apple Silicon arm64 only. Intel / Universal 2 has never been built or run; public copy must not mention it |
| Signature | ad-hoc (`codesign -s -`). Valid on this machine only; Gatekeeper elsewhere will refuse it, correctly |
| Packaging | `scripts/package-release.sh` produces a DMG with TriCap.app + `/Applications` drag target |

## Requirements ledger

Priorities: P0 = broken for real users, P1 = feature work, P2 = delivery scaffolding.

### This round

| # | P | Requirement | Acceptance | Status |
|---|---|---|---|---|
| A | P0 | Mode banner never erased by selection/highlight | Regression tests that fail on the old draw order; snapshots of both overlaps; banner never in captures | **Done** (`d912523`) — 10 tests, 7 fail on old code; snapshots 16/17 |
| B | P0 | Replace hand-written mosaic with `CIPixellate` | Mirror defect reproduced first; grid canvas-anchored; outside pixels untouched; one render path for preview + all exports; copy says pixelate | **Done** (`6e23723`) — probe + 13 new tests (3 fail on old code) + reworked legacy test; snapshot 18 |
| C | P1 | Launch at login via `SMAppService.mainApp` | System status the only truth; four statuses mapped; idempotent toggle; errors inline; snapshot | **Done** (`a713ccb`) — 8 tests; snapshots 01/19. Real login-time launch **unverified** (below) |
| D | P2 | Install + release boundary | This plan; fail-closed DMG script; release template with honest sections | **Done** (this commit) — script verified in both modes on this machine |

### Already in the baseline (must not regress)

F3 pins the clipboard image above other windows (never a screenshot key) · window-aware selection
with snapping · screenshots default to clipboard, no editor · original app icon ·
near-full-screen HUD placement · Animated WebP balanced strategy + live pre-encoding
(tail latency 177 s → 0.85 s, measured).

## Verified in this round, on this machine only

Environment at the time of writing — **must be re-collected at release time, not copied**:
macOS 26.5.2 (build 25F84), Apple Silicon arm64, Swift 6.3.3, two displays
(1470×956 @2x built-in, 1280×800 @2x secondary), 0 codesigning identities present.

- Full test suite, clean Debug and Release builds, `--selftest` under `caffeinate`, 19 UI
  snapshots individually reviewed, bundle audit (no external libwebp, `codesign --verify
  --deep --strict`).
- `package-release.sh --local-test`: DMG builds, mounts, contains TriCap.app +
  `/Applications` symlink, app inside verifies.
- `package-release.sh` (release mode) **fails closed, proven under injected failures**
  (`scripts/diagnostics/package-release-gate-probe.sh`, no Developer ID required — and the probe
  itself runs against an **isolated dist directory from mktemp**, fingerprinting the real
  build/dist before and after and failing unless it is byte-identical): the official
  `TriCap-<version>.dmg` name exists only after notarization is literally `Accepted` (JSON,
  machine-parsed), the staple validates and `spctl` passes on the mounted app — until then the
  artefact lives under a temporary name in a per-run temp directory, and the final name is
  claimed with a **hard link whose EEXIST is kernel-atomic** (no check-then-move window).
  Ten scenarios, five consecutive full runs, all green (**73 checks per run, 365/365 total**):
  every injected failure must match its own gate-specific error, so an earlier preflight failure
  cannot masquerade as coverage; scenarios are notary *rejected* / *command failure* /
  *unparsable output*, *staple failure*, *spctl rejection*, *SIGTERM mid-upload*,
  *target already exists*, **all-success stubs** (the test-mode hard barrier: even fully faked
  verdicts can only mint `…-TEST-PROBE.dmg`, never the official name, never the release banner),
  a **two-run race** for one target (exactly one winner in either ordering; the loser exits
  non-zero; the winner's inode and hash never change), and the real `--local-test` build.
  The probe has now caught five real release-path defects across its life: a trap that reported
  exit 0 after SIGTERM; a mount-table check that never matched because /sbin/mount prints
  /private/var/… where $TMPDIR says /var/…; a `detach`/`rm` race with macOS's asynchronous
  unmount; a `security | grep -q` + `pipefail` SIGPIPE race that randomly rejected a valid
  identity; and parent-only TERM being deferred behind a live notary child. All are fixed:
  detaches poll the physical mount path, identity output is fully captured before matching, and
  notarization is a tracked child that the signal handler terminates and reaps before cleanup.

## Not yet verified

- **Login item actually launching TriCap at login.** Requires a real logout/login, which would
  destroy the working session; deliberately not performed. Also requires the app installed at a
  stable path (`/Applications`) — a bare build directory reports `notFound` by design. Enable the
  login item only after the install path is stable; keep this sentence in end-user docs.
- **The signed/notarized path of `package-release.sh`** end to end: no Developer ID identity
  exists on this machine. Every failure gate is exercised by injection; the *happy* path
  (real signature, real `Accepted`, real staple, real spctl pass) has never run anywhere.
- **Any second machine**: clean-machine install, Gatekeeper first-launch flow, macOS 14/15
  behaviour, Intel — all untested.
- Real-interaction items carried in REVIEW_HANDOFF.md §4 (clicking Stop, F3 press, drag/zoom on
  pins, editor interactions, etc.).

## Release blockers

1. **No Developer ID Application identity** on the build machine (`security find-identity`: 0).
2. **Never notarized**: no accepted notarytool submission, nothing stapled, `spctl --assess`
   never passed on a distributable artefact.
3. **arm64-only**: public notes may only say Apple Silicon until Universal 2 is built and run.
4. **Login item unverified at real login** (see above) — must be verified or listed as a known
   limitation in the release notes.
5. **Verified-environment section must be re-collected** on the release build, from the release
   artefact, not from development runs.

When 1–2 clear: run `scripts/package-release.sh` (release mode), then fill
`release/RELEASE_TEMPLATE.md` with freshly collected facts. If any check in the script fails, the
release stays blocked — the script will not produce a distributable artefact past a failure.

## Credentials policy

No file in this repository accepts, stores or logs credentials. Signing references a keychain
identity by name (`CODESIGN_IDENTITY_RELEASE`); notarization references a keychain profile by
name (`TRICAP_NOTARY_PROFILE`), created once by a human with `xcrun notarytool
store-credentials`. Never paste passwords, App Store Connect keys or team IDs into scripts,
arguments, environment files or CI logs.
