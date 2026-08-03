# TriCap architecture

## Build shape, and why it is a SwiftPM package

The machine this was built on has **Command Line Tools but no `Xcode.app`**, so `xcodebuild` is
unavailable:

```
$ xcodebuild -version
xcode-select: error: tool 'xcodebuild' requires Xcode, but active developer directory
'/Library/Developer/CommandLineTools' is a command line tools instance
```

The project is therefore a SwiftPM package plus `scripts/build-app.sh`, which assembles the
SwiftPM executable into a real `TriCap.app` bundle (Info.plist with `LSUIElement`, the bundle
identifier TCC keys permission on, the libwebp licence files, ad-hoc code signature). This costs
one shell script and buys a build that works with either toolchain. Adding an `.xcodeproj` later
is mechanical: the targets map one-to-one.

Two other consequences of the CLT-only toolchain:

- **`swift-testing`, not XCTest.** `XCTest.framework` is genuinely absent from CLT.
  `Testing.framework` ships in `$(xcode-select -p)/Library/Developer/Frameworks` but SwiftPM does
  not add that directory to the search path unless Xcode is the active developer directory.
  `scripts/test.sh` passes the `-F` and two `-rpath` flags that make `swift test` work.
- **libwebp is vendored, not linked.** See below.

## Module layout

```
CWebP          vendored libwebp 1.6.0 (C)
   ↑
TriCapKit      coordinate spaces · limits · settings · errors · image plumbing · display survey
   ↑        ↖        ↖              ↖
CaptureCore  SelectionUI  AnnotationCore  →  ExportCore
   ↑             ↑             ↑              ↑
   └─────────────┴──── TriCapApp ────────────┘
```

| Target | Responsibility |
|---|---|
| `CWebP` | Vendored libwebp: dec, demux, dsp, enc, mux, utils, sharpyuv. One hand-written module map exposing only the public headers TriCap uses. |
| `TriCapKit` | The shared vocabulary: `CoordinateConverter`, `DisplayGeometry`, `CaptureRegion`, `RecordingLimits`, `AnimatedWebPOptions`, `AppSettings`, `HotKeyCombo`, `TriCapError`, `ImageProcessing`, `DisplaySurvey`, logging. |
| `CaptureCore` | Permission state, ScreenCaptureKit configuration, `StillCaptureService`, `RegionRecorder`, the bounded `FrameBuffer`, the `RecordingSession` lifecycle and its `CaptureSessionGate`, clip trimming and WebP timeline construction. |
| `SelectionUI` | The cross-display selection overlay: one borderless shielding-level window per screen, one shared global selection rect, `R`/`S` mode switching, `Esc`/right-click cancel. |
| `AnnotationCore` | Annotation model (`AnnotationItem`, `AnnotationShape`, `AnnotationStyle`), the snapshot-based `AnnotationDocument` with bounded undo/redo, and `AnnotationRenderer`. |
| `ExportCore` | `WebPCodec` (the libwebp bridge), `StillImageCodec` + `MagicBytes`, `OutputFileWriter`, `MarkdownReference`, and `ExportService` which renders → encodes → writes → **re-reads and verifies**. |
| `TriCapApp` | Menu-bar item, global hot key, settings, editor, recording HUD, capture orchestration, plus two headless entry points (`--selftest`, `--render-ui-snapshots`). |

### Deviations from the suggested structure, and why

The brief suggested five modules (CaptureCore, SelectionUI, AnnotationCore, ExportCore,
TriCapApp). All five exist. Two additions:

1. **`TriCapKit` was added.** Coordinate types, capture limits and settings are needed by *three*
   of the five modules. Without a shared base, either `SelectionUI` would have to depend on
   `CaptureCore` (inverting the natural direction — selection happens before capture) or the
   geometry would be duplicated. A flat dependency graph with one leaf-ward vocabulary module
   keeps the coordinate math in exactly one place, which is the single most important property
   given the "prevent selection offset" requirement.

2. **`DisplaySurvey` lives in `TriCapKit`, not `CaptureCore`.** It is the only AppKit-touching
   thing there. It reads `NSScreen`/`CGDisplayBounds` and produces pure `DisplayGeometry` values.
   Putting it beside the geometry types is what lets every coordinate test run headless.

