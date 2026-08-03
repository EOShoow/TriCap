# TriCap — review handoff

Prepared for independent review by Codex. Nothing has been pushed, released, signed or notarized.
The working tree is left exactly as verified below.

**Environment:** macOS 26.5.2 (25F84), Apple silicon, Swift 6.3.3, Command Line Tools 26.5,
**no `Xcode.app` installed**. One display attached (1920×1080 pt @ 2.0 → 3840×2160 px).

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
- 134 automated tests; a headless end-to-end `--selftest`; a headless `--render-ui-snapshots`.

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
Debug   → Build complete! (36.59s)   [180 tasks]
Release → Build complete! (38.70s)   [140 tasks]
```

Zero warnings, zero errors (`swift build 2>&1 | grep -c "warning:"` → `0`).

`xcodebuild` was **not** run — it does not exist on this machine (evidence in §5.1).

### 3.2 Test suite

```bash
./scripts/test.sh
```

```
✔ Test run with 134 tests in 17 suites passed after 0.174 seconds.
```

Suites: Coordinate conversion · Output sizing · CaptureRegion resolution · Clip trimming ·
Animated WebP timeline · Frame buffer limits · Annotation document · Annotation rendering ·
Markdown reference · Output file writing · libwebp bridge · Animated WebP frame coalescing ·
Magic byte detection · Export service (stills / animated WebP / degenerate recordings) ·
Screen recording permission state.

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

Abridged output from the last run (Release build gave identical results):

```
TriCap self-test
  libwebp: 1.6.0 (encoder/mux/demux (1, 6, 0)/(1, 6, 0)/(1, 6, 0))

== Screen recording permission
  CGPreflightScreenCaptureAccess() = true
  ScreenRecordingPermission.authorizationStatus() = authorized
  PASS  SCShareableContent reachable  — 1 display(s), 12 app(s)

== Displays
  display 2: appKit=(0,0 1920x1080) quartz=(0,0 1920x1080) scale=2.0 pixels=3840x2160
  NOTE: only one display is attached, so multi-display selection is NOT covered by this run.

== Region resolution
  PASS  region resolves  — pixels=(200,1360 800x600) sourceRect(pt)=(100,680 400x300)
  PASS  pixel size == points × scale
  PASS  1-pixel top-left corner selection  — (0,0 1x1)

== Still capture
  PASS  SCScreenshotManager capture  — 800x600, source colour space kCGColorSpaceSRGB, converted=false
  PASS  capture matches the requested pixel rect
  PASS  capture is sRGB  — kCGColorSpaceSRGB

== Annotate and export stills
  PASS  annotation document has 4 items and can undo
  PASS  export PNG   — still-png.png  63537 bytes container=png
  PASS  export JPEG  — still-jpeg.jpg 65795 bytes container=jpeg
  PASS  export WebP  — still-webp.webp 22058 bytes container=webpStill
  PASS  <each> extension matches magic bytes
  PASS  <each> reference is vault-relative  — ![still-png](assets/still-png.png) …
  PASS  WebP decodes back at the same size  — 800x600
  PASS  outside-vault reference is the absolute path
  PASS  filename collision resolves to -1  — collision.png, collision-1.png

== Recording (5 s target)
  output pixel size: 800x600
  PASS  recording finishes with frames — 60 frames, 5.05 s, 3334 KB retained,
                                        stop=userStopped, dropped=0
  PASS  retained memory stayed under the ceiling
  PASS  frame count stayed under the ceiling
  PASS  frame timestamps are non-decreasing

== Trim and export animated WebP
  PASS  trim keeps the expected frame count — kept 56 of 60 (indices 2...57)
  PASS  trimmed clip restarts at t=0
  PASS  timeline is strictly increasing and starts at 0
  PASS  animated WebP written — clip.webp 57994 bytes
  PASS  container is animated WebP
  PASS  stored frame count is within the submitted count — 52 stored of 56 submitted
  PASS  total playback duration is preserved — 4716 ms vs 4716 ms
  PASS  canvas size round-trips — 800x600
  PASS  loop count is 0 (infinite)
  PASS  timestamps read back strictly increasing
  PASS  every frame duration > 0
  PASS  markdown reference is vault-relative — ![clip](assets/clip.webp)
  PASS  fixed overlay present on every frame — sampled (40,20) in all 52 frames

