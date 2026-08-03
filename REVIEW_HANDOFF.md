# TriCap — review handoff

Prepared for independent review by Codex. Nothing has been pushed, released, signed or notarized.
The working tree is left exactly as verified below.

**Environment:** macOS 26.5.2 (25F84), Apple silicon, Swift 6.3.3, Command Line Tools 26.5,
**no `Xcode.app` installed**. One display attached (1920×1080 pt @ 2.0 → 3840×2160 px).

> **Round 3.** Round-2 commit `f521ac6` was re-reviewed and four remaining Important issues were
> repaired in the current working tree: colour provenance, sample-queue draining, delayed I/O
> errors, and unknown-volume case sensitivity. See the updated A3/B7/B8 rows below.
>
> **Round 2.** Baseline `83a8c12`. See
> [§0](#0-review-round-2--what-changed) for the issue → file → test mapping and
> [§4.6](#46-round-2-specific-gaps) for what round 2 could *not* verify on this machine.

---

## 0. Round 3 — usability and quality

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
| P1 | The recording HUD had no cancel affordance and no sense of the limit | ✅ | progress bar + `Esc cancels · Return stops` |
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
| Maximum | 100 | 3840 | 20 | 95 |

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

## 0.1 Review round 2 — what changed

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

Six PNGs in `build/ui-snapshots/`, all inspected:

| File | Shows |
|---|---|
| `01-settings-general.png` | Settings → General: shortcut recorder reading `⌥⇧5`, explanatory text, permission row (`Granted` + "Open System Settings") |
| `02-editor-still.png` | Still editor: 5 tool buttons with the active one highlighted **and named** ("Arrow"), 6-colour palette, stroke slider, undo/redo/clear, composited annotations, `940 × 620 px`, Format PNG **· Lossless**, `Saves to ~/Pictures/TriCap`, Close/Save |
| `03-editor-clip-trim.png` | Clip editor: mosaic tool selected with its block-size slider, `8 of 12 frames · 0.7 s`, Reset trim, Start=2 / End=9 / Frame=5 sliders, `640 × 400 px  Animated WebP` |
| `04-selection-overlay.png` | Selection overlay in recording mode: persistent banner "● Record a clip   S screenshot   Esc cancel", punched-out selection with red corner brackets, `940 × 520 px` badge, "Release to start recording" |
| `05-recording-hud.png` | Recording HUD, now rendered by `RecordingHUD.populateHUD` itself rather than a hand-built copy: `4.2 s / 15 s`, `51 frames · 12 MB`, progress bar toward the limit, **`Esc cancels · Return stops`**, Stop button in dark appearance |
| `06-menu-bar-item.png` | Status-item template icon at menu-bar size |
| `07-editor-single-frame-clip.png` | **Round 2 (B10).** A one-frame clip: `1 of 1 frames · 0.1 s`, *Reset trim* disabled, "Single frame — nothing to trim.", and **no** Start/End/Frame sliders |
| `08-settings-quality.png` | **Round 3.** Quality tab, Advanced expanded: preset *Balanced* with its summary, format PNG with "Lossless — every pixel is preserved exactly", **PNG quality → "Lossless — no setting"** (no stepper), the four recording parameters, and the size-guidance footer |
| `09-welcome.png` | **Round 3.** Getting Started: "TriCap is running", the three numbered steps, *Ask macOS now* for the not-determined permission state |
| `10-export-toast.png` | **Round 3.** Post-export confirmation: file name, `~/Documents/Vault/assets · 1.4 MB`, "Copied the Markdown reference", **Show in Finder** |
| `11-selection-overlay-screenshot.png` | **Round 3.** Screenshot mode: blue banner "● Take a screenshot   R record   Esc cancel", corner brackets, "Release to capture" |
| `12-recording-countdown.png` | **Round 3.** Countdown: `3`, "Recording starts…", "Esc to cancel" |

**These are offscreen renders of the real view hierarchies** (`NSHostingView` / `SelectionOverlayView`
in off-screen windows, captured via `CALayer.render(in:)`), not desktop captures — see §4.1 for why,
and §4.2 for what that does not cover.

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
| Quality presets end to end | That picking a preset visibly changes a *real* capture's file size. The mapping to encoder arguments is asserted, and the encoders' response to quality is asserted, but the two were not chained through a live capture. | Save the same region at *Smaller file* and at *Maximum*, compare sizes |
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

# 3. app bundle + the "no external libwebp" gate
./scripts/build-app.sh release

# 4. end-to-end capture pipeline (captures a real screen region).
#    `caffeinate -dimsu` keeps the display awake — without it this machine's screen sleeps
#    mid-run and ScreenCaptureKit serves a frozen composite (see §4.6).
caffeinate -dimsu .build/release/TriCap --selftest ./build/selftest

# 5. UI snapshots
.build/release/TriCap --render-ui-snapshots ./build/ui-snapshots

# 6. re-vendor libwebp from upstream (verifies the pinned SHA-256)
./scripts/vendor-libwebp.sh 1.6.0   # should produce no diff

# 7. run it
open build/release/TriCap.app
```

Steps 4 and 5 need Screen & System Audio Recording permission for the binary being run.

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