`CWebP` is a sixth target purely because SwiftPM needs C and Swift in separate targets.

## Capture session lifecycle

Exactly one capture may be in flight, and "in flight" spans the whole pipeline: selection,
countdown, recording, teardown and the hand-off to the editor.

`CaptureSessionGate` is the single occupancy flag. Every entry point — the global hot key and both
menu items — calls `tryBegin()`, and the gate is released in one `defer` at the end of the whole
`Task`. A refused entry is counted and logged rather than silently dropped.

`RecordingSession` owns one recording and holds the invariant that makes the gate meaningful:
**`run()` does not return until the backend is torn down and the chrome is dismissed.** An earlier
version released its "busy" flag as soon as the HUD appeared, so a second hot-key press could
begin a new session on top of a live one, overwriting the recorder, the stop target and the cancel
key. Stop and cancel are latched: the first request wins, later ones are counted and ignored, so a
double-click on Stop, or Stop racing an automatic duration stop, is harmless.

Both the backend (`RecordingBackend`) and the on-screen furniture (`RecordingChrome`) are
protocols, so the lifecycle rules are unit-tested with fakes — no ScreenCaptureKit, no window
server. `RegionRecorder` and `RecordingChromeController` are the production implementations.

## Recording duration and the static-screen problem

ScreenCaptureKit only delivers a `.complete` frame when the picture actually changed. A duration
ceiling checked when a frame arrives therefore never fires on a still screen: a "15 second
maximum" recording of a motionless window would run until the user noticed. So:

- `RegionRecorder` runs a 10 Hz tick on the main run loop that measures elapsed time with
  `ContinuousClock` (monotonic — an NTP correction cannot move the ceiling) and stops the
  recording itself. The stop is latched, so it is reported exactly once and the tick timer is
  invalidated.
- The clip records `wallClockDuration`, measured from the first *retained* frame to the moment
  capture stopped. `RecordedClip.duration` returns that, floored at "last frame + one nominal
  interval" so a recording stopped microseconds after a frame does not end on a flash.
- `ClipTiming.timeline(for:nominalFrameInterval:totalDuration:)` extends the final frame to the
  measured end, so one second of motion followed by fourteen static seconds exports as a fifteen
  second animation whose last frame holds for fourteen seconds.
- `ClipTrimmer.trimmedDuration(frames:range:clipDuration:)` defines what trimming means: keeping
  the tail keeps the recording's real end; trimming the tail off ends the clip when the first
  dropped frame would have replaced the last kept one.

## Cancelling a recording from another application

The cancel key has to work when the user has clicked into the app they are recording, which a
`NSEvent.addLocalMonitorForEvents` monitor cannot do — it only sees keys delivered to TriCap. A
*global* `NSEvent` monitor would need Accessibility permission, a second TCC prompt TriCap refuses
to ask for.

Carbon's `RegisterEventHotKey` accepts a modifier-less key code and needs no permission at all.
Verified on this machine: `RegisterEventHotKey(kVK_Escape, 0, …)` returns `noErr` with
`AXIsProcessTrusted() == false`. `GlobalHotKeyMonitor` therefore keeps independent *slots* — the
user's configurable capture shortcut and a transient recording-cancel key — and
`RecordingChromeController` claims a bare Escape for the lifetime of one capture.

That claim spans the **countdown as well as the recording**. The countdown is the phase a user is
most likely to abandon, and the phase where TriCap is least likely to be frontmost — the whole
point of a countdown is to give them time to arrange another window. `TransientHotKeyClaim` holds
the rules: register once (a duplicate registration fails with `eventHotKeyExistsErr`), rebind the
action in place when the recording takes over so no keypress falls through the gap, and release
exactly once on every exit path. The registrar is injected, so those rules are unit-tested without
Carbon.

There is deliberately **no global stop key**. The HUD is a borderless, never-key floating panel, so
a `keyEquivalent` on its Stop button could never fire; advertising Return as a way to stop was a
promise the window could not keep. Stopping is a click; Escape — a real system-wide hot key —
cancels.

The trade is explicit: while a recording runs (at most `RecordingLimits.maxDuration`), Escape is
intercepted system-wide. If another application already owns a bare Escape hot key, the HUD says
so instead of pretending Escape is wired up.

