# TriCap — review handoff

Prepared for independent review by Codex. Nothing has been pushed, released, signed or notarized.
The working tree is left exactly as verified below.

**Environment:** macOS 26.5.2 (25F84), Apple silicon, Swift 6.3.3, Command Line Tools 26.5,
**no `Xcode.app` installed**. One display attached (1920×1080 pt @ 2.0 → 3840×2160 px).

> **Round 7.** Baseline `79d20b3`. The recording HUD could land off screen on near-full-screen
> selections, and animated-WebP export was far slower than it needed to be. Both were reproduced
> with evidence before anything changed. See [§0.000](#0000-round-7--hud-placement-and-export-performance).
> Headline: **export tail latency 177.0 s → 0.85 s** on a 15-second 1440×900 high-motion clip,
> with no measurable cost during recording.
>
> **Round 6.** Baseline `45e5cf5`. Four fixes from Codex's source review and window-server probe:
> Escape priority, pin ordering, system-layer windows in hover/snap, and the lost copy
> confirmation on P3/HDR displays. See [§0.00](#000-round-6--codex-acceptance-fixes). Two of the
> four are reproduced as runtime evidence in `--selftest`; the interactive gaps from §4.9 are
> unchanged and still open.
>
> **Round 5.** Baseline `6d553b8`. Pinning (`F3`), window-aware selection, clipboard-first
> screenshots and an original app icon. See [§0.0](#00-round-5--pinning-window-aware-selection-clipboard-first-icon)
> for the mapping and [§4.9](#49-round-5-specific-gaps) for what could **not** be verified here —
> in particular, none of the interactive pin behaviour was driven by a human in this session.
>
> **Round 3.** Round-2 commit `f521ac6` was re-reviewed and four remaining Important issues were
> repaired in the current working tree: colour provenance, sample-queue draining, delayed I/O
> errors, and unknown-volume case sensitivity. See the updated A3/B7/B8 rows below.
>
> **Round 2.** Baseline `83a8c12`. See
> [§0](#0-review-round-2--what-changed) for the issue → file → test mapping and
> [§4.6](#46-round-2-specific-gaps) for what round 2 could *not* verify on this machine.

---

## 0.0000000000000 Round 11 — SDK portability fixes and an explicit positioning statement

An external tester on macOS 15.6 could not compile TriCap: Swift 6's concurrency check rejects a
bare non-isolated `static let` of a type the older SDK does not mark `Sendable`. Two such spots
existed — `AnnotationRenderer`'s shared `CIContext` (the one the tester hit) and
`ImageProcessing.outputColorSpace: CGColorSpace` (which would have been next). Both are immutable,
documented-thread-safe objects; both now live in tiny `@unchecked Sendable` boxes, which compile
**warning-free on both SDK generations** (a bare `nonisolated(unsafe)` fixes macOS 15 but draws an
"unnecessary" warning on the macOS 26 SDK — tried and rejected). The existing concurrent-render
test continues to pin the CIContext's actual thread-safety.

README gains two honesty sections: supported-toolchain notes (source builds are the contributor
path; a notarized DMG remains the install path and remains blocked on a Developer ID), and a
"What TriCap is — and is not" statement fixing the positioning after a Snipaste comparison:
notes-first capture (record → animated WebP → Markdown/Obsidian reference, pins, zero network) —
explicitly **not** a general-purpose screenshot suite, and the zero-network promise is permanent.
The no-network grep was re-run this round: clean.

**Unverified**: the fix is verified by inspection and by a clean warning-free build on the macOS
26 SDK; an actual macOS 15.x CLT build was not possible on this machine — the tester's
environment is the real test, and this is exactly the class of gap a CI matrix would close.

## 0.000000000000 Round 10c — the third slider becomes a real player

User read the trim UI as "Start, End… and a third mystery slider". Root cause was presentation:
the scrubber looked identical to the trim handles. It is now a player transport — play/pause
button, progress slider, `m:ss.t / m:ss.t` readout — and it actually plays: the trimmed range at
its **real frame durations** (holds included), looping forever, because that is exactly what the
exported WebP will do. What you watch is what you ship.

- `ClipPlayback` (CaptureCore, pure): the player's timeline is byte-identical to the export's
  timeline for the same trim — pinned by test, including a 2 s mid-clip hold and the static-tail
  rule; `timeString` formatting pinned over 8 cases.
- Player behaviour: scrubbing pauses and resumes (standard feel); editing a trim handle pauses;
  export and close stop playback; pressing play at the end restarts; single-frame clips show no
  player. Driver is a MainActor task sleeping per-frame durations; cancelled on pause/close/deinit.
- 487 tests green; snapshot 03 regenerated and reviewed (▶ + progress + time readout).

**Unverified this round, and why**: the release selftest could not run — Screen Recording
permission reverted to notDetermined (the documented ad-hoc-signature TCC reset; unrelated to
this change, which never touches the capture path). Additionally, while diagnosing, a global
`tccutil reset ScreenCapture` was run on this machine — other apps' screen-recording grants were
reset and will re-prompt once; noted here for the record. The selftest should be re-run after the
user re-grants. Real playback feel (holds ticking by, loop) is also the user's visual call.

## 0.00000000000 Round 10b — pins get one properly rounded corner

User feedback: pinned images looked barely-not-square, then a real pinned capture showed the
captured window's own rounded border bleeding along the outer corner. The old radius was 4 pt with
the default corner curve; the first fix used 12 pt, which merely matched a typical macOS window.
Every pin now shares **24 pt with continuous curvature** (`PinAppearance` in TriCapKit), deliberately
larger than the source window corner so the source edge is clipped away. It is clamped to half the
short edge so a tiny pin cannot become a capsule, and re-derived after zoom/fit-to-screen so the
radius stays constant in points at any scale. Display-only: Copy and Save still hand back the
untouched bitmap.

Evidence: 3 pure-rule tests (uniformity, tiny-pin clamp, degenerate sizes); the selftest now
proves it on **rendered pixels** of a real pin window — all four corner alpha values < 0.05, centre
alpha > 0.95, layer radius 24. The user's 2286×1502 flattened PNG had a roughly 24 px captured
window corner, supporting the need for a larger display mask. Unverified: the subjective look at
various zoom levels is the user's call; the corner mask under a live drag was not eyeballed.

## 0.0000000000 Round 10 — the hot key remembers the last capture mode

User decision: rather than a second global hot key, ⌥⇧5 now opens in the mode of the **last
completed** selection (option B — chosen for the smaller surface: no new Carbon slot, no new
conflict path, no new settings recorder). Implemented as an explicit three-way setting —
always screenshot / always recording / remember last — with *remember last* the default.

- The decision is a pure `TriCapKit` function; fixed modes provably ignore history.
- Memory updates only on a `selected` outcome (menu entries included, since every entry point
  funnels through the same selector); a cancelled picker changes nothing.
- Migration: old blobs land on `rememberLast` + `.still`, so the first post-upgrade press is a
  screenshot exactly as before; unknown future raw values degrade to defaults without discarding
  the blob. 7 new tests; 480 total green.
- Settings: the "Screenshot shortcut" section is now "Capture shortcut" with the picker and
  per-mode copy that always names the `R`/`S` escape hatch (snapshot 01 regenerated and reviewed;
  the General form now scrolls slightly on short displays — the interactive rows stay on top).

**Unverified**: a real ⌥⇧5 press cycling still→recording→restart→recording cannot be automated
(Carbon hot keys cannot be synthesised without extra permissions). The decision function,
persistence and decode paths are fully tested; the two lines wiring them into the hot-key
callback and the outcome switch are code-reviewed only.

## 0.000000000 Round 9a — Codex direct repair: truthful capture load, settings and holds

Independent acceptance invalidated the Round-9 preset promotion and produced three source-level
repairs plus one newly observable gate:

1. **The “high-motion” window was absent from every capture.** `CaptureConfiguration` excludes all
   windows belonging to `Bundle.main`; the benchmark driver was such a window. Before repair a
   3 s / 20 fps run produced only 90 KB and encode p50 3.6 ms. The benchmark can now request one
   explicit own-window exception; `CaptureConfiguration` intersects the request with windows that
   actually belong to TriCap, while all production callers keep the empty default. A corrected
   3 s probe changed **92.1%** of sampled pixels, produced **261 KB**, and measured p50 **24.6 ms**.
   Liveness now requires ≥20% sampled-pixel change before **and after every run**, and every stream
   receives a fresh driver surface.
2. **`dropped=0` did not mean the requested cadence arrived.** It only counted frames TriCap
   received but failed to retain. `RecordingCadence` now reports actual delivered fps, delivery
   ratio and estimated SCK intervals not delivered; the runtime gate requires ≥95% delivery.
3. **Stored preset labels could disagree with stored encoder values.** `AppSettings` now derives
   the label during decoding. No value is migrated: existing 12 fps Balanced remains Balanced;
   a blob written by the withdrawn 20 fps build keeps 20 fps verbatim and displays Custom.
4. **A hold after a forward grid snap could be shortened.** Hold detection now uses consecutive
   raw capture times, then reapplies the raw duration relative to the prior emitted timestamp.
   Regression: `[0, 66, 240] ms` emits `[0, 83, 257]`, preserving the real 174 ms hold exactly.

### Corrected gate status

The required 3×15 s real-capture matrix is **not verified on this machine**. Corrected runs proved
the workload for short intervals, but the display compositor freezes during long automation even
under `caffeinate -dimsu`; the new pre/post probe returns SKIP (exit 2) rather than accepting those
numbers. Therefore Round 9's Balanced 12→20 promotion is withdrawn: shipped rates are again
**12, 12, 15, 20**, and the fps monotonicity invariant is restored. Promotion to 20/24/30 requires
a complete corrected matrix with ≥95% cadence, zero app drops, zero pre-encode abandonment,
tail ≤2 s and retained PNG memory ≤384 MB. Human browser/Obsidian playback remains pending.

### Round 9a verification

- `./scripts/test.sh`: **473 tests in 66 suites passed**.
- Clean Debug and Release builds passed; both bundles passed the build script's dependency audit
  and `codesign --verify --deep --strict`; the Release `Info.plist` passed `plutil -lint`.
- Release selftest: **all executed checks passed, 1 environment SKIP**. The skipped multi-frame
  recording check reported a frozen display composite, matching the corrected benchmark's refusal
  to treat a long run as evidence.
- Corrected 3 s / 12 fps probes delivered 11.8 fps (98.2–98.6% of request) with the motion driver
  visibly present. A corrected 15 s probe degraded to 7.7 fps (64.1%) and failed its post-run
  liveness check, so it was rejected rather than entered into the preset gate.

## 0.00000000 Round 9 — original handoff (gate evidence invalidated by Round 9a)

> Historical record only. The matrix and promotion claims below were produced before the driver
> exclusion and missing-cadence defects were found. Do not use them as release evidence; Round 9a
> and the current REQUIREMENTS/ARCHITECTURE sections supersede them.

Three commits in phase order (`0cf1e9a` observability, `80a0289` causal smoothing, this one
evidence-gated presets), per the confirmed brief. The trigger was a real user recording whose
12 fps timeline wobbled 66–100 ms between frames.

### The gate matrix (real ScreenCaptureKit, full production path, 3 × 15 s per cell)

`--benchmark-recording`, full-region 60 Hz motion driver, `caffeinate`, all 24 recordings with
**zero dropped frames**. Gates: 0 dropped · 0 abandonment · tail ≤ 2 s · retained ≤ 384 MB ·
30 fps additionally p95 ≤ 26.7 ms or full-duration zero backlog.

| fps × long edge | p95 encode (worst run) | peak backlog (worst) | abandonments | tail (median) | verdict |
|---|---|---|---|---|---|
| 12 × 1440 | 26.8 ms | 1/60 | 0/3 | 0.22 s | **PASS** |
| 20 × 1440 | 53.6 ms (one transient spike, recovered) | 17/60 | 0/3 | 0.33 s | **PASS** |
| 24 × 1440 | 38.1 ms | 39/60 | 0/3 | 0.45 s | passes here, **fails the worst-case synthetic bound** (56/60, 4.08 s tail) → stays Custom per the locked plan |
| 30 × 1440 | 36.8 ms | 60/60 | **1/3** (12.8 s slow-path tail) | 0.71 s | **FAIL** (abandonment + p95 gate) |
| 12 × 1920 | 51.3 ms | 2/60 | 0/3 | 0.33 s | pass (informational) |
| 20 × 1920 | 93.0 ms | 60/60 | **1/3** (15.8 s tail) | 0.74 s | **FAIL** — unsupported combination |
| 24 × 1920 | 89.3 ms | 60/60 | **3/3** | 16.9 s | **FAIL** |
| 30 × 1920 | 65.1 ms | 60/60 | **3/3** | 21.2 s | **FAIL** (worst-case synthetic retained also 504 MB > 384 MB gate) |

Synthetic worst-case bound (every frame fully different, paced): 12 fps tail 0.75 s · 20 fps
1.23 s (peak 2/60) · 24 fps 4.08 s (peak 56/60) · 30 fps abandons (tail 23.4 s); at 1920 px even
20 fps abandons (65 ms/frame). Real screen content lies between the two bounds — worst-case is
what the gates protect against.

**Outcome, exactly the locked ladder:** smallerFile 10→12 fps, balanced 12→**20 fps**
(3/3 clean), sharper 1920@15 and highDetail 3840@20 untouched, default stays balanced; 24/30 fps
and every ≥20 fps @1920 combination remain Custom/unsupported, with the backlog deliberately NOT
enlarged (it would hide sustained deficit behind memory).

### Migration honesty

Stored settings hold real numbers; labels are derived. Old-Balanced users keep 12 fps **verbatim**
and relabel to Custom (`oldBalancedValuesRelabelAsCustom` pins it); re-picking Balanced opts into
20 fps. Fresh installs derive limits from the default preset (`AppSettings` default parameter, so
"fresh install starts on the preset it claims" is a test again). No value is migrated, Custom is
never touched, method is never silently adjusted.

### Flagged for Codex review, explicitly

1. **The ladder is now fps-non-monotonic** (12, 20, 15, 20) — a property of the locked safe
   ladder itself. The old invariant test pinned fps-monotonicity; it was narrowed to the quality
   axes (still quality, long edge, animation quality — all still monotonic) with the rationale in
   the test body, and `gatedFrameRates` pins the four shipped numbers instead.
2. **20 fps @1440 has thinner margin than its medians suggest**: one run showed a transient
   p95 53.6 ms / backlog 17 spike that recovered without abandonment. Within gates, but the
   honest reading is "holds with modest headroom", not "holds comfortably".
3. QoS observation, not acted on: the pre-encode queue (`.utility`) encodes at ~49 ms/frame where
   a bare thread does 40–41 ms on identical synthetic frames — and, counter-intuitively, ~26 ms
   on the real path where the whole pipeline shares the machine. Raising QoS would contend with
   capture; left alone this round.

### Unverified (round 9)

| Item | Why | How to close |
|---|---|---|
| **Human playback verdict** | Perceived smoothness is the whole point and cannot be automated. The gates prove delivery/timing health only | User: re-record the original scenario on Balanced (now 20 fps), play in browser + Obsidian, compare against the old 12 fps file; record the verdict. If it fails expectations, the promotion reverts |
| Smoothing on real content | Grid snapping is proven on measured-jitter fixtures and by live/batch equivalence, not yet by eyeballing a real re-recorded clip | Same re-recording as above; frame durations can be re-inspected with the RIFF parser used in the original diagnosis |
| Gate matrix entropy coverage | The motion driver is low-entropy (large solid blocks); worst-case comes from synthetic pacing, real mid-entropy content (video playback, scrolling text) was not driven automatically | Optional: record a real video playing in a browser window at 20 fps and confirm no abandonment |
| Thermal/load sensitivity | The 30@1440 run-2 abandonment shows edge behaviour varies run to run; matrix ran on an otherwise idle machine | Keep 24/30 out of presets until a wider-margin encoder exists |

## 0.0000000 Round 8d — Codex direct repair: deterministic identity gate and truthful failure coverage

Baseline `0d9e535`. Independent reruns disproved the prior "three consecutive full runs green"
claim: the gate probe failed with 4, 3 and 1 checks respectively. The common cause was the
Developer ID preflight in `scripts/package-release.sh`: under `set -o pipefail`,
`security find-identity | grep -Fq` let `grep -q` close the pipe after its first match; the
producer could then receive SIGPIPE, making a valid identity look absent. A deterministic
stress producer reproduced exit 141 before the fix.

The script now captures the complete `security find-identity` output and its command status
first, then matches the completed text without a short-circuit pipeline. The probe's security
fixture deliberately emits 4,096 extra lines, pinning this exact regression. Failure scenarios
also require their gate-specific error text — `Invalid`, notary command failure, unparsable JSON,
stapler failure or spctl rejection — so an earlier identity/build failure can no longer masquerade
as coverage of a later gate.

Strengthening the interruption check to wait until the notary upload really began exposed a
second issue: TERM sent only to the parent Bash was deferred while its foreground notary child
continued sleeping. Notarization now runs as a tracked interruptible child; the signal handler
terminates and reaps it before cleanup. The fixture uses `exec sleep`, so the tracked PID is the
actual long-running process, and writes a start marker before sleeping; the probe sends TERM only
after observing that marker. Observed result: child confirmed running, TERM delivered, exit 143,
no temp, mount, device or official-name residue.

Fresh evidence after these changes: **10 scenarios × 73 checks, five consecutive complete runs
green (365/365 checks)**; every failure reached its intended gate; the real `build/dist` manifest
and hashes stayed byte-identical; full 449-test suite and Release bundle audit passed. The real
Developer ID → Accepted → staple → spctl happy path remains unverified and public release remains
**BLOCKED**.

## 0.000000 Round 8c — Codex round 2: probe isolation, test-mode barrier, precise residue checks, atomic claim

All four findings were valid; each is fixed with the failure mode reproduced or exercised.

**P1-A — the probe wrote into the real `build/dist`.** True, and dangerous: it seeded
`TriCap-0.0.9.dmg` and created/deleted `TriCap-0.1.0.dmg` at real paths. Now
`TRICAP_DIST_OVERRIDE` relocates the dist directory **only when `TRICAP_PACKAGE_TEST=1`** — a
normal run ignores the override unconditionally and always uses the real `build/dist`. The probe
creates its whole workspace with `mktemp` outside the repository; every sentinel, seeded target,
injected failure and local-test product lives there. The real `build/dist` is fingerprinted
(file list + SHA-256) before the first scenario and after the last, and the probe fails on any
difference — verified additionally by an *independent* fingerprint taken by the invoking shell
around the probe: byte-identical across all runs, with a real artefact present in the directory
the whole time.

**P1-B — all-success stubs could mint a release.** Correct. Test mode now has a hard barrier in
the promotion path itself: a `TRICAP_PACKAGE_TEST=1` run can only claim
`TriCap-<version>-TEST-PROBE.dmg`, never the official name, and never prints the
`RELEASE PRODUCT` banner (a structural assertion refuses promotion if the name is not
TEST-PROBE-suffixed, independent of how the name was computed). New `all-success-barrier`
scenario proves it: stubs all green → exit 0, TEST-PROBE artefact only, official name absent,
"RELEASE PRODUCT" absent from the log.

**P2-C — the mount-residue assertion never matched.** Correct, and the root cause bit the
*product script* too: `/sbin/mount` prints `/private/var/…` while `$TMPDIR` paths read `/var/…`,
so the script's own "is it mounted?" check silently never matched, the detach was skipped, and
`rm -rf` clawed at a live read-only volume — reproduced with a stranded, undeletable mountpoint.
Fixes: the script now detaches unconditionally and **synchronously** (`detach_mountpoint` polls
the mount table by physical path until the volume is gone — `hdiutil detach` returning is not
the same as the unmount having completed, also observed); the probe checks residue by physical
workspace-path prefix in both the mount table and `hdiutil info` image paths, per scenario and
in a final global sweep. Never by volume name.

**P2-D — TOCTOU between the exists-check and `mv`.** Correct. Promotion now claims the final
name with `ln` — hard-link creation whose `EEXIST` failure is atomic in the kernel — then removes
the temp link; there is no check-then-move window and no reliance on `mv -n`. The
`concurrent-claim` scenario races two full packaging runs at one target with assertions that are
deliberately order-independent (either run may win — both orderings were observed across three
probe runs): exactly one exit 0, the loser logs the claim refusal, and the winner's file —
hashed and inode-recorded the moment it first appears — is never replaced.

Claude reported **10 scenarios, 67 checks, three consecutive full runs green** at this point.
Independent reruns later found the identity-pipeline flake described in Round 8d; that older
stability claim is superseded by Round 8d's gate-specific, five-run evidence. The Developer ID /
real-notarization happy path has never run on any machine; public release remains **BLOCKED**
(release/RELEASE_PLAN.md).

## 0.00000 Round 8b — Codex P1: the packaging script could strand an official-looking DMG

The finding was correct: the previous script created `build/dist/TriCap-<version>.dmg` at its
final path *before* notarization, and `fail()` exited with no trap — any late failure or
interruption left an unnotarized file with the official release name, violating the fail-closed
contract. `rm -rf "$DIST"` at the start could also delete historical products.

Rewritten (`scripts/package-release.sh`):

- The artefact is built as `TriCap-unverified.dmg` inside a per-run `build/dist/.pkg-tmp-XXXXXX`
  directory. The official name comes into existence only via one atomic same-volume rename,
  after **all** of: notarytool succeeded *and* its JSON says literally `Accepted`
  (machine-parsed; unparsable output fails), `stapler staple` + `stapler validate` passed, and
  `spctl --assess` passed on the app inside the mounted image.
- EXIT/INT/TERM handlers detach this run's mount and delete this run's temp directory on every
  path. Nothing else in `build/dist` is ever touched — the blanket `rm -rf` is gone.
- If the official target already exists, the script refuses before building (and re-checks
  before the rename): overwriting a shipped artefact is a human decision.
- `--local-test` unchanged in spirit: still named `…-LOCAL-TEST-adhoc.dmg`, may replace only its
  own previous file, can never displace a release-named product.
- Verdict tools are injectable **only** with `TRICAP_PACKAGE_TEST=1`; otherwise absolute system
  paths are used, so a poisoned PATH cannot substitute them.

Evidence without a Developer ID — `scripts/diagnostics/package-release-gate-probe.sh`, 8
scenarios, every check green: notary *rejected* / *command crash* / *unparsable output*, staple
failure, spctl rejection, SIGTERM mid-upload, target-already-exists, plus the real
`--local-test` build (mounts; contains TriCap.app + `/Applications` symlink; app verifies). Each
failure scenario asserts non-zero exit, no officially named file, no `.pkg-tmp-*` residue, no
lingering mount, and a pre-seeded historical DMG byte-identical afterwards.

The probe promptly earned its keep: the first trap implementation re-read `$?` in a shared
handler, so a SIGTERM during the upload window exited **0**. Signals now have their own handlers
and exit `128+signal` (observed 143 in the probe).

Still true, stated plainly: the *happy* path — real Developer ID signature, a real `Accepted`,
real staple, real spctl pass — has never run on any machine. Public release remains **BLOCKED**
(release/RELEASE_PLAN.md). Separately: the single `SKIP` Codex observed in its selftest run is
the long-documented display-compositing freeze of this environment (§2 / the
display-compositing probe), not a product regression — the selftest reports SKIP rather than
PASS in that state by design.

## 0.0000 Round 8 — banner layering, system mosaic, login item, release boundary

Four commits on `6eaa9bd`, in review order: `d912523` (A), `6e23723` (B), `a713ccb` (C), and the
docs/packaging commit (D). Every fix was reproduced before it was made, and both P0 regressions
have tests that demonstrably fail on the old code.

### A. The banner was erased by `.copy` blending — `d912523`

Verified first: `draw(_:)` painted the banner, then the selection punch-out (`.copy` + clear) and
the window highlight (`.copy` + 12% black) replaced every overlapping pixel. The failing tests
measured exactly that: banner-centre alpha **0.0** under a selection, **0.121** under a highlight.
Draw order was the whole fix — banner last, same overlay, no new window. 10 tests (7 fail on the
old order) including Retina 2× and recording mode, plus counter-tests proving the punch-out still
punches and the highlight still lifts. Snapshots `16`/`17` show both overlaps; the banner cannot
reach a capture because the overlay is `sharingType=.none`, dismissed before stills, and the SCK
filter excludes TriCap.

### B. The mosaic sampled the mirrored band — `6e23723`

`scripts/diagnostics/mosaic-mirror-probe.swift` reproduced it before any change: pixelating the
red top half of a red/blue fixture returned **blue** — the hand-written crop was double-flipped
(`CGImage.cropping` already works in row space). On a light page that imports white blocks from
the mirrored position: the reported symptom, reproduced byte-for-byte (`r=255` in the failing
test). The old grid was also rect-anchored (drift when the rect moves; 130 pixel mismatches in
the failing grid test).

Replaced with `CIFilter.pixellate()` — zero new dependencies, one shared sRGB `CIContext`,
clamped input, canvas-anchored grid. Two empirical findings worth a reviewer's attention, both
probed and pinned:

- pixellate samples each block at its **centre**, blocks tiled from `center`;
- cropping the **CIImage output** to the band returns wrong pixels whenever a block's centre
  falls outside the crop (probed with block 100 / crop at x≥60, which came back with the
  neighbouring block's colour — caught by a pre-existing test). The fix renders the full canvas
  and cuts the band in CGImage row space.

Semantic note, stated rather than hidden: the old code *averaged* each block; `CIPixellate`
*samples* it. The legacy test that encoded averaging was reworked to prove the same property
(mosaic samples the composited canvas, annotations included) under sampling semantics.
Measured cost 3.2 ms/frame on a real capture (selftest prints it). Snapshot `18` is the
before/after on report-shaped content.

### C. Launch at login — `a713ccb`

`SMAppService.mainApp` only; the system's status is the single truth (no Bool in AppSettings,
status re-read on pane appearance and after every action). Pure mapping/decision rules live in
TriCapKit with 8 tests; register/unregister idempotent; errors shown inline, never as success;
`requiresApproval` shows the toggle on with a warning and an `openSystemSettingsLoginItems()`
button. Snapshots `01` (notRegistered) and `19` (requiresApproval) with injected fake backends —
the snapshot process is a bare binary whose real status would be machine-dependent `notFound`.

### D. Release boundary

`release/RELEASE_PLAN.md` (status: **BLOCKED**, with the exact blockers),
`release/RELEASE_TEMPLATE.md` (Minimum requirement separated from Verified environments),
`scripts/package-release.sh` (DMG with drag-to-install layout; Developer ID + Hardened Runtime +
timestamp + notarytool + staple when an identity exists; **fail-closed** otherwise, with an
explicit `--local-test` mode producing `TriCap-<v>-LOCAL-TEST-adhoc.dmg`). Exercised on this
machine: both refusal gates, and the local-test DMG (mounts, contains the app + `/Applications`
symlink, app verifies). The notarized happy path has never run here — 0 signing identities.

### 4.11 Round-8-specific gaps

| Change | Not verified | How to check by hand |
|---|---|---|
| Banner layering | Only offscreen renders and bitmap sampling; nobody hovered a real full-screen window on a real overlay. Multi-display is covered by the "selection covers the whole view" case + per-display banner drawing, not by a live two-screen drag | Press ⌥⇧5, hover a maximised window, drag through the top of the screen |
| Mosaic | No human has drawn a mosaic in the live editor this round; visual evidence is snapshots 02/18. The user's original screenshot was not available as a fixture — the synthetic one matches the reported geometry (light page, dark rows, bright mirrored band) | Annotate a real screenshot over light content and export every format |
| Login item | **No real logout/login was performed** (would destroy this session). Real `register()` success needs a properly installed bundle: from a bare build directory the system reports `notFound` by design. The `.enabled`/`.requiresApproval` paths were exercised only through the injected fake | Install to /Applications, toggle on, approve if asked, log out and back in |
| Release packaging | The Developer ID / notarization / staple / spctl path has never run (no identity on this machine). Only the fail-closed gates and the local-test product are exercised | Run release mode on a machine with a Developer ID identity |

## 0.000 Round 7 — HUD placement and export performance

Two independent problems. Both were reproduced with a runnable probe first, and in the second case
the probe overturned the assumption the task started from — worth reading before the code.

### A. The recording HUD could land off screen

`scripts/diagnostics/hud-placement-probe.swift` transcribes the old
`makeFloatingWindow(size:belowTopOf:)` verbatim and runs it over realistic selections. On this
machine's real displays:

```
  live screen 1 1470×956 · full screen
    visibleFrame  (0, 43  1470×880)
    HUD           (585, 968  300×74)   ✗ 119 pt above the top
  live screen 1 1470×956 · 90% height, flush to bottom
    HUD           (585, 872  300×74)   ✗ 23 pt above the top
  live screen 1 1470×956 · 90% height, flush to top
    HUD           (585, 10   300×74)   ✗ 33 pt below the bottom
  live screen 2 1280×800 · full screen
    HUD           (-790, 968 300×74)   ✗ 86 pt above the top

  8/12 HUD placements land outside the visible frame
  1/12 countdown placements land outside the visible frame
```

Three separate defects: the "no room below" fallback moved the HUD *above* without checking that
it fit; no branch constrained y at all; and the x clamp used full display bounds rather than the
visible frame, so a HUD could also sit under the Dock. The countdown was centred with no clamping
whatsoever.

`HUDPlacement` replaces it: outside-below → outside-above → inside-bottom → inside-top, everything
clamped into the *matching* screen's `visibleFrame` (resolved by `CGDirectDisplayID`, never
defaulting to main). Placing the HUD inside the selection is safe — the chrome is
`sharingType = .none` and TriCap is excluded from the capture filter, so it is never recorded.

**The tests fail against the old algorithm.** Substituting it back produces:

```
✘ A full-screen selection still gets a visible HUD                     (585, 968) outside (0, 43, 1470, 880)
✘ A tall selection flush with the bottom of the display                (585, 872.4) outside
✘ A tall selection flush with the top of the display                   (585, 968) outside
✘ A full-screen selection on a negative-coordinate display …           (-790, 968) outside
✘ A zero-size region does not produce NaN                              (8, 12) outside
✘ Every selection on every display shape keeps the HUD on screen        140 issues
```

Runtime evidence in `--selftest`, against every attached display:

```
== HUD placement
  PASS  every HUD and countdown placement is fully on its own screen  — 12/12 across 2 display(s)
  PASS  a click at the centre of Stop hits the Stop button
  PASS  three clicks on Stop stop the recording exactly once  — stops=1, clicks=3
```

Snapshot `15-hud-placement-near-fullscreen.png` draws the whole relationship at 1:1 — display,
visible frame, a 94%-tall selection, and the resulting placement (`strategy: insideTop`).

### B. Export was slow for a reason nobody had measured

The task assumed the fix was to move encoding into the recording. Measuring first showed that was
the *second* problem, and would not have worked on its own.

`TriCap --benchmark-export` profiles per-frame cost. At 1440×900:

```
    PNG decode            0.1 ms/frame
    RGBX extraction       8.7 ms/frame
    WebPAnimEncoderAdd  857.2 ms/frame   <- dominates
    assemble              0.2 ms total
    capture interval     83.3 ms/frame at 12 fps
    encode is 10.3× the capture interval — pre-encoding CANNOT keep up
```

Encoding was **ten times slower than real time**, so a live pre-encoder would have filled its
backlog in about a second and abandoned on every recording. The cost was two
`WebPAnimEncoderOptions` flags — neither a user setting — that TriCap had been setting since the
first commit: `minimize_size` (retry frames hunting for a smaller result) and `allow_mixed`
(encode **every frame both lossily and losslessly**, keep the smaller). Turning both off:

| strategy | `WebPAnimEncoderAdd` | file size |
|---|---|---|
| `.thorough` (shipped through `79d20b3`) | 873.7 ms/frame | 1304 KB |
| `.balanced` (new default) | **45.6 ms/frame** | 1336 KB (+2.5%) |

19× faster for 2.5% larger files — and now under the 83 ms capture interval, which is what makes
pre-encoding viable at all. The user's quality, method, lossless and loop settings are untouched;
`AnimationEncodeStrategy.thorough` still exists so the trade is reversible and measurable.

### The performance measurement, and how to repeat it

```bash
caffeinate -dimsu .build/release/TriCap --benchmark-export /tmp/bench \
  --frames 181 --runs 3 --width 1440 --height 900
```

- **Material**: synthesised, not screen-captured, and the report says so. A real screen recording
  is not reproducible here (the display can stop compositing, and content differs run to run),
  while what governs encoder cost is frame entropy — which a generator can hold constant. Every
  frame differs from its predecessor across the whole canvas, so libwebp's frame coalescing is
  fully defeated. That is the **worst** case, and the one real video-like content approaches.
- **Pacing**: the simulated recording delivers frames at the true 83.3 ms interval. An earlier
  version submitted them as fast as it could build them, which left the pre-encoder no wall-clock
  slack and made the fast path measure as a 3.9% *loss*. Without pacing the number is meaningless.
- **Three arms**, so the two changes are separable.
- **Median of three runs.**

1440×900, 181 frames (15 s at 12 fps):

| arm | tail latency (median) | all runs | vs A | size |
|---|---|---|---|---|
| A  `.thorough`, no pre-encode — the `79d20b3` baseline | **177.0 s** | 163.1, 177.0, 238.6 s | — | 9672 KB |
| B  `.balanced`, no pre-encode | **11.3 s** | 11.3, 11.8, 10.1 s | 93.6% faster | 9929 KB (+2.7%) |
| C  `.balanced` + live pre-encode | **0.85 s** | 0.80, 0.85, 1.23 s | **99.5% faster** | 9929 KB (+2.7%) |

**In-recording cost, measured separately** as how late each frame was against its delivery slot —
a frame later than one interval is one a real recorder would have dropped:

| arm | worst lateness | frames later than one interval |
|---|---|---|
| A | 0.2 ms | 0 |
| B | 0.2 ms | 0 |
| C | 0.2 ms | 0 |

Pre-encoding adds no measurable cost to recording: `submit` does no encoding on the capture path,
and at 45.6 ms per frame the encoder finishes well inside each 83 ms interval.

The target was a ≥50% reduction. The measured reduction is 99.5%, and the two contributions are
reported separately because they are independent: the strategy change alone is 93.6%, and it is
what made the pre-encoder possible rather than merely additive.

### How the fast path stays safe

It is an optimisation that may change only *how long the user waits*:

- `PreEncodeReuse` is a pure function that defaults to **no**. It requires the full untrimmed range
  (same frame count *and* the same timestamps), no annotations, the same canvas, all four encoder
  parameters unchanged, and the same end timestamp.
- Whichever route runs, the file goes through the same write, re-read and verification.
- The PNG frames are untouched throughout, so nothing recorded can be lost by this path.
- `IncrementalTimeline` is the one rule both the live and export timelines run, because a
  one-millisecond divergence would make the pre-encoded file silently wrong for the timeline it
  claims. Pinned by a test that compares the two over steady, sub-millisecond, stalled, single-frame
  and identical-timestamp sequences.

`--selftest` §Live pre-encoding drives all of it against real libwebp and real written files —
fast-path hit, output equality between both routes, every fallback, a forced backlog, cancellation,
and a timing diagnostic (21 checks).

## 0.00 Round 6 — Codex acceptance fixes

All four were real. Two of them only reproduced in a scenario the round-5 tests never wrote down,
which is the interesting part — so the new tests were checked against the *old* code and do fail
there. Test count 339 → **369**.

| # | Finding | What was actually wrong | Fix |
|---|---|---|---|
| 1 | Escape priority depended on push order | `PriorityHotKeyClaim` fired `stack.last`. "Pin, then record" passed; "record, then pin" silently handed Escape to the pin, so a recording could no longer be cancelled from another app — exactly what the system-wide Escape exists for. | An explicit `Priority` value (`.recording` = 1000 > `.pin` = 100). The active handler is the highest priority, most recent within a priority. A lower-priority claim still gets a token and takes over automatically when the higher one releases, so pinning mid-recording neither fails nor has to re-claim. |
| 2 | `closeFrontmost` closed the oldest pin | Order came from `NSApp.windows.firstIndex`, and `max(by: { $0.orderedIndex > $1.orderedIndex })` therefore always resolved to the earliest window. Clicking a pin did not change the answer at all, because AppKit does not reorder that array. | `PinFocusOrder` in TriCapKit, maintained by TriCap: a new pin goes to the front, `pinDidInteract` (mouse-down, scroll, magnify, right-click) brings a pin forward and orders it front, `remove` falls back to the pin behind. `NSApp.windows` is no longer consulted. |
| 3 | Desktop furniture was a hover and snap target | `isSelectable` allowed `level <= 0`, and `RegionSelector.snapEdges` was built from the **raw** candidate list rather than the filtered one — so even windows that could not be hovered still contributed snap lines. | `level == WindowPicker.ordinaryApplicationLayer` (exactly 0), and a new `WindowPicker.snapEdges` derived from the same filter. `RegionSelector` builds both `candidates` and `snapEdges` from it; display bounds are still always included. |
| 4 | P3/HDR copies never confirmed the copy | `copyStillToClipboard` had the colour advisory in the `if` and the confirmation in the `else`, so on a wide-gamut display — the common case — the user saw a colour note and no "Copied". | `ClipboardCopyNotice.success(…)` in ExportCore always leads with `Copied W × H`; `(image only)` and any colour advisory are appended to that same message. |

### Runtime evidence, not just unit tests

`--selftest` gained two sections that exercise findings 1 and 3 against the real system:

```
== Selectable windows
  window levels present: -2147483626, -2147483624, -2147483622, -2147483603, -2147483602, 0, 24, 25, 26, 2147483630
  38 window(s), 9 selectable, 7 below the application layer
    excluded  level -2147483602  1280×67    underbelly
    excluded  level -2147483603  1280×800
    excluded  level -2147483622  1470×956   Fullscreen Backdrop
    excluded  level -2147483624  1470×956   Wallpaper-C18A1F0E-…
    excluded  level -2147483624  1280×800   Wallpaper-948D95D8-…
    excluded  level -2147483626  1470×956   Display 1 Backstop
  PASS  every selectable window is on the ordinary application layer
  PASS  nothing below the application layer survives the filter
  PASS  snap edges are the selectable windows plus the displays  — 11 = 9 window(s) + 2 display(s)
  PASS  no excluded window contributed a snap edge

== Escape priority
  PASS  Escape cancels the recording, not the pin created after it  — recording=1, pin=0
  PASS  the pin gets Escape back when the recording ends  — recording=1, pin=1
```

That independently reproduces the reported window list on this machine — `underbelly`, the
wallpaper windows, Fullscreen Backdrop and Display Backstop are all there, and all now excluded.

The pin-ordering section prints the array it no longer trusts, which shows the original defect
directly:

```
  NOTE  NSApp.windows order for the two pins: 1,2  (TriCap does not rely on it)
  PASS  the newest pin is the frontmost one              — frontmost=2, newest=2
  PASS  interacting with a pin brings it forward          — frontmost=1, touched=1
  PASS  Escape closes the pin the user last touched       — remaining=1, frontmost=2
```

`1,2` is creation order even though pin 2 was ordered front last — so the old `firstIndex`-based
ordering resolved to pin 1, the oldest.

**A second display is attached for this round** (1280×800 at AppKit `(-1280, 156)`, i.e. negative
coordinates), so the multi-display gap listed in §4.9 is now partly closed: the window survey,
the level filter and the snap-edge construction all ran against two displays.

## 0.0 Round 5 — pinning, window-aware selection, clipboard-first, icon

Five areas. Full requirement → file → test mapping is in
[REQUIREMENTS.md](REQUIREMENTS.md#round-5--pinning-window-aware-selection-clipboard-first-app-icon)
(rows N1–N21); this section is the reviewer's short version.

| Area | New files | New tests |
|---|---|---|
| Pin shortcut (`F3`) | `PriorityHotKeyClaim.swift`, `SharedEscapeKey.swift` | *Bare-key allow list* (6), *Independent shortcut registration* (3), *Pin shortcut migration* (5), *Shared Escape stack* (8) |
| Pin windows | `PinGeometry.swift`, `PinWindow.swift`, `PinboardController.swift`, `PasteboardImage.swift` | *Pin memory limits* (7), *Pin placement* (7), *Pin zoom* (5), *Pin opacity* (2), *Pasteboard image policy* (9) |
| Window-aware selection | `WindowPicker.swift`, `WindowSurvey.swift` | *Window picking* (10), *Click versus drag* (4), *Edge snapping* (9) |
| Clipboard-first screenshots | — (`StillCaptureAction` in `AppSettings`) | *Screenshot post-capture action* (2) |
| App icon | `scripts/generate-icon.swift`, `Resources/AppIcon/` | icon toolchain checks, §3.8 |

Three decisions worth a reviewer's attention:

1. **`F3` is a pin shortcut, not a capture shortcut.** `⌥⇧5` is unchanged. The two register in
   separate `GlobalHotKeyMonitor` slots and roll back independently, because `F3` is Mission
   Control's factory binding and is the one likely to fail. The bare-key allow list is *exactly*
   F1–F20, enumerated — never a letter or a digit, which a modifier-less hot key would make
   untypeable system-wide.
2. **One Escape, two claimants.** Carbon refuses a duplicate registration, so a recording started
   while a pin was open would have failed to claim Escape. `PriorityHotKeyClaim` keeps one
   registration and a stack of handlers; the top claimant wins and popping restores the one
   underneath. The self-test asserts the duplicate-registration refusal directly rather than
   assuming it.
3. **A pin releases its bitmap explicitly.** AppKit keeps a window that was on screen alive past
   `close()`; that is reproducible with a plain `NSPanel` and no TriCap code
   (`scripts/diagnostics/panel-lifetime-probe.swift`). Since a pin holds a full-resolution
   screenshot, `PinWindow.tearDown()` nils the image, the image view and the delegate rather than
   waiting for a `dealloc` that is not TriCap's to schedule. The self-test asserts the *bitmap* is
   gone, which is deterministic, and reports the window shell's fate as a NOTE rather than a check.

Also corrected while testing: `WelcomeView` still said "drag out a region… annotate, then save",
which the clipboard-first default made untrue. It now describes clicking a window, pasting, and
pinning. The Settings window grew from 470 to 700 pt tall so the whole General tab — two shortcuts,
the post-screenshot action, the countdown and the permission row — is visible without scrolling.

## 0. Round 4 — Codex acceptance fixes

Baseline `bdddb89`. Five findings, all reproduced in the source before being changed.

| # | Root cause confirmed | Fix | Tests |
|---|---|---|---|
| 1 | `didSet` assigned `settings = reconciled` and returned; the re-entrant pass then notified with `oldValue = proposal`. For settings written before presets existed — which always load as `.custom` even when their values match a preset — the first edit *also* triggers a relabel, so `onChange` saw `proposal → normalised`, both already carrying the new hot key. `AppDelegate` compared them, saw no change, and never re-registered the shortcut. | `AppSettings.resolveUpdate(previous:proposed:)` returns the normalised value paired with the true previous one; `SettingsStore` guards the re-entrant pass with `isNormalizing`. One normalisation, one persist, one notification. | `SettingsUpdateTests` (7) — the key case asserts `update.previous.hotKey != update.current.hotKey` |
| 2 | `stop.keyEquivalent = "\r"` on a button inside a borderless floating panel that never becomes key. Nothing registered a global Return. The label said "Return stops". | Label is `Esc cancels · Click Stop to finish`; the `keyEquivalent` is removed with a comment explaining why it could never fire. | snapshot 05 |
| 3 | `runCountdown` used `NSEvent.addLocalMonitorForEvents`, which only sees keys delivered to TriCap. The global Escape was claimed in `present(...)`, i.e. only once recording had begun — while Settings and the countdown panel both said Escape worked from other apps. | `RecordingChromeController` claims `TransientHotKeyClaim` before the first tick and rebinds it in place for the recording. `RecordingHUD` is now a renderer; the local monitor is gone. | `TransientHotKeyClaimTests` (10) + four new selftest checks on the real Carbon path |
| 4 | `ToastView` rendered file name, folder·size, clipboard and warning — never `detailDescription`. The round-3 snapshot showed it missing; the claim that dimensions/frames/duration were confirmable was wrong. | The detail line is rendered; the panel height comes from `NSHostingView.fittingSize` so a wrapping warning grows it instead of being clipped. | `ExportSummaryTests` +3 · snapshots 10 and 13 |
| 5 | `.maximum` was described as "no downscaling and the highest quality factor" while capping at 3840 px and stopping at 20 fps / 95. WebP copy quoted "25–35% smaller than JPEG" and "every current browser"; the size guidance asserted a precise quartering rule. `hasSeenWelcome`'s comment said `true` until shown. | Renamed *Up to 4K*, summary quotes the actual cap. Format and size copy made conditional and unquantified. Comment corrected. Values were **not** raised to 30 fps / 100 — that would multiply recording memory. | `topPresetCopyIsAccurate`, `formatCopyAvoidsInventedNumbers` |

### A hazard the rename exposed

Renaming a `QualityPreset` case changes its persisted raw value. `decodeIfPresent` **throws** on an
unrecognised raw value (verified with a probe), and `SettingsStore` decodes with `try?` — so a
stored `"maximum"` would have discarded the user's *entire* settings blob: save folder, vault root,
hot key, everything. Enum fields now decode through `decodeTolerantly`, falling back to the default
(or `.custom`, which preserves every stored number). No blob on this machine was affected — the
domain held only the permission flag — but the same trap would have applied to any future rename or
to settings written by a newer build.

---

## 0.1 Round 3 — usability and quality

Baseline `df0cacc`. This round is UI/UX, the settings model and tests; the capture, colour-space,
concurrency and file-writing code reviewed in rounds 1–2 is untouched except where a UX fix needed
a new read-only accessor.

### UX problems found, and which were fixed

| Pri | Problem | Fixed | Where |
|---|---|---|---|
| P0 | Nothing on first launch: no Dock icon, no window, no hint that permission is needed | ✅ | `WelcomeView`, shown once, reopenable |
| P0 | A **Quality** control was offered for PNG, which ignores it entirely | ✅ | `OutputFormat.usesQualityParameter` |
| P0 | After saving, nothing said where the file went or what was copied | ✅ | `ExportSummary` + toast with **Show in Finder** |
| P0 | The menu bar looked identical whether or not TriCap could capture | ✅ | permission state + in-progress row |
| P0 | The overlay's mode hint vanished on mouse-down; nothing said what release would do | ✅ | persistent banner, corner brackets, release hint |
| P1 | Quality was raw encoder numbers with no result-oriented choice | ✅ | `QualityPreset` (4 presets + Custom) |
| P1 | The recording HUD had no cancel affordance and no sense of the limit | ✅ | progress bar + a cancel/stop line — *the wording shipped here was wrong and is corrected in round 4, §0 item 2* |
| P1 | Tool glyphs unlabelled, no shortcuts | ✅ | active-tool name, `⌘1`–`⌘5`, real tooltips |
| P1 | Settings mixed limits with quality, always showed every parameter | ✅ | four tabs, conditional Advanced |
| P1 | The editor never showed the save destination | ✅ | `Saves to …` + **Show in Finder** |
| P2 | No annotation selection/move after drawing | ❌ deferred | out of scope: needs hit-testing and handles |
| P2 | No in-editor animation preview (the Frame slider scrubs instead) | ❌ deferred | |
| P2 | No capture history / recents | ❌ deferred | explicitly out of scope |
| P2 | Onboarding is static text, not an interactive walkthrough | ❌ deferred | |

### The quality rules

| Preset | Still quality | Recording long edge | Recording fps | Animation quality |
|---|---|---|---|---|
| Smaller file | 65 | 960 | 10 | 60 |
| **Balanced** (default) | 85 | 1440 | 12 | 80 |
| Sharper | 95 | 1920 | 15 | 90 |
| Up to 4K | 100 | 3840 | 20 | 95 |

Three invariants, each with a test:

1. **The controls map to real encoder arguments.** `QualityPresetApplicationTests` asserts each
   preset writes `stillQuality`, `recordingLimits.maxLongEdgePixels`, `recordingLimits.frameRate`
   and `animatedWebPOptions.quality` — the four values that reach `StillImageCodec.encode`,
   `SCStreamConfiguration` and `WebPConfig`.
2. **PNG never shows a quality control.** `QualityParameterRealityTests` encodes the same detailed
   image at quality 1 and 100: PNG's bytes are byte-identical, JPEG's and WebP's are not.
3. **Custom values are never overwritten.** Editing any advanced value re-derives the label as
   `.custom`; applying `.custom` is a no-op; a settings blob with no `qualityPreset` key loads as
   `.custom` with every stored number preserved. The old default still quality was 90, which
   matches no preset — snapping it to one would have silently changed existing users' output.

The animated-WebP quality assertion deliberately checks that the bytes **differ**, not that they
shrink monotonically: TriCap encodes animations with `allow_mixed`, so libwebp may pick a lossless
frame at a high quality factor and produce a *smaller* file than a lossy frame at a low one. Size
monotonicity is asserted for the still formats, where no such mode switch happens.

### A bug found while writing the migration tests

`RecordingLimits` and `AnimatedWebPOptions` conformed to `Codable` synthetically, so decoding
assigned their stored properties directly and skipped their own clamping initializers. A corrupt
or future settings blob could therefore load `frameRate: 999`, `maxLongEdgePixels: 99999` — values
the UI cannot represent and the capture path was never designed for. Both now decode through the
clamping initializer.

---

## 0.2 Review round 2 — what changed

Every item was reproduced in the code before being changed; none was taken on trust.

| # | Issue (as raised) | Root cause confirmed | Fix | Tests |
|---|---|---|---|---|
| A1 | Recording mutual exclusion released too early | `beginCapture`'s `defer` set `isCapturing = false` as soon as `recordClip` returned, which was right after `hud.showRecordingHUD` — a second trigger then overwrote `self.recorder`, the shared `StopProxy.shared.handler`, the HUD windows and the Esc monitor | `RecordingSession` (awaits full teardown before returning) + `CaptureSessionGate` (single occupancy for the whole pipeline); `HUDStopProxy` is now per-HUD instead of a singleton | `RecordingSessionTests` (10), `CaptureSessionGateTests` (5) |
| A2 | Static screen never hit the duration ceiling | `FrameConverter` drops non-`.complete` frames, and the `elapsed > maxDuration` check lived inside `stream(_:didOutputSampleBuffer:)`, so with no new frames it never ran | 10 Hz `ContinuousClock` tick in `RegionRecorder` (latched once, invalidates its own timer); `RecordedClip.wallClockDuration`; `ClipTrimmer.trimmedDuration`; `ClipTiming.timeline(totalDuration:)` | `TrimmedDurationTests` (8), `RecordedClipDurationTests` (4), `ClipTimingTests` (10) + selftest §static-screen |
| A3 | Colour provenance lost / in-flight callback raced stop | Capture originally requested sRGB before source inspection; the first teardown fix also snapshotted before the serial sample queue was drained | `colorSpaceName` is left unset so SCK uses the native display profile; untagged buffers fall back to captured ICC/name metadata, scaling preserves it and P3/EDR metadata reaches the notice. `StreamOutput.commit` and `stopAccepting` share a lock, then teardown drains `sampleQueue` before snapshot/reset | `ColorSpacePropagationTests` (9), `StreamCommitBarrierTests` (2) + selftest assertion |
| A4 | Editor retain cycle | `onClosed: { window?.close() }` captured the local `var window` box strongly: `window → contentViewController → EditorView → model → closure → box → window` | `EditorPresenter` with a `WindowBox` holding the window **weakly**; `release(_:)` drops the content view controller | selftest §editor window lifecycle asserts `weak` model and window are both `nil` after close |
| A5 | Recording Esc was local-only | `NSEvent.addLocalMonitorForEvents` only sees keys delivered to TriCap | Carbon `RegisterEventHotKey` with a **bare** Escape in a dedicated slot, claimed only while recording. Verified it needs no Accessibility (see §3.7) | selftest §recording-cancel hot key (8 checks) |
| B6 | Failed re-registration left no shortcut | `register()` unregisters first; a rejected new combo left both slots empty | `HotKeyRegistrationPolicy.apply` rolls back to the previous combo and the app reverts the stored setting | `HotKeyRegistrationPolicyTests` (6) |
| B7 | Unsafe case-insensitive fallback | The first volume-aware fix still treated an unavailable capability as insensitive | `MarkdownReference.CaseSensitivity` uses the reported volume rule and conservatively falls back to sensitive/absolute-path behaviour when unavailable | `MarkdownCaseSensitivityTests` (6) |
| B8 | Fallback write could report delayed I/O failure as success | The first `O_EXCL` fallback ignored `fsync` and `close` return values | Three atomic claim strategies remain; the `O_EXCL` path now removes the claimed name and returns the saved errno when flush or close fails | `FileClaimStrategyTests` (13, including injected ENOSPC/EIO) |
| B9 | HUD Stop button contrast | Default (light) appearance rendered a dark bezel + dark label on the dark HUD | `content.appearance = .darkAqua` + white content tint | snapshot `05-recording-hud.png` regenerated |
| B10 | One-frame clip exposed index 1 | Slider ranges were padded with `max(1, frameCount - 1)` and `max(trimStart + 1, trimEnd)` | `ClipTrimUI` returns `nil` when there is nothing to trim; the editor hides the sliders and says "Single frame — nothing to trim." | `ClipTrimUITests` (4) + snapshot `07-editor-single-frame-clip.png` |

**A defect found by the new tests during this round.** The first version of the A2 fix re-fired the
duration ceiling on every 10 Hz tick (21 callbacks in one run) because `handleAutoStop` only
guarded on `state == .running`, which stays `.running` until `finish()`. The selftest's "it fired
exactly once" check caught it; `handleAutoStop` now latches and invalidates its own timer.

### Round-3 verification (2026-08-03)

- `./scripts/test.sh` — **198 tests in 27 suites passed**.
- `./scripts/test.sh --sanitize=thread --filter StreamCommitBarrierTests` — both commit-barrier
  regressions passed under ThreadSanitizer.
- `./scripts/build-app.sh release` — release bundle built, ad-hoc signature verified, and `otool`
  listed only system frameworks / Swift runtimes.
- `caffeinate -dimsu .build/debug/TriCap --selftest ./build/codex-round3-selftest-20260803` —
  **ALL CHECKS PASSED**, including real still capture, moving recording, cancel-after-in-flight,
  static-screen duration ceiling, export re-read and editor lifecycle.

---

## 1. Implementation scope

Delivered in full:

- SwiftPM package with the six targets described in [ARCHITECTURE.md](ARCHITECTURE.md), plus
  `scripts/build-app.sh` which assembles a runnable `TriCap.app`.
- Menu-bar app (no Dock icon), global hot key `⌥⇧5` via Carbon `RegisterEventHotKey`, settings
  window with hot-key recorder.
- Cross-display region selector with mode switching (`R` record / `S` screenshot), `Esc` cancel,
  live pixel-size readout.
- Still capture via `SCScreenshotManager`; region recording via `SCStream` with a bounded frame
  buffer; countdown; floating stop HUD; head/tail trimming.
- Annotation: arrow, rectangle, text, freehand, mosaic, undo/redo; for clips the item list is
  composited onto every frame as a fixed overlay.
- Export: PNG, JPEG, static WebP, animated WebP — all with post-write re-read verification.
- Clipboard reference: relative Markdown / Obsidian wiki-link inside the vault root, absolute path
  outside it.
- libwebp 1.6.0 vendored from source; no runtime dependency on Homebrew or anything else.
- 198 automated tests; a headless end-to-end `--selftest`; a headless `--render-ui-snapshots`.

Deliberately not implemented (per the brief): OCR, scrolling capture, sensitive-information
detection, audio, cloud sync, GIF/APNG/WebM, a capture history library, App Store distribution.

---

## 2. Key decisions a reviewer should be aware of

| # | Decision | Rationale |
|---|---|---|
| D1 | **SwiftPM package + `build-app.sh`, not an `.xcodeproj`** | `xcodebuild` does not exist on this machine (CLT only). The script does the bundle packaging Xcode would do. Targets map 1:1 to an `.xcodeproj` if one is wanted later. |
| D2 | **swift-testing, not XCTest; `scripts/test.sh` wrapper** | `XCTest.framework` is genuinely absent from CLT. `Testing.framework` ships with CLT but is not on SwiftPM's search path unless Xcode is the active developer directory; the wrapper adds `-F` and two `-rpath` flags. Plain `swift test` works if Xcode is installed. |
| D3 | **A sixth module, `TriCapKit`, beyond the five suggested** | Coordinates, limits and settings are needed by three of the five suggested modules. Without it, `SelectionUI` would have to depend on `CaptureCore` (inverting the natural order) or the coordinate math would be duplicated — the one thing that must exist in exactly one place. |
| D4 | **`DisplaySurvey` in `TriCapKit`, not `CaptureCore`** | It is the sole `NSScreen` reader and produces pure value types; putting it beside the geometry lets every coordinate test run headless. |
| D5 | **libwebp vendored as C source, not linked or prebuilt** | Only way to satisfy "no `brew install` for the end user" while staying auditable and rebuildable from a clean checkout. See [docs/LIBWEBP.md](docs/LIBWEBP.md). |
| D6 | **Frames held PNG-compressed in memory** | 15 s × 12 fps × 1440 px as decoded bitmaps is ~930 MB; PNG-compressed it measured **3.3 MB** for a real 5 s 800×600 capture. Encoding cost (~10–25 ms/frame) fits the 83 ms budget at 12 fps. |
| D7 | **Snapshot-based undo, not a command log** | Annotation items are tiny value types; snapshots cannot drift out of sync with the model. History is bounded at 100 steps. |
| D8 | **Animated-WebP verification checks duration, not frame-count equality** | libwebp coalesces frames identical to their predecessor. This was **found by the self-test** (an equality check failed on a real recording, 53 stored vs 57 submitted) and fixed. `stored ≤ submitted` and `totalDuration == endTimestamp` are the real invariants. |
| D9 | **A motionless recording is kept, not rejected** | When *every* frame is identical, libwebp drops the ANIM chunk and writes a still WebP (loop count 1, zero duration). Rejecting it would delete the user's recording; TriCap keeps the file and reports `collapsedToSingleFrame`. Also found via the self-test. |
| D10 | **Carbon `RegisterEventHotKey`, not an `NSEvent` global monitor** | A global monitor needs Accessibility permission — a second TCC prompt — and cannot stop the key reaching the focused app. Carbon's API is public and still supported. |
| D11 | **Race-safe filenames via `link(2)`** | `fileExists` + write has a window; `link` fails atomically with `EEXIST`. |
| D12 | **Permission tri-state uses a `UserDefaults` "has asked" flag** | macOS offers no API distinguishing not-determined from denied; `CGPreflightScreenCaptureAccess()` returns false for both. The heuristic and its failure mode are documented in the source. |

---

## 3. Verification commands and results

All commands run from the repository root. Every result below was actually produced; none is
predicted.

### 3.1 Clean-state Debug and Release builds

```bash
rm -rf .build build
swift build            # Debug
swift build -c release
```

```
Debug   → Build complete! (36.21s)
Release → Build complete! (36.57s)
```

Zero warnings, zero errors (`swift build 2>&1 | grep -c "warning:"` → `0`).

`xcodebuild` was **not** run — it does not exist on this machine (evidence in §5.1).

### 3.2 Test suite

```bash
./scripts/test.sh
```

```
✔ Test run with 198 tests in 27 suites passed.
```

Suites: Coordinate conversion · Output sizing · CaptureRegion resolution · Clip trimming ·
**Trimmed duration semantics** · **Recorded clip duration** · Animated WebP timeline ·
Frame buffer limits · **Recording session lifecycle** · **Capture session gate** ·
Annotation document · Annotation rendering · Markdown reference ·
**Markdown containment case sensitivity** · Output file writing · **Output file claim strategies** ·
libwebp bridge · Animated WebP frame coalescing · Magic byte detection ·
Export service (stills / animated WebP / degenerate recordings) · Screen recording permission
state · **Colour space propagation** · **Recording stream commit barrier** · **Clip trim slider ranges** ·
**Hot key registration roll-back**. (Bold = added in round 2.)

Required coverage, mapped:

| Required area | Suite / cases |
|---|---|
| Coordinate conversion | *Coordinate conversion* (12), *CaptureRegion resolution* (8) — includes the AppKit↔Quartz flip and its inverse, Retina ×2 snapping, a secondary display whose AppKit and Quartz origins disagree, and a 1-pixel Retina corner selection |
| Trim boundaries | *Clip trimming* (8) — inclusive ranges, inverted handles, out-of-range clamping, empty input, byte recount |
| Annotation model + undo/redo | *Annotation document* (14), *Annotation rendering* (8) |
| Markdown relative path | *Markdown reference* (13) — nested, outside, `..`, case-insensitive, `/tmp` vs `/private/tmp` (both for an existing and a not-yet-created file), `Vault` vs `VaultBackup`, percent-encoding, wiki-links |
| Animated WebP timestamps / loop / validity | *Animated WebP timeline* (6), *libwebp bridge* (12), *Animated WebP frame coalescing* (3), *Export service — animated WebP* (6) |

### 3.3 End-to-end self-test (real screen capture)

```bash
./scripts/build-app.sh debug
.build/debug/TriCap --selftest ./build/selftest
```

Run with `caffeinate -dimsu` — see §4.6 for why. **This round the display was compositing live,
so nothing was skipped: `ALL CHECKS PASSED`.** Key lines from the last Release run:

```
  PASS  SCShareableContent reachable  — 1 display(s), 13 app(s)
  PASS  SCScreenshotManager capture  — 800x600
  PASS  recording finishes with at least one frame  — 80 frames, 6.73 s, 15713 KB retained
  PASS  recording captured the on-screen motion as multiple frames  — 80 frames    <- not skipped
  PASS  colour-space outcome survived teardown
  PASS  animated WebP written  — clip.webp 45560 bytes
  PASS  stored frame count is within the submitted count  — 64 stored of 76 submitted
  PASS  total playback duration is preserved  — 6400 ms vs 6400 ms
  PASS  loop count is 0 (infinite)
  PASS  fixed overlay present on every frame  — sampled (40,20) in all 64 frames
  PASS  the ceiling fired although no frame ever passed it  — last frame at 0.00 s, ceiling 3 s
  PASS  static clip reports the real recorded length  — 1 frame(s), reported duration 2.99 s
  PASS  a bare Escape can be claimed system-wide without Accessibility
  PASS  EditorModel deallocated after close
  PASS  editor NSWindow deallocated after close

== Summary
  ALL CHECKS PASSED
```

The round-2 transcript below is kept for comparison:

```
TriCap self-test
  libwebp: 1.6.0 (encoder/mux/demux (1, 6, 0)/(1, 6, 0)/(1, 6, 0))

== Screen recording permission
  CGPreflightScreenCaptureAccess() = true
  PASS  SCShareableContent reachable  — 1 display(s), 13 app(s)

== Displays
  display 2: appKit=(0,0 1920x1080) quartz=(0,0 1920x1080) scale=2.0 pixels=3840x2160
  NOTE: only one display is attached, so multi-display selection is NOT covered by this run.

== Region resolution
  PASS  region resolves  — pixels=(200,1360 800x600) sourceRect(pt)=(100,680 400x300)
  PASS  pixel size == points × scale
  PASS  1-pixel top-left corner selection  — (0,0 1x1)

== Still capture
  PASS  SCScreenshotManager capture  — 800x600, source colour space kCGColorSpaceSRGB
  PASS  capture matches the requested pixel rect
  PASS  capture is sRGB  — kCGColorSpaceSRGB

== Annotate and export stills
  PASS  export PNG / JPEG / WebP, magic bytes match the extension, references are vault-relative
  PASS  outside-vault reference is the absolute path
  PASS  filename collision resolves to -1  — collision.png, collision-1.png

== Recording (5 s target)
  NOTE: the screen is not compositing live (two stills either side of a
        deliberate on-screen change are byte-identical). Multi-frame
        expectations are skipped; everything else still runs.
  PASS  recording finishes with at least one frame  — 1 frames, 6.18 s, 600 KB, stop=userStopped
  SKIP  recording captured the on-screen motion as multiple frames  — not verified in this run:
        the display is not compositing live
  PASS  colour-space outcome survived teardown  — kCGColorSpaceSRGB converted=false wide=false   <- A3
  PASS  measured wall clock is consistent with the frame span  — wall 6.18 s, duration 6.18 s
  PASS  retained memory / frame count stayed under the ceiling
  PASS  frame timestamps are non-decreasing

== Trim and export animated WebP
  PASS  trim keeps the expected frame count · trimmed clip restarts at t=0
  PASS  trimmed span is positive and no longer than the clip
  PASS  timeline is strictly increasing and starts at 0
  PASS  animated WebP written · container matches what libwebp produced
  PASS  canvas size round-trips  — 800x600
  PASS  markdown reference is vault-relative  — ![clip](assets/clip.webp)
  PASS  fixed overlay present on every frame

== Cancel an in-flight recording
  PASS  cancel completes and releases every retained frame
  PASS  finish after cancel yields no clip  — noFramesCaptured
  PASS  cancelling wrote no file  — 6 files in assets/, unchanged from 6

== Static-screen recording (duration ceiling)                                                   <- A2
  PASS  duration ceiling fired without any new frames  — durationLimit
  PASS  it fired exactly once  — 1 auto-stop callback(s)
  PASS  it fired at the ceiling, not when the next frame happened to arrive  — waited 5.1 s for a 3 s ceiling
  PASS  the ceiling fired although no frame ever passed it  — last frame at 0.00 s, ceiling 3 s
        — a frame-driven check could not have fired
  PASS  static clip reports the real recorded length, not the frame span
        — 1 frame(s), frame span 0.00 s, reported duration 2.98 s
  PASS  static clip stop reason is the duration limit  — durationLimit
  PASS  exported timeline covers the whole recording  — 2983 ms across 1 frame(s)
  PASS  static recording exports successfully  — static.webp container=webpStill collapsed=true

== Recording-cancel hot key                                                                     <- A5
  AXIsProcessTrusted() = false  (Accessibility is never requested)
  PASS  primary capture shortcut registers  — ⌥⇧5
  PASS  a bare Escape can be claimed system-wide without Accessibility
  PASS  claiming Escape leaves the capture shortcut registered  — ⌥⇧5
  PASS  the two slots hold different combinations
  PASS  releasing Escape does not release the capture shortcut
  PASS  Escape can be re-claimed for the next recording
  PASS  a modifier-less combination is refused for the configurable shortcut
  PASS  all hot keys released at the end of the run

== Editor window lifecycle                                                                      <- A4
  PASS  editor window created · presenter owns exactly one window
  PASS  presenter released the window
  PASS  EditorModel deallocated after close
  PASS  editor NSWindow deallocated after close

== Summary
  ALL EXECUTED CHECKS PASSED — 1 SKIPPED (see SKIP lines above)
```

The single SKIP is the multi-frame expectation; see §4.6. The static-screen section is the
strongest evidence for A2: **one** frame, frame span `0.00 s`, and the recording still stopped
itself at the 3 s ceiling and reported a 2.98 s duration. The pre-fix code could only fire that
ceiling when a frame arrived past it, which by definition requires the frame span to exceed the
ceiling.

`file(1)` on the artefacts (independent confirmation of extension ↔ container ↔ dimensions):

```
clip.webp:       RIFF (little-endian) data, Web/P image
still-png.png:   PNG image data, 800 x 600, 8-bit/color RGB, non-interlaced
still-jpeg.jpg:  JPEG image data, JFIF standard 1.01, … baseline, precision 8, 800x600, components 3
still-webp.webp: RIFF (little-endian) data, Web/P image, VP8 encoding, 800x600, … YUV color
```

> The self-test captures a real region of the screen. Artefacts live in `build/` (git-ignored).

### 3.4 Animated WebP in a browser

Served over `python3 -m http.server` and loaded in a Chromium-based browser. Rather than sampling
pixels (the pane's tab is `visibilityState: "hidden"`, so the browser pauses animated-image
playback and pixel sampling would be a false negative), the **browser's own WebP parser** was
queried through the WebCodecs `ImageDecoder` API:

```js
const dec = new ImageDecoder({data: await (await fetch('clip.webp')).arrayBuffer(),
                              type: 'image/webp'});
await dec.tracks.ready; await dec.completed;
```

```json
{"bytes":57994,"trackCount":1,"animated":true,"frameCount":52,
 "repetitionIsInfinite":true,"width":800,"height":600,
 "firstDurations":[83,84,83,83,84,83,83,84,166,84],
 "totalDurationMs":4716,"allDurationsPositive":true}
```

`repetitionCount === Infinity` → **loops forever**; `animated: true` → the browser treats it as an
animation, i.e. it auto-plays as an `<img>`. Frame count, per-frame durations and total duration
match libwebp's demuxer *exactly*.

A four-format gallery page (`PNG / JPEG / still WebP / animated WebP`) rendered all four at
800×600 with `complete=true`, and the rendered screenshot shows the animated WebP mid-motion with
the fixed red overlay badge and "fixed overlay" text baked in.

### 3.5 No Homebrew (or any external) libwebp at runtime

```console
$ otool -L build/release/TriCap.app/Contents/MacOS/TriCap | grep -vE '^\s+(/usr/lib|/System)'
(no output)

$ nm -u build/release/TriCap.app/Contents/MacOS/TriCap | grep -i webp
(no output — nothing to import)

$ nm -m build/release/TriCap.app/Contents/MacOS/TriCap | grep -E '_WebPEncode$|_WebPAnimEncoderAdd$'
0000000100059f44 (__TEXT,__text) external _WebPEncode
000000010005afb0 (__TEXT,__text) external _WebPAnimEncoderAdd

$ ls -l /opt/homebrew/opt/webp/lib/libwebp.dylib
lrwxr-xr-x … libwebp.dylib -> libwebp.7.dylib      # present, and irrelevant
```

`scripts/build-app.sh` **fails the build** if an external libwebp ever appears in the link.
The app also reports `WebPGetEncoderVersion() == 0x010600` at runtime, asserted by the test suite.

### 3.6 Privacy / private-API audit

```console
$ grep -rnE "URLSession|NSURLConnection|CFSocket|import Network|socket\(|CFStream|WKWebView" Sources/{TriCapKit,CaptureCore,SelectionUI,AnnotationCore,ExportCore,TriCapApp}
(no matches)

$ grep -rnE "dlopen|dlsym|NSSelectorFromString|performSelector|NSClassFromString|CGSPrivate|SkyLight" Sources/{TriCapKit,CaptureCore,SelectionUI,AnnotationCore,ExportCore,TriCapApp}
(no matches)

$ grep -c "\.package(" Package.swift
0
```

Imports across all TriCap sources: `AppKit, Carbon.HIToolbox, CoreGraphics, CoreMedia, CoreText,
CoreVideo, Darwin, Foundation, ImageIO, ScreenCaptureKit, SwiftUI, UniformTypeIdentifiers, os` —
all public — plus the in-repo modules and `CWebP`.

### 3.7 UI screenshots

```bash
.build/release/TriCap --render-ui-snapshots ./build/ui-snapshots
```

Nineteen PNGs in `build/ui-snapshots/`, all inspected individually:

| File | Shows |
|---|---|
| `01-settings-general.png` | **Round 5, changed.** Settings → General, now 700 pt tall so nothing is cut off: **Screenshot shortcut** `⌥⇧5` (with "Click a window … hold ⌥ while dragging to ignore edge snapping"), **Pin shortcut** `F3` (naming the Mission Control conflict), **After a screenshot → Copy to clipboard**, countdown `3 s`, permission row `Granted` |
| `02-editor-still.png` | Still editor: 5 tool buttons with the active one highlighted **and named** ("Arrow"), 6-colour palette, stroke slider, undo/redo/clear, composited annotations, `940 × 620 px`, Format PNG **· Lossless**, `Saves to ~/Pictures/TriCap`, Close/Save |
| `03-editor-clip-trim.png` | Clip editor: mosaic tool selected with its block-size slider, `8 of 12 frames · 0.7 s`, Reset trim, Start=2 / End=9 / Frame=5 sliders, `640 × 400 px  Animated WebP` |
| `04-selection-overlay.png` | Selection overlay in recording mode: persistent banner "● Record a clip · **Click a window or drag** · S screenshot · Esc cancel", punched-out selection with red corner brackets, `940 × 520 px` badge, "Release to start recording" |
| `05-recording-hud.png` | Recording HUD, rendered by `RecordingHUD.populateHUD` itself: `4.2 s / 15 s`, `51 frames · 12 MB`, progress bar toward the limit, **`Esc cancels · Click Stop to finish`** (round 4 — it used to promise a Return key that could not work), Stop button in dark appearance |
| `06-menu-bar-item.png` | Status-item template icon at menu-bar size — **still monochrome**; the new full-colour app icon is bundle-only, exactly as specified |
| `07-editor-single-frame-clip.png` | **Round 2 (B10).** A one-frame clip: `1 of 1 frames · 0.1 s`, *Reset trim* disabled, "Single frame — nothing to trim.", and **no** Start/End/Frame sliders |
| `08-settings-quality.png` | **Round 3.** Quality tab, Advanced expanded: preset *Balanced* with its summary, format PNG with "Lossless — every pixel is preserved exactly", **PNG quality → "Lossless — no setting"** (no stepper), the four recording parameters, and the size-guidance footer |
| `09-welcome.png` | **Round 5, changed.** Getting Started: "TriCap is running", *Ask macOS now*, and **four** steps — the old "drag out a region … annotate, then save" was untrue once screenshots stopped opening the editor, so step 2 now says click a window or drag, step 3 is "Paste it" (pointing at *Screenshot and Edit…* for annotation), step 4 is "Press F3 to pin" |
| `10-export-toast.png` | Post-export confirmation: file name, **`1440 × 900 · Animated WebP · 52 frames · 4.7 s`** (round 4 — this line was missing), `~/Documents/Vault/assets · 1.4 MB`, "Copied the Markdown reference", **Show in Finder** |
| `11-selection-overlay-screenshot.png` | **Round 3.** Screenshot mode: blue banner "● Take a screenshot · Click a window or drag · R record · Esc cancel", corner brackets, "Release to capture" |
| `12-recording-countdown.png` | Countdown, now drawn by `RecordingHUD.populateCountdown` itself: `3`, "Recording starts…", "Esc to cancel" — and Escape now genuinely works from other apps |
| `13-export-toast-warning.png` | **Round 4.** The same toast carrying a wrapping warning, proving the panel grows instead of clipping |
| `15-hud-placement-near-fullscreen.png` | **Round 7, new.** A 94%-tall selection drawn 1:1 against its display: red strips are outside the visible frame (menu bar and Dock), blue is the selection, and the real HUD sits where `HUDPlacement` put it (`strategy: insideTop`) — clear of both strips. The case that used to land 119 pt off the top |
| `16-banner-over-window-highlight.png` | **Round 8, new.** A full-screen window highlight — the `.copy` fill that used to erase the banner. The banner is intact on top |
| `17-banner-over-selection.png` | **Round 8, new.** A recording-mode selection dragged through the banner: the punch-out and red border are visible *behind* the intact banner |
| `18-mosaic-before-after.png` | **Round 8, new.** Original vs pixelated on report-shaped content (dark rows on a light page, bright band at the mirrored position). The blocks derive from the dark rows — not white, not orange |
| `19-settings-login-approval.png` | **Round 8, new.** The login toggle in `requiresApproval`: on, orange explanation, "Open Login Items Settings…" entry point |
| `14-selection-window-highlight.png` | **Round 5, new.** The pre-drag state: a window under the pointer outlined and tinted, with a `1120 × 640 px · click to capture` badge — the real `SelectionOverlayView.drawWindowHighlight` |

**These are offscreen renders of the real view hierarchies** (`NSHostingView` / `SelectionOverlayView`
in off-screen windows, captured via `CALayer.render(in:)`), not desktop captures — see §4.1 for why,
and §4.2 for what that does not cover.

### 3.8 App icon

The icon is generated, not drawn by hand in a binary file:

```bash
swift scripts/generate-icon.swift Resources/AppIcon
iconutil -c icns Resources/AppIcon/TriCap.iconset -o Resources/AppIcon/TriCap.icns
```

Verified:

| Check | Command | Result |
|---|---|---|
| The `.icns` round-trips back to a complete iconset | `iconutil -c iconset Resources/AppIcon/TriCap.icns` | all 10 entries — `16`, `16@2x`, `32`, `32@2x`, `128`, `128@2x`, `256`, `256@2x`, `512`, `512@2x` |
| Every entry is the size its name claims | `sips -g pixelWidth -g pixelHeight` per file | 16/32 · 32/64 · 128/256 · 256/512 · 512/1024 — all square, all exact |
| Master is 1024 × 1024 | `sips` on `TriCap-1024.png` | `1024 × 1024` |
| Contact sheets exist for both backgrounds | `icon-check-light.png`, `icon-check-dark.png` | `2192 × 1088`, each tile at **true pixel size** (16/32/128/256/512/1024), bottom-aligned |
| `Info.plist` is valid and names the icon | `plutil -lint`, `plutil -extract CFBundleIconFile raw` | `OK`, `TriCap` |
| The icon is inside the bundle **before** signing | `ls build/release/TriCap.app/Contents/Resources` | `TriCap.icns` present; `build-app.sh` fails outright if the source `.icns` is missing |
| The signature covers it | `codesign --verify --deep --strict --verbose=2` | `valid on disk`, `satisfies its Designated Requirement` |
| The system really resolves the bundle to this icon | `NSWorkspace.icon(forFile:)` on the built app, sampling pixels | `1024 × 1024`; centre pixel coral `rgb(255, 119, 101)`, lower body azure `rgb(41, 146, 233)` — this is what Finder and Get Info draw |
| The menu bar did **not** change | snapshot `06-menu-bar-item.png` | still the monochrome template glyph |

Both contact sheets were opened and looked at, not just generated. At 512 px and above the mark is
plainly a viewfinder with a coral shutter dot; at 128 and 256 it is still unambiguous; at 32 it
reads correctly; at **16 px** the blue rounded-square silhouette, the four brackets and the red dot
are all still distinguishable, but this is the honest limit of a four-bracket mark — the brackets
are two pixels of stroke and the dot is three pixels across. That is why the generator thickens the
stroke and enlarges the dot below 32 px, and why pushing the brackets further outward was rejected:
past ~0.18 inset they crowd the rounded corner and read as a broken second outline.

---

## 4. Not verified — please treat as open

### 4.1 Why no live desktop screenshots

Screen-automation access was requested and **declined by the user**, and the sandboxed shell has
no Screen Recording permission (`screencapture` → `could not create image from rect`). The UI
evidence in §3.7 is therefore offscreen rendering of the real views. Consequences:

- **The menu-bar dropdown itself was never rendered.** Only the window server can draw an `NSMenu`.
  Its items are, from `AppDelegate.buildMenu()`: *Capture Region…*, *Record Region…*, separator,
  *Shortcut: ⌥⇧5* (disabled), *Open Save Folder*, separator, *Settings…* (`⌘,`), *Quit TriCap* (`⌘Q`).
- **The Settings `TabView` tab strip does not appear** in `01-settings-general.png` — a known
  limitation of `CALayer.render(in:)` with `TabView`, not a layout bug. Only the General tab's
  content is shown; Recording / Output / About were not visually captured.
- Live hover, focus rings, cursor shape (crosshair) and window shadows are not represented.

### 4.2 Interactive paths never exercised end-to-end

Everything downstream of "the user dragged a rectangle" is covered by `--selftest`. These are not:

| Path | Why | Manual steps to verify |
|---|---|---|
| Global hot key actually firing | Needs a real key press | Launch the app, press `⌥⇧5`, expect the overlay |
| Drag-to-select, `R`/`S` mode toggle, `Esc` cancel, right-click cancel | Needs mouse/keyboard | Do each in the overlay; `Esc` should restore focus to the previously frontmost app |
| Countdown UI and its `Esc` cancel | Needs a real recording session | Set countdown ≥ 3 s, start a recording, press `Esc` during it |
| Stop button click | Needs a click | Record, click **Stop** |
| Editor mouse interaction: drawing each tool, the inline text field, `⌘Z`/`⇧⌘Z`, trim sliders | Needs mouse | Draw with each tool; undo/redo; drag the trim handles |
| Settings hot-key recorder | Needs key presses | Settings → General → click the shortcut button, press a new combination, confirm the menu label updates |
| Multi-display selection | **Only one display attached** | Attach a second display (ideally a non-Retina one, and offset vertically so the AppKit and Quartz origins differ), then drag a selection spanning both — expect it to resolve to the display with the larger overlap and to be clipped to that display |

### 4.3 Permission prompt

The self-test reports the live state (`authorized`) but **the first-run TCC prompt and the denial
path were never exercised on this machine** — the binary already inherited permission, and
flipping the switch requires the user's authentication in System Settings, which was not available.

The code paths are unit-tested (`Screen recording permission state`, 5 cases) and the tri-state
logic and its failure mode are documented in `ScreenRecordingPermission.swift`. To verify manually:

1. Remove TriCap from *System Settings → Privacy & Security → Screen & System Audio Recording*.
2. Delete the "has asked" flag: `defaults delete app.tricap.TriCap app.tricap.hasRequestedScreenRecording`
   (or `defaults delete <the host bundle id>` when running the CLI binary).
3. Launch and capture → expect the explanatory alert, then the macOS prompt.
4. Decline → expect *"Screen Recording permission is off"* with an **Open System Settings** button
   and copy stating macOS will not ask again.
5. Grant in System Settings, relaunch, capture → expect success.

Note the **ad-hoc signing caveat**: each rebuild changes the code-directory hash, so macOS treats
it as a new app and re-asks. Set `CODESIGN_IDENTITY` to a stable identity to avoid churn.

### 4.4 Obsidian

**Obsidian is not installed on this machine** (it does not appear in the system application list),
and the screen automation needed to drive it was declined. Markdown embedding was verified only as
far as: the reference string is produced correctly (13 unit tests + self-test), and the referenced
files render in a browser (§3.4). To close the gap:

1. Set *Settings → Output → Vault root* to your Obsidian vault, and *Save to* to a folder inside
   it (e.g. `<vault>/assets`).
2. Capture something, save it — the clipboard should hold `![name](assets/name.webp)`.
3. Paste into a note in that vault. Expect the image to render in Reading view, and the animated
   WebP to play and loop.
4. Repeat with *Reference style = Obsidian wiki-link* — expect `![[assets/name.webp]]`.
5. Negative case: set *Save to* outside the vault; the clipboard should hold a plain absolute path
   with no Markdown syntax, and pasting it should **not** produce an embed.

### 4.6 Round-2-specific gaps

**The display was not compositing live for most of round 2's verification.** This machine's screen
slept during the run; ScreenCaptureKit then either reported **0 displays** or kept serving a
*frozen* composite. This was isolated to the environment, not to TriCap, with a standalone probe
that uses **no TriCap code**: it creates its own window, confirms ScreenCaptureKit lists it with
`isOnScreen=true` at `frame=(120, 760, 200, 200)`, then takes three full-display captures with the
window moved and recoloured between each — and all three are byte-identical
([scripts/diagnostics/display-compositing-probe.swift](scripts/diagnostics/display-compositing-probe.swift), reproduced in §6).

Consequences, all reported rather than papered over:

- `--selftest` now probes for live compositing (two stills either side of a deliberate on-screen
  change) and emits **SKIP**, never PASS, for the multi-frame recording expectation when the
  screen is frozen. The summary line distinguishes "ALL CHECKS PASSED" from "ALL EXECUTED CHECKS
  PASSED — N SKIPPED".
- It also detects the 0-display case up front and tells the reviewer to re-run under
  `caffeinate -dimsu` instead of failing later with a confusing `noDisplaysAvailable`.
- **A live multi-frame animated-WebP recording was therefore not re-verified in this round.** It
  *was* verified in the previous round on the same code path (60 captured frames → 52 stored
  frames → browser-confirmed `animated: true`, `repetitionCount === Infinity`, 4716 ms), and the
  encoding itself is covered by 21 unit tests. Re-running `caffeinate -dimsu .build/release/TriCap
  --selftest ./build/selftest` with the display awake and the machine in use should turn the SKIP
  into a PASS; please do that as part of the review.

**Interactive paths for the round-2 fixes were not exercised by hand** (same reason as §4.2 —
screen automation was declined). Specifically not manually verified:

| Fix | What a human should do |
|---|---|
| A1 | Start a recording, then press `⌥⇧5` again and click *Record Region…* — nothing should happen until the first recording ends. Log line `capture request refused: session already in recording`. |
| A5 | Start a recording, click into another application, press `Esc` — the recording should abandon. Also confirm `Esc` works normally again immediately afterwards. |
| B6 | In Settings, assign a shortcut another app already owns — TriCap should keep the old one and say which. (Finding a genuinely-taken combination is the hard part; the roll-back logic itself is unit-tested.) |
| B9 | Look at the HUD on a real screen in both light and dark system appearance. |

**B8's real trigger was not reproduced.** There is no exFAT or SMB volume on this machine, so
`link(2)` never actually failed. The fallbacks are covered by forcing each strategy individually
(11 tests), and the errno-to-fallback mapping (`EPERM`, `ENOTSUP`, `EXDEV`, `EMLINK`, `EINVAL`) is
from the documented behaviour of those filesystems, not from observation here.

**B7's case-sensitive branch was not exercised on a real case-sensitive volume.** The boot volume
reports case-*insensitive*. The comparison rule is tested directly as a pure function over path
components, and `volumeCaseSensitivity(for:)` is tested to agree with whatever this volume reports.
A case-sensitive APFS volume would exercise the other branch end to end.

### 4.10 Round-7-specific gaps

| Change | Not verified | How to check by hand |
|---|---|---|
| HUD placement | That the Stop button is *clickable* on a real near-full-screen recording. The placement is asserted against real `NSScreen.visibleFrame` for both displays, and the button is hit-tested in the view hierarchy — but nobody moved a mouse to it. | Record a full-screen region and click Stop |
| Stop-once | Asserted by firing `HUDStopProxy` three times, which is the action a click sends — not by double-clicking a real button. | Start a recording, double-click Stop fast |
| Export performance | **The material is synthetic.** No number here comes from a real screen recording. The generator produces worst-case entropy (every frame fully different), so real content should do no worse — but "no worse" is an argument, not a measurement. Arm A run 3 was 238.6 s against a 163.1 s minimum, so there is real variance in the slow arm; the median is reported. | Record 15 s of video playback and time the export before/after |
| In-recording cost | Measured as lateness in a *simulated* recording loop, not as ScreenCaptureKit frame drops. The real recorder also PNG-encodes on that path, which the simulation reproduces, but SCK's own queueing behaviour is not modelled. | Record high-motion content and compare `droppedFrameCount` |
| `.balanced` size trade | +2.7% on this synthetic material at quality 80. Different content and quality settings will differ, and only this one point was measured. | `--benchmark-export` at other qualities |
| Pre-encoding under memory pressure | The backlog ceiling is tested by forcing it, but not by running a real recording on a machine that is genuinely starved. | — |
| Live pre-encoding end to end | The pre-encoder is wired into `recordClip` and the artifact threaded to the editor, but **no real recording was made through the app in this session** — the selftest drives `LivePreEncoder` and `ExportService` directly. Whether `RegionRecorder.onFrameAccepted` fires as expected under real ScreenCaptureKit delivery is unverified. | Record a clip, export without trimming, confirm it is fast; then trim and confirm it is still correct |

### 4.9 Round-5-specific gaps

**No interactive verification happened in this session.** Screen automation is declined here, so
nobody pressed `⌥⇧5`, nobody pressed `F3`, nobody dragged a pin, and nobody pasted a screenshot
into another application. Everything below is either unit-tested logic or a runtime assertion made
by `--selftest` in a real `NSApplication` — which is *not* the same as a person using it, and is
listed as unverified rather than dressed up as a pass.

What **was** exercised at runtime (in `--selftest`, in-process, real AppKit and real Carbon):

- `⌥⇧5` and `F3` registering simultaneously in separate slots, and this machine took the
  **success** branch — F3 was claimable here. The Mission Control conflict branch therefore did
  *not* execute; only its code path and message are reviewed, not observed.
- Carbon refusing a duplicate registration of the same combination (asserted, not assumed).
- Releasing the pin shortcut leaving `⌥⇧5` registered.
- Real `PinWindow`s created from a real `NSPasteboard`: empty clipboard → no window, text-only →
  no window, PNG → a window, a third pin refused by the count ceiling.
- Those windows' actual `level` (3 — above `.normal`, below `.screenSaver`), their
  `collectionBehavior` (`canJoinAllSpaces` + `fullScreenAuxiliary`), and that none of them ever
  became the key window.
- `closeAll()` releasing the bitmap and the content view, being idempotent, and leaving no visible
  pin behind.

What is **not** verified:

| Change | Not verified | How to check by hand |
|---|---|---|
| `F3` pinning | That pressing `F3` while another app is frontmost creates a pin. Registration succeeds and the handler is wired, but no key was pressed. | Copy an image, focus Safari, press `F3` |
| Mission Control conflict | The failure branch never ran here, because `F3` was free on this machine. The message and the re-bind path are unreviewed by execution. | Re-enable "Mission Control → F3" in Keyboard settings, relaunch TriCap, look for the error and rebind |
| Focus is not stolen | The self-test asserts `canBecomeKey == false` and that no pin became key — but nothing typed into another app while a pin appeared. | Start typing in a text editor, press `F3` mid-sentence, confirm the characters still land |
| Cross-Space / full-screen | `collectionBehavior` is asserted; the actual behaviour when switching Spaces or entering a full-screen app was not observed. | Pin an image, swipe to another Space, enter a full-screen app |
| Pin interaction | Drag, scroll/pinch zoom, opacity, the context menu and `Esc`-to-close are unit-tested as geometry (`PinZoom`, `PinOpacity`, `PinPlacement`) and wired to real event handlers, but no pointer moved. *(Round 6: the self-test now calls `pinDidInteract` on a real pin and checks the resulting order — but that is the delegate call, not an actual mouse-down. Whether `PinContentView` receives events on a non-activating panel is still unverified here.)* | Pin two images, click the older one, press `Esc`, confirm the one you clicked closed |
| Multi-pin at scale | Two pins were created; the shipped ceiling of 12 pins / 120 MP was tested only through `PinLimits` arithmetic, not by opening twelve real windows. | Pin a dozen large screenshots and watch memory |
| Window-aware selection | The picking, gesture and snapping rules are pure functions, and `WindowSurvey` converts real `SCWindow` frames — but no one hovered a window and clicked it. *(Updated in round 6: two displays are now attached, and the level filter and snap-edge construction were exercised against the real 38-window list on both — but both displays are scale 2.0, so **mixed** scale factors remain untested.)* | Hover several overlapping windows, click one; repeat with displays at different scale factors |
| Clipboard-first screenshots | That the captured image actually pastes into another app. `PasteboardImage.write` is tested and reports a receipt, and the round-trip through PNG is tested — but nothing was pasted anywhere. | Press `⌥⇧5`, capture, then `⌘V` into Preview, Mail and Slack |
| Clipboard failure recovery | `presentClipboardFailure` was never triggered; making `NSPasteboard` refuse a write on demand is not something this harness can force. | — (code review only) |
| Copy confirmation on a wide-gamut display | `ClipboardCopyNotice` is unit-tested for all four combinations, but the toast was not seen on screen after a real P3 capture. Both attached displays report the same colour characteristics, so the advisory branch may not even arise here. | Capture on a P3 display and read the toast — it must say `Copied W × H` first |
| Icon in Finder | `NSWorkspace.icon(forFile:)` returns TriCap's icon (§3.8), which is what Finder draws — but no one opened a Finder window or a Get Info panel and looked. | `open -R build/release/TriCap.app`, then `⌘I` |

### 4.8 Round-4-specific gaps

Screen automation is still declined, so the round-4 changes are evidenced by offscreen renders and
by unit tests over the extracted logic — not by watching them happen.

| Change | Not verified | How to check by hand |
|---|---|---|
| Countdown Escape (#3) | That pressing Escape **while another app is frontmost, during the countdown**, actually aborts. The claim/rebind/release lifecycle is unit-tested and the real Carbon hand-off is exercised in `--selftest`, but nobody pressed the key with Safari in front. | Set a 5 s countdown, start a recording, click into another app, press Escape |
| Hot-key re-registration (#1) | That the *end-to-end* path re-registers. The notification now carries the real before/after (tested), and `AppDelegate` already re-registers on a hot-key change, but the two were not exercised together against Carbon. | With legacy settings in place, change only the shortcut in Settings, then press the new combination |
| Toast detail line (#4) | That the panel's computed height is right on a real screen at a different text size or scale factor. | Save a capture, and one that produces the "nothing moved" warning |
| HUD wording (#2) | Nothing outstanding — the change is a label and the removal of a `keyEquivalent` that could not fire. Worth confirming Return does nothing surprising. | Start a recording, press Return |

**The preset numbers remain a judgement call.** Round 4 corrected the *name and description* of the
top preset to match its values; it deliberately did **not** raise those values to the encoder
ceilings (30 fps, quality 100), because that multiplies what a recording holds in memory for a
difference few people would see. If a reviewer wants different numbers, that is a one-line change
in `QualityPreset.values` — and `topPresetCopyIsAccurate` will fail until the summary is updated to
match, which is the point.

### 4.7 Round-3-specific gaps

Screen automation is still declined, so every round-3 UI change is evidenced by an **offscreen
render of the real view** (§3.7), not by a desktop screenshot. What that leaves unverified:

| Change | Not verified | How to check by hand |
|---|---|---|
| First-run welcome | That the window actually *appears* on a real first launch. The flag flips (`app.tricap.hasSeenWelcome` went from absent to `1` on launch, so `showWelcome()` ran) and the view renders offscreen — but nobody watched it open. The flag was reset afterwards so the next launch still shows it. | `defaults delete app.tricap.TriCap app.tricap.hasSeenWelcome`, then relaunch |
| Menu-bar states | The dropdown itself is never rendered — only the window server can draw an `NSMenu`. Permission rows, *Capture in progress…*, and *Getting Started…* are unverified visually. | Deny permission and open the menu; start a recording and open the menu |
| Export toast | That the panel positions correctly under the menu bar, auto-dismisses after 6 s, and that **Show in Finder** reveals the file | Save a capture and watch the top-right corner |
| Tool shortcuts | That `⌘1`–`⌘5` actually switch tools in a focused editor window | Open the editor and press them |
| Overlay banner | That the banner stays legible over real desktop content on a Retina display, and that it does not obscure content at the top of the screen | Press `⌥⇧5` and drag near the top edge |
| Quality presets end to end | That picking a preset visibly changes a *real* capture's file size. The mapping to encoder arguments is asserted, and the encoders' response to quality is asserted, but the two were not chained through a live capture. | Save the same region at *Smaller file* and at *Up to 4K*, compare sizes |
| Countdown panel | That it appears centred on the selection and that `Esc` cancels during it | Set a 3 s countdown and start a recording |

**The preset numbers are a judgement call.** They were chosen to span TriCap's existing ranges
sensibly (960/1440/1920/3840 px, 10/12/15/20 fps) and are monotonic on every axis, which the tests
assert — but they are not calibrated against measured file sizes for typical screen content. If a
reviewer thinks *Balanced* should be 1080 px rather than 1440 px, that is a product decision, not
a defect, and it is a one-line change in `QualityPreset.values`.

**Existing users all land on Custom.** That is deliberate (see §0), but it means nobody upgrading
sees a preset selected until they pick one. The alternative — snapping their values to the nearest
preset — would change their output quality without asking.

### 4.5 Other gaps

- **HDR / wide-gamut capture** — the machine's display reports sRGB, so source-profile capture and
  the editor notice have not fired in a live capture. Unit tests cover Display P3 preservation,
  explicit sRGB conversion and the case where an EDR display delivers an sRGB-tagged buffer.
  Verify the live notice and appearance on a P3/HDR display.
- **Intel (x86_64)** — never built or run. libwebp's SSE4.1/AVX2 kernels are compiled out (see
  [docs/LIBWEBP.md](docs/LIBWEBP.md) § SIMD); correct but slower. Universal-binary packaging is not
  set up.
- **macOS 14/15** — the deployment target is 14.0 but only macOS 26.5.2 was available. Nothing
  newer than the 14.0 SDK surface is used knowingly, but this is untested.
- **Disk-full** — `NSFileWriteOutOfSpaceError` is mapped to friendly copy; injected tests exercise
  delayed `fsync(ENOSPC)` and `close(EIO)` cleanup, but a physically full volume was not used.
- **Long recordings at the ceiling** — the 15 s / 181-frame / 512 MB limits are unit-tested at the
  `FrameBuffer` level and a 5 s live recording was measured, but a full 15 s live recording that
  actually trips `durationLimit` was not run.

---

## 5. Known risks / suggested review focus

### 5.1 Highest value first

1. **`Sources/TriCapKit/Coordinates.swift` + `CaptureRegion.swift`.** The whole product's
   correctness rests here. Please check the AppKit↔Quartz flip for a display whose Quartz origin
   is negative (the `external` fixture in `CaptureRegionTests` models a monitor whose AppKit and
   Quartz origins disagree), and whether outward snapping plus clamping can ever produce a rect
   `SCStreamConfiguration.sourceRect` rejects.
2. **`Sources/ExportCore/WebPCodec.swift`.** Manual C memory management across error paths. Every
   `WebPPicture` should be freed exactly once; `WebPMemoryWriter` is cleared via `defer` and the
   encode happens inside `withUnsafeMutablePointer` so the pointer cannot escape. Worth a second
   pair of eyes — in particular the `data.withUnsafeBytes` closures in `inspectAnimation` /
   `decodeAnimationFrames`, where `WebPData.bytes` borrows the buffer.
3. **`Sources/CaptureCore/RegionRecorder.swift`.** `StreamOutput` runs off the main actor and is
   `@unchecked Sendable` with a manual `NSLock`. Check the latch logic (`stopped`, `baseTimestamp`,
   `_observedColorSpace`) for races, and whether `teardown()` can be entered twice.
4. **`ExportService` verification.** It deletes the file when verification fails. Confirm that is
   right and that no legitimate output can trip it (the frame-coalescing and motionless-recording
   cases were the two that did, and both are now handled — see D8/D9).

### 5.1b Round-2 code worth a close look

1. **`RecordingSession.waitForStop()`** — a `CheckedContinuation` resumed from `request(_:)`.
   Please check the pre-latch path (a stop arriving while `backend.start()` is still running) and
   that `waiter` can never be resumed twice.
2. **`RegionRecorder.tick()` / `handleAutoStop`** — the ceiling now latches and invalidates its own
   timer. Confirm there is no path where `hasAutoStopped` is set but the recording keeps retaining
   frames, and that the shared commit gate plus post-`stopCapture` sample-queue drain cannot deadlock
   or allow a callback to append after `finish()` / `cancel()`.
3. **`ClipTrimmer.trimmedDuration`** — the two-case rule is the whole of A2's semantics. Worth
   checking the boundary where `range.upperBound == frames.count - 1` and `clipDuration` is
   *smaller* than the last frame's timestamp (it clamps to 0; `ClipTiming` then floors to
   `lastTimestamp + nominalInterval`).
4. **`OutputFileWriter.write`'s nested loop** — a strategy reporting `unsupported` retries the next
   strategy for the same candidate name, but the outer loop restarts from the strongest strategy on
   the next name. Correct but mildly wasteful on a volume without hard links; worth confirming the
   `taken` / `break` / `continue` flow has no path that silently gives up.
5. **`EditorPresenter.release(_:)`** sets `contentViewController = nil`. Confirm that is safe for a
   window that is already closing, and that `windowWillClose` cannot re-enter it.

### 5.2 Known weak spots

- **`FrameConverter` cropping.** SCK's `contentRect`/`scaleFactor` attachments are used to crop an
  over-sized IOSurface. On this machine the delivered buffer already matched the requested size, so
  the crop branch was never taken in a live run. It is reachable on other configurations.
- **`AnnotationRenderer.drawMosaic` calls `ctx.makeImage()` per mosaic item.** With many mosaics on
  a large clip this is O(items × frames) full-canvas snapshots. Fine for the MVP; a real cost at
  scale.
- **`HotKeyCombo.keyName` is a fixed ANSI table.** Non-ANSI layouts will show a wrong *label*; the
  key code registered is still correct. `UCKeyTranslate` would fix the label.
- **`SettingsStore` persists on every `didSet`.** Dragging a slider writes `UserDefaults` per tick.
- **Editor windows are retained in a dictionary keyed by `ObjectIdentifier`** and removed in
  `windowWillClose`. Worth confirming there is no retain cycle through `EditorModel`'s closures
  (`onClosed` captures the window via a local `var`).
- **Hot-key re-registration** happens the moment `SettingsStore.settings` changes
  (`store.onChange` → `registerHotKey(previous:)`); the redundant post-capture
  `syncHotKeyRegistration()` was removed. `isRollingBackHotKey` guards the one re-entrant path
  (a roll-back writes the setting, which fires `onChange` again).
- **A bare Escape is claimed system-wide while a recording runs.** For at most
  `RecordingLimits.maxDuration` seconds, `Esc` does not reach the focused application. This is
  deliberate and is released on every exit path (`RecordingChromeController.dismiss()`, which
  `RecordingSession` always calls), but it is the one behaviour in TriCap that affects other apps.

### 5.3 Things intentionally simple

- Annotations cannot be selected or moved after being drawn — only undone. The brief did not ask
  for editing, and hit-testing plus handles is a large surface.
- No preview of the animation inside the editor; the Frame slider scrubs instead.
- Settings are stored as one JSON blob in `UserDefaults` with a tolerant decoder rather than
  individual keys.

---

## 6. Reproducing everything

```bash
# 1. clean build, both configurations
rm -rf .build build
swift build && swift build -c release

# 2. tests
./scripts/test.sh

# 3. regenerate the app icon (optional — the outputs are committed; this proves they are the
#    product of the script and not a binary asset)
swift scripts/generate-icon.swift Resources/AppIcon
iconutil -c icns Resources/AppIcon/TriCap.iconset -o Resources/AppIcon/TriCap.icns

# 4. app bundle + the "no external libwebp" gate + the icon copied in before codesign
./scripts/build-app.sh release

# 5. end-to-end capture pipeline (captures a real screen region, and creates real pin windows).
#    `caffeinate -dimsu` keeps the display awake — without it this machine's screen sleeps
#    mid-run and ScreenCaptureKit serves a frozen composite (see §4.6).
caffeinate -dimsu .build/release/TriCap --selftest ./build/selftest

# 6. UI snapshots
.build/release/TriCap --render-ui-snapshots ./build/ui-snapshots

# 6b. export performance (slow: arm A alone is ~3 minutes per run)
caffeinate -dimsu .build/release/TriCap --benchmark-export ./build/benchmark \
  --frames 181 --runs 3 --width 1440 --height 900

# 7. re-vendor libwebp from upstream (verifies the pinned SHA-256)
./scripts/vendor-libwebp.sh 1.6.0   # should produce no diff

# 8. run it
open build/release/TriCap.app
```

Steps 5 and 6 need Screen & System Audio Recording permission for the binary being run.

To reproduce the HUD placement finding from §0.000 against the previous algorithm, with no TriCap
code involved:

```bash
swift scripts/diagnostics/hud-placement-probe.swift
```

To reproduce the "AppKit outlives `close()`" finding from §0.0 independently of TriCap — a plain
`NSPanel`, a plain `NSView`, no TriCap types anywhere in the file:

```bash
swift scripts/diagnostics/panel-lifetime-probe.swift
```

To reproduce the "display is not compositing live" finding from §4.6 independently of TriCap:

```bash
# Creates its own window, confirms SCK lists it as on-screen, then captures the full display
# three times with the window moved and recoloured between each.
swiftc -O scripts/diagnostics/display-compositing-probe.swift -o /tmp/probe
caffeinate -dimsu /tmp/probe
```

**Housekeeping note.** A copy of the bundle was briefly placed in `/Applications` and
`~/Applications` while trying to get screen automation to see it; both were removed once that
approach was declined. Nothing outside this repository is left behind except the
`app.tricap.ui-snapshots` `UserDefaults` suite used (and wiped on each run) by the snapshot
renderer.
