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
| `CaptureCore` | Permission state, ScreenCaptureKit configuration, `StillCaptureService`, `RegionRecorder`, the bounded `FrameBuffer`, clip trimming and WebP timeline construction. |
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

- `SCStreamConfiguration.colorSpaceName` is pinned to sRGB for both capture paths.
- `ImageProcessing.normalizedToSRGB` re-renders every capture into that layout and reports what
  the source space was and whether a conversion happened.
- A wide-gamut or HDR source (`Display P3`, `Rec. 2020`, PQ/HLG, extended sRGB…) is detected by
  name and surfaced to the user in the editor: *"colours outside sRGB have been mapped into gamut
  and HDR highlights are clipped."* The conversion is not silent.
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
5. Export pulls frames back **one at a time** through `AnimationFrameSource.loadFrame`, so peak
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

`OutputFileWriter` writes to a temp file in the destination directory, then claims the final name
with `link(2)`, which fails atomically with `EEXIST`. A `fileExists` check followed by a write
would have a race window; two TriCap exports in the same second cannot clobber each other. Names
go `base.ext`, `base-1.ext`, … up to 1000, then one random-token fallback.

## Hot key

`RegisterEventHotKey` (Carbon) rather than an `NSEvent` global monitor: a global monitor needs
Accessibility permission — a second, scarier TCC prompt on top of Screen Recording — and cannot
stop the key reaching the focused app. Carbon's hot-key API remains the only public way to claim a
system-wide combination without that permission. A combination with no modifiers is refused
outright; a combination another app already owns is reported instead of silently going dead.

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