## Quality presets

`QualityPreset` (in `TriCapKit`) names an outcome — *Smaller file*, *Balanced*, *Sharper*,
*Up to 4K* — and stands for four concrete encoder arguments: the still quality factor, the
recording long-edge cap, the recording frame rate, and the animation quality factor. Those four
are exactly the values that reach `StillImageCodec.encode(quality:)`, `SCStreamConfiguration` and
`WebPConfig`, which is what the tests assert.

`custom` is a *state*, not a menu item. `AppSettings.reconcileQualityPreset()` re-derives the
label from the values after every edit, so:

- editing any advanced field drops the label to Custom and keeps the user's numbers;
- applying `.custom` is a no-op, because there are no canonical values to write;
- a settings blob with no `qualityPreset` key (written by a build that predates presets) loads as
  Custom with every value preserved, rather than being snapped to a preset — which would silently
  change the quality an existing user was already getting.

`applyQualityPreset` reads the label back off the *clamped* values rather than trusting its
argument, so a preset whose numbers fell outside `RecordingLimits`' ranges could not claim to be
applied when it was not.

`OutputFormat.usesQualityParameter` is what keeps the UI honest: PNG is lossless, `encodePNG`
takes no quality argument, and the settings window shows *Lossless — no setting* instead of a
control that does nothing.

Preset names and copy are held to the same standard by tests: the top preset must not claim to be
an encoder ceiling it is not (it caps at 3840 px / 20 fps / quality 95, deliberately short of the
30 fps and quality-100 limits), and no format explanation may state a compression ratio TriCap has
not measured — `formatCopyAvoidsInventedNumbers` fails on any digit in that copy.

### Settings changes are announced once, with the real before-and-after

Normalisation must not be observable as a second edit. `AppSettings.resolveUpdate` pairs a
normalised proposal with the values it actually replaces, and `SettingsStore` suppresses the
re-entrant `didSet` its own normalising write causes. Without that, an edit to settings written by
a build with no presets — which always load as `.custom`, even when their values match a preset —
reported `proposal → normalised` to the observer. Both sides already carried the new hot key, so
"did the hot key change?" answered *no* and the shortcut was persisted but never re-registered.

Enum fields decode tolerantly for the same reason: `decodeIfPresent` *throws* on an unrecognised
raw value, and settings are read with `try?`, so one renamed case would discard the user's save
folder, vault root and hot key along with it.

## Coordinate model

This is the highest-risk part of a screenshot tool, so it is worth stating precisely.

| Space | Origin | +y | Unit | Produced by |
|---|---|---|---|---|
| AppKit global points | bottom-left of the primary screen | up | point | `NSScreen.frame`, mouse events |
| Quartz global points | top-left of the primary display | down | point | `CGDisplayBounds` |
| Display-local points | top-left of *that* display | down | point | Quartz global − display origin |
| Display pixels | top-left of that display | down | **pixel** | display-local × `backingScaleFactor` |
| Capture pixels | top-left of the frame | down | pixel | display pixels, optionally downscaled by the long-edge cap |

Rules the code enforces:

- The AppKit↔Quartz flip is `y' = primaryHeight − y − height` for a rect (the *height*
  participates, because the origin moves from the bottom-left to the top-left corner). It is its
  own inverse; both directions are tested.
- Pixel rects are snapped **outward** (`floor` the near edge, `ceil` the far edge) so a drag never
  silently loses the sub-pixel sliver the user covered, then intersected with the display so an
  edge drag cannot ask ScreenCaptureKit for out-of-bounds pixels.
- `SCStreamConfiguration.sourceRect` is fed the point rect **recomputed from the snapped pixel
  rect**, not the raw drag — otherwise the capture and the selection disagree by a sub-pixel
  amount that compounds on Retina.
- A drag spanning two displays resolves to the display with the largest overlap, and
  `CaptureRegion` clips the selection to that display in AppKit space *before* any flip.

`Sources/TriCapKit/Coordinates.swift` is the only file that performs these conversions.
`Tests/TriCapTests/CoordinateTests.swift` and `CaptureRegionTests.swift` pin the exact numbers,
including the Retina one-pixel corner case and a secondary display whose AppKit and Quartz origins
disagree.