== Cancel an in-flight recording
  PASS  cancel completes and releases every retained frame
  PASS  finish after cancel yields no clip — noFramesCaptured
  PASS  cancelling wrote no file — 6 files in assets/, unchanged from 6

== Summary
  ALL CHECKS PASSED
```

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
| `02-editor-still.png` | Still editor: 5-tool picker, 6-colour palette, stroke slider, undo/redo/clear, canvas with arrow + rectangle + text + mosaic composited, `940 × 620 px`, Format picker (PNG), Close/Save |
| `03-editor-clip-trim.png` | Clip editor: mosaic tool selected with its block-size slider, `8 of 12 frames · 0.7 s`, Reset trim, Start=2 / End=9 / Frame=5 sliders, `640 × 400 px  Animated WebP` |
| `04-selection-overlay.png` | Selection overlay: dimmed desktop, punched-out bright selection, **red** border (recording mode), `940 × 520 px` badge |
| `05-recording-hud.png` | Recording HUD: red dot, `4.2 s / 15 s`, `51 frames · 12 MB`, Stop button |
| `06-menu-bar-item.png` | Status-item template icon at menu-bar size |

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

### 4.5 Other gaps

- **HDR / wide-gamut capture** — the machine's display reports sRGB, so the wide-gamut branch of
  `ImageProcessing.normalizedToSRGB` never fired in a live capture. The detection list and the
  user-facing notice are unit-covered only. Verify on a P3 or HDR display.
- **Intel (x86_64)** — never built or run. libwebp's SSE4.1/AVX2 kernels are compiled out (see
  [docs/LIBWEBP.md](docs/LIBWEBP.md) § SIMD); correct but slower. Universal-binary packaging is not
  set up.
- **macOS 14/15** — the deployment target is 14.0 but only macOS 26.5.2 was available. Nothing
  newer than the 14.0 SDK surface is used knowingly, but this is untested.
- **Disk-full** — `NSFileWriteOutOfSpaceError` is mapped to friendly copy; only the read-only
  directory branch is actually exercised by tests.
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

### 5.2 Known weak spots

- **`FrameConverter` cropping.** SCK's `contentRect`/`scaleFactor` attachments are used to crop an
  over-sized IOSurface. On this machine the delivered buffer already matched the requested size, so
  the crop branch was never taken in a live run. It is reachable on other configurations.
- **`RecordingHUD.StopProxy` is a singleton.** Only one recording can be in flight (guarded by
  `AppDelegate.isCapturing`), but it is a global mutable target and would break with concurrent HUDs.
- **`AnnotationRenderer.drawMosaic` calls `ctx.makeImage()` per mosaic item.** With many mosaics on
  a large clip this is O(items × frames) full-canvas snapshots. Fine for the MVP; a real cost at
  scale.
- **`HotKeyCombo.keyName` is a fixed ANSI table.** Non-ANSI layouts will show a wrong *label*; the
  key code registered is still correct. `UCKeyTranslate` would fix the label.
- **`SettingsStore` persists on every `didSet`.** Dragging a slider writes `UserDefaults` per tick.
- **Editor windows are retained in a dictionary keyed by `ObjectIdentifier`** and removed in
  `windowWillClose`. Worth confirming there is no retain cycle through `EditorModel`'s closures
  (`onClosed` captures the window via a local `var`).
- **Hot-key re-registration** now happens the moment `SettingsStore.settings` changes
  (`store.onChange` → `registerHotKey()`), not only when the settings window closes. The older
  `syncHotKeyRegistration()` call after each capture is kept as a belt-and-braces fallback; a
  reviewer may consider it redundant.

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

# 4. end-to-end capture pipeline (captures a real screen region)
.build/release/TriCap --selftest ./build/selftest

# 5. UI snapshots
.build/release/TriCap --render-ui-snapshots ./build/ui-snapshots

# 6. re-vendor libwebp from upstream (verifies the pinned SHA-256)
./scripts/vendor-libwebp.sh 1.6.0   # should produce no diff

# 7. run it
open build/release/TriCap.app
```

Steps 4 and 5 need Screen & System Audio Recording permission for the binary being run.

**Housekeeping note.** A copy of the bundle was briefly placed in `/Applications` and
`~/Applications` while trying to get screen automation to see it; both were removed once that
approach was declined. Nothing outside this repository is left behind except the
`app.tricap.ui-snapshots` `UserDefaults` suite used (and wiped on each run) by the snapshot
renderer.
