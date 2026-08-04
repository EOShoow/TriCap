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
| `TriCapKit` | The shared vocabulary: `CoordinateConverter`, `DisplayGeometry`, `CaptureRegion`, `RecordingLimits`, `AnimatedWebPOptions`, `AppSettings`, `HotKeyCombo`, `TriCapError`, `ImageProcessing`, `DisplaySurvey`, logging — plus the pure logic behind window-aware selection (`WindowPicker`, `SelectionGesture`, `SnapEngine`), pinning (`PinLimits`, `PinPlacement`, `PinZoom`, `PinOpacity`, `PinFocusOrder`, `PriorityHotKeyClaim`), chrome placement (`HUDPlacement`) and animation timing (`IncrementalTimeline`, `AnimationEncodeStrategy`). |
| `CaptureCore` | Permission state, ScreenCaptureKit configuration, `StillCaptureService`, `RegionRecorder`, the bounded `FrameBuffer`, the `RecordingSession` lifecycle and its `CaptureSessionGate`, `WindowSurvey`, clip trimming and WebP timeline construction. |
| `SelectionUI` | The cross-display selection overlay: one borderless shielding-level window per screen, one shared global selection rect, window highlighting under the pointer, `R`/`S` mode switching, `Esc`/right-click cancel. |
| `AnnotationCore` | Annotation model (`AnnotationItem`, `AnnotationShape`, `AnnotationStyle`), the snapshot-based `AnnotationDocument` with bounded undo/redo, and `AnnotationRenderer`. |
| `ExportCore` | `WebPCodec` (the libwebp bridge), `WebPAnimEncoderSession` + `LivePreEncoder` (encode-while-recording), `PreEncodeReuse`, `StillImageCodec` + `MagicBytes`, `OutputFileWriter`, `MarkdownReference`, `PasteboardImage`, and `ExportService` which renders → encodes → writes → **re-reads and verifies**. |
| `TriCapApp` | Menu-bar item, global hot keys, settings, editor, recording HUD, pin windows (`PinWindow`, `PinboardController`), capture orchestration, plus two headless entry points (`--selftest`, `--render-ui-snapshots`). |

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

### Two features, one Escape

Pinning wants the same key: a pin parked over another application has to be dismissable without
hunting for TriCap. Carbon will not register the same combination twice, so a recording started
while a pin was open would have failed to claim Escape — and recording cancellation, the more
urgent of the two, would have been the one to lose.

`PriorityHotKeyClaim` resolves that with one registration and a *stack* of handlers. Pushing
returns a token; the top of the stack receives the key; popping a token — in any order — hands the
key back to whoever is underneath, and the registration is released only when the stack empties.
So a pin claims Escape, a recording pushes on top of it and takes Escape for its duration, and when
the recording ends the pin gets Escape back. `SharedEscapeKey` holds the single process-wide claim,
and both `RecordingChromeController` and `PinboardController` go through it.

## Where the chrome goes

The recording HUD is the only way to stop a recording with a click, so a HUD off the edge of the
screen is a recording that cannot be ended except by waiting out the duration limit.

`HUDPlacement` (TriCapKit, pure) tries four positions in order — outside-below, outside-above,
inside-bottom, inside-top — and clamps whatever it picks into the target screen's **visible frame**,
which excludes the menu bar and the Dock. Placing the HUD *inside* the selection is safe because
the chrome is `sharingType = .none` and TriCap's own windows are excluded from the capture filter,
so it is never recorded; it only covers what the user is watching. The countdown is centred on the
selection and clamped the same way.

The screen is resolved by matching `CGDirectDisplayID` against `NSScreen`, never by falling back to
`NSScreen.main`: a recording on a secondary display must not put its Stop button on the primary one.

The previous version preferred below, fell back to above *without checking whether that fit*, and
never constrained y at all. `scripts/diagnostics/hud-placement-probe.swift` runs that algorithm over
realistic selections and puts 8 of 12 outside the visible frame, plain full-screen capture included.

## Export cost, and where the work happens

Two changes, in the order the measurements forced them. Both are reproducible with
`TriCap --benchmark-export`, which reports tail latency and in-recording cost separately because
moving work into the recording can trade one for the other.

### The encoder was doing far more work than asked

Profiling a 1440×900 high-motion clip attributed **857 ms per frame** to `WebPAnimEncoderAdd`,
against 0.1 ms for PNG decode and 8.7 ms for pixel extraction. Nothing else was worth looking at.