## Colour policy

One colour space, one pixel layout, everywhere: **8-bit sRGB, opaque, `R G B X`**
(`CGImageAlphaInfo.noneSkipLast | .byteOrder32Big`).

- `DisplaySurvey` records the public `NSScreen` wide-gamut flag and extended dynamic-range
  capability. `SCStreamConfiguration.colorSpaceName` is deliberately left unset, invoking
  ScreenCaptureKit's documented default of the display's native profile. This also avoids storing
  a temporary Swift bridge in the SDK's non-retaining `assign CFStringRef` property.
- Intermediate downscaling retains the source profile. `ImageProcessing.normalizedToSRGB` then
  re-renders into the canonical layout and reports what source conversion happened.
- A wide-gamut or HDR source (`Display P3`, `Rec. 2020`, PQ/HLG, extended sRGB, or an EDR display)
  is surfaced to the user in the editor: *"colours outside sRGB have been mapped into gamut and
  HDR highlights are clipped."* The conversion is not silent even if ScreenCaptureKit delivers an
  sRGB-tagged buffer from an EDR display.
- Fixing the layout at RGBX means the libwebp bridge can use `WebPPictureImportRGBX`
  unconditionally. Importing this buffer as RGBA would read the unused X byte as alpha and produce
  a fully transparent file — there is a regression test for exactly that.

## Memory bounds

A 15 s × 12 fps × 1440 px recording is ~180 frames; held as decoded bitmaps that is ~930 MB. So:

1. Frames are downscaled **at capture time** — `SCStreamConfiguration.width/height` is set to the
   long-edge-capped output size, so ScreenCaptureKit does the resampling and nothing larger is
   ever allocated.
2. Each frame is PNG-compressed immediately on the sample-handler queue and stored as `Data`
   (~60 KB rather than ~5 MB per frame; a real 5 s capture measured 3.3 MB total).
3. `FrameBuffer` enforces a frame-count ceiling *and* a byte ceiling under one lock, latching a
   `RecordingStopReason` the recorder observes. Once latched, further appends are rejected without
   growing memory.
4. `SCStreamConfiguration.queueDepth = 5` bounds what SCK buffers for us.
5. Stop/cancel closes a commit gate shared with the sample callback, then removes the stream output,
   stops capture and drains the serial sample queue before snapshotting or resetting the buffer.
6. Export pulls frames back **one at a time** through `AnimationFrameSource.loadFrame`, so peak
   usage during encoding is one decoded frame plus libwebp's canvas.

## Annotation model

`AnnotationDocument` uses **snapshot undo**: each mutation pushes a copy of the item array.
Annotation items are small value types, so snapshots are cheaper than a command log and cannot
drift out of sync with the model the way inverse-operation undo can. History depth is bounded
(100 by default). Degenerate shapes — a click that made a zero-size rect, an empty text box — are
rejected rather than stored, so they never occupy an undo step the user has to press twice to get
past.

Annotation coordinates are **canvas pixels, top-left origin, +y down**. `AnnotationRenderer` does
the single flip into `CGContext` space; nothing else in the codebase flips them. Mosaic samples
the *already-composited* canvas, so redacting on top of an earlier annotation actually redacts it.

For a clip, the same item list is composited onto every frame — that is what makes annotations a
fixed overlay rather than something that drifts.

## Export and verification

`ExportService` never reports success on an unverified file. After writing it re-reads the bytes
and checks:

- magic bytes match the extension (`MagicBytes` distinguishes still from animated WebP via the
  `VP8X` animation flag);
- for animations: canvas size, frame count within bounds, **total playback duration exactly
  equal** to the requested end timestamp, strictly increasing timestamps, and loop count.

If verification fails the file is deleted rather than left for the user to paste into a note and
discover is broken later.

The frame-count check is deliberately an inequality. libwebp coalesces a frame identical to its
predecessor into that frame's duration, so `stored ≤ submitted`. Duration is the invariant that
survives coalescing exactly. When *every* frame is identical libwebp drops the animation chunk and
writes a still WebP; that is detected, kept, and reported as `collapsedToSingleFrame`.

## Writing files

`OutputFileWriter` writes to a temp file in the destination directory, then *atomically claims*
the final name. A `fileExists` check followed by a write would have a race window; two TriCap
exports in the same second cannot clobber each other. Names go `base.ext`, `base-1.ext`, … up to
1000, then one random-token fallback.

Three claim mechanisms, tried in order, because not every filesystem implements the strong ones:

| Strategy | Call | Where it works |
|---|---|---|
| `hardLink` | `link(2)` | APFS, HFS+. Best: the final name never exists in a partial state, because the bytes are already complete in the temp file. |
| `exclusiveRename` | `renamex_np(…, RENAME_EXCL)` | APFS, HFS+. Atomic create-or-fail. |
| `exclusiveCreate` | `open(O_CREAT\|O_EXCL)` then write | Everywhere, including exFAT and SMB. Claims the name atomically but writes the bytes afterwards, so an abrupt power loss mid-write can leave a short file. Last resort. |

`link(2)` returns `EPERM` on exFAT/FAT and `ENOTSUP` on many network mounts; treating that as a
hard failure meant a save folder on a USB stick or a NAS could not be written to at all. Those
errno values now fall through to the next strategy, while a real error still propagates.

## Feedback surfaces

Three small types exist so that what the user is *told* is testable, not just drawn:

- `ExportSummary` (in `ExportCore`) turns an `ExportResult` plus the actual pasteboard outcomes
  into the confirmation wording. It takes what *happened* — the `Bool` each pasteboard write
  returned — rather than what the settings asked for, so the toast cannot claim a copy that did
  not occur, and it names the *kind* of thing copied ("the Markdown reference" vs "the file path")
  because those are very different things to paste into a note.
- `RecordingHUD.populateHUD` builds the HUD body, and both the live floating panel and the
  offscreen UI-snapshot renderer call it. Previously the snapshot rebuilt the HUD by hand and
  drifted out of date the moment the real one changed.
- `WelcomeView` is a plain SwiftUI view driven by `HotKeyCombo` and `ScreenRecordingAuthorization`,
  so every permission state renders without a live TCC prompt.

## Editor window ownership

`EditorPresenter` is the sole owner of open editor windows. The editor's *Close* button needs to
reach its own window, and capturing it strongly in the model's `onClosed` closure forms
`window → contentViewController → EditorView → model → closure → window` — a cycle that keeps the
window, the model and every retained recording frame alive forever (tens of megabytes per leaked
editor). The closure captures a box that holds the window **weakly** instead. `--selftest` proves
it: it builds a real clip editor, closes it, and asserts that weak references to the window and
the model are both nil.

## Hot key

`RegisterEventHotKey` (Carbon) rather than an `NSEvent` global monitor: a global monitor needs
Accessibility permission — a second, scarier TCC prompt on top of Screen Recording — and cannot
stop the key reaching the focused app. Carbon's hot-key API remains the only public way to claim a
system-wide combination without that permission. A modifier-less combination is refused for the
*configurable* shortcut (it would swallow ordinary typing); only the transient recording-cancel
slot opts in via `allowingNoModifiers`.

Claiming a new combination requires releasing the old one first, so a rejected new shortcut used
to leave TriCap with no working shortcut at all. `HotKeyRegistrationPolicy` (a pure function, so
the behaviour is testable without Carbon) now rolls back to the previous combination, the app
reverts the stored setting to match, and the user is told which shortcut is actually live.

## Selection overlay

One borderless window per `NSScreen` at `CGShieldingWindowLevel()`, `sharingType = .none` (so the
dimming layer never appears in *other* apps' recordings). The selection rect lives in AppKit
global points and is broadcast to every overlay, so a drag crossing monitors renders as a single
continuous rectangle. TriCap's own application is excluded from the `SCContentFilter`, so neither
the overlay nor the recording HUD can end up inside a capture.

## Headless entry points

`TriCapApp` has two argument-driven modes that exit without installing the menu bar:

- `--selftest <dir>` drives the whole real pipeline and exits non-zero on any failed check.
- `--render-ui-snapshots <dir>` renders the real view hierarchies offscreen to PNG.

Both exist because the interactive flow needs a human at the keyboard while everything downstream
of "the user dragged a rectangle" can be verified unattended — and because a reviewer needs one
reproducible command.