The cause was two `WebPAnimEncoderOptions` flags, neither of them a user setting: `minimize_size`
retries frames hunting for a smaller result, and `allow_mixed` encodes **every frame both lossily
and losslessly** and keeps the smaller — and lossless encoding of a noisy megapixel frame is the
most expensive operation in the pipeline. `AnimationEncodeStrategy` names both settings; the
default is now `.balanced` with both off, and `.thorough` preserves the old behaviour for
comparison. Measured: **873.7 ms → 45.6 ms per frame for 2.7% larger files.** The user's quality,
method, lossless and loop settings are untouched.

### Encoding while recording, when it is safe to

At 45.6 ms per frame against an 83 ms capture interval, encoding now fits inside the interval —
which is what makes pre-encoding possible at all. `LivePreEncoder` (ExportCore) owns a long-lived
`WebPAnimEncoderSession` on one serial queue and is fed by `RegionRecorder.onFrameAccepted`, which
fires outside the frame lock for exactly the frames the PNG buffer retains.

It is never load-bearing. `submit` does no encoding on the capture path; at most `maxBacklog`
frames may be waiting, and past that the fast path is **abandoned** rather than allowed to grow a
second unbounded buffer beside the PNG one. Every failure — backlog, encoder error, cancellation,
setup — is recorded and the export simply takes the route it always took, so nothing the user
recorded can be lost by this path.

Reuse is decided by `PreEncodeReuse`, a pure function that defaults to *no*. It requires the whole
untrimmed range (same frame count **and** same timestamps), no annotations, the same canvas, all
four encoder parameters unchanged, and the same end timestamp. Anything else — a trim, an
annotation, a quality change — goes back through per-frame render-and-encode. Whichever route runs,
the file is written, re-read and verified by the same code.

The one thing that cannot be computed live is the **end** timestamp, because it depends on the
measured wall-clock duration and is only final once capture stops. Per-frame timestamps can be, and
`IncrementalTimeline` in TriCapKit is the single rule both `ClipTiming` and the pre-encoder run —
a one-millisecond disagreement between them would make the pre-encoded file silently wrong for the
timeline it claims.

Measured at 1440×900, 181 frames (15 s at 12 fps), median of three, recording paced at the real
frame interval: **177.0 s → 11.3 s** from the strategy change alone, **→ 0.85 s** with pre-encoding.
Worst frame lateness 0.2 ms and no dropped frames in any arm.

## The mosaic is Core Image, and what it is not

`AnnotationRenderer.drawMosaic` uses `CIPixellate` through one shared `CIContext` (documented
immutable and thread-safe; filters are created per call). It replaced a hand-written
crop→downscale→upscale implementation whose crop rect was double-flipped — `CGImage.cropping(to:)`
already works in row space — so it pixelated the **vertically mirrored** band and, over a light
page, painted white blocks unrelated to the covered content.
`scripts/diagnostics/mosaic-mirror-probe.swift` reproduces the defect standalone; `MosaicTests`
pins the fix, including canvas-anchored grid (no drift when the rect moves), edge clamping (no
hollow fringes), untouched pixels outside the rect, and byte-identical output across concurrent
renders. One render path serves the editor preview, every still format and every animated frame;
measured cost on a real capture is ~3 ms per frame, which is why no GPU framework dependency was
added.

**Boundary:** pixelation is visual obscuration, not security-grade redaction — a pixelated block
is a deterministic function of the pixels beneath it, and low block counts over known fonts can be
reconstructed. For credentials or keys, the honest tool is a filled rectangle. TriCap's copy says
"pixelate", never "blur", and never claims irreversibility.

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
system-wide combination without that permission.

A modifier-less hot key is swallowed everywhere, so binding one to an ordinary key would make that
character untypeable in every application. `HotKeyCombo.bareKeyAllowList` is therefore *exactly*
the function row, F1–F20 — enumerated key codes, not a range test, so a letter can never slip in.
That is what lets the pin shortcut default to a bare `F3` while `⌥⇧5` keeps its modifiers, and the
transient Escape claim still opts in separately via `allowingNoModifiers`.

Claiming a new combination requires releasing the old one first, so a rejected new shortcut used
to leave TriCap with no working shortcut at all. `HotKeyRegistrationPolicy` (a pure function, so
the behaviour is testable without Carbon) now rolls back to the previous combination, the app
reverts the stored setting to match, and the user is told which shortcut is actually live. The
screenshot and pin shortcuts run that policy **independently**, in separate slots: `F3` is Mission
Control's factory binding and is the registration most likely to fail, and it must not be able to
take `⌥⇧5` down with it. A failure is reported — naming Mission Control — and the key stays
re-bindable; TriCap never silently substitutes a different one.

## Pinning

A pin is an `NSPanel` at `.floating` — deliberately *not* the `CGShieldingWindowLevel()` the
selection overlay uses. A pin is content the user parked somewhere and then forgot about; it must
never be able to sit over a password prompt, a permission sheet or the login window. It is a
`.nonactivatingPanel` with `canBecomeKey == false` and is shown with `orderFrontRegardless()`
rather than `makeKeyAndOrderFront`, so pinning a reference never interrupts typing, and
`[.canJoinAllSpaces, .fullScreenAuxiliary]` keeps it in view as the user moves between Spaces.

Teardown does not wait for `dealloc`. AppKit keeps a window that has been on screen alive past
`close()` for its own bookkeeping — reproducible with a `NSPanel` and no TriCap code at all, see
[scripts/diagnostics/panel-lifetime-probe.swift](scripts/diagnostics/panel-lifetime-probe.swift) —
and a pin holds a full-resolution screenshot. `PinWindow.tearDown()` therefore drops the bitmap,
the image view and the delegate explicitly and is idempotent, so the megabytes come back when the
user closes the pin rather than whenever AppKit gets round to it. `PinLimits` bounds the rest:
twelve pins, 40 MP each, 120 MP in total, refused with a sentence that says which ceiling was hit.

## Window-aware selection

Hovering highlights the topmost selectable window and a click captures it; dragging past 6 pt
(radially, and stickily — dragging back to the origin does not turn a region into a window click)
switches to a free region. `WindowSurvey` asks ScreenCaptureKit for the window list and converts
each `SCWindow.frame` from Quartz to AppKit points through the same `CoordinateConverter` as
everything else; if the list is unavailable it returns empty and the overlay degrades to plain
drag selection rather than failing.

The decisions themselves are pure functions in `TriCapKit` so they can be tested without a screen:
`WindowPicker` (exclusions — TriCap's own windows, off-screen, `level > 0` system layers,
degenerate sizes — and overlap resolved by stacking order), `SelectionGesture` (the click/drag
threshold), and `SnapEngine` (8 pt edge snapping, disabled by holding Option). `SnapEngine` snaps
each axis independently: a short selection near a display edge can have both of its horizontal
sides inside the threshold of the same line, and collapsing that axis must not also cancel a
perfectly good snap on the other one.

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
- `--benchmark-export <dir> [--frames N] [--runs N] [--width W] [--height H]` measures animation
  export against synthetic high-motion material, reporting tail latency and in-recording cost
  separately for three configurations. See ARCHITECTURE.md §"Export cost".

Both exist because the interactive flow needs a human at the keyboard while everything downstream
of "the user dragged a rectangle" can be verified unattended — and because a reviewer needs one
reproducible command.

## App icon

[scripts/generate-icon.swift](scripts/generate-icon.swift) *is* the icon source. There is no
binary design file and no downloaded art anywhere in the repository: every shape is a Core
Graphics path with numbers that show up in a diff, and the whole set — 1024 px master, the
`.iconset`, and light/dark contact sheets at 16/32/128/256/512/1024 px — regenerates from one
command. `iconutil` turns the iconset into `Resources/AppIcon/TriCap.icns`.

The mark is a viewfinder: four corner brackets around an open centre, on a deep-navy-to-azure
vertical gradient, with a single small coral shutter dot at the optical centre — the one warm
colour, and what makes it read as a camera rather than a crop tool. Below 32 px the stroke
thickens, the brackets move slightly outward and the dot grows, because a proportional hairline
disappears at 16 px; pushed much further out the brackets crowd the rounded corner and read as a
broken second outline, so the small-size geometry is a deliberate compromise rather than a scale.

`build-app.sh` copies the `.icns` into `Contents/Resources` **before** `codesign`, or the signature
would cover a bundle that does not contain it. The full-colour icon is for Finder, Get Info and
System Settings only — the menu-bar item stays a monochrome SF Symbol template so it tints with
the menu bar and inverts correctly in dark mode.
