# TriCap

A native macOS menu-bar tool for region screenshots and short animated-WebP clips. Everything
happens on your Mac: no network code, no telemetry, no cloud sync, no account.

---

## What it does

- **First launch** shows a short Getting Started window: where the menu-bar icon is, how to grant
  Screen Recording, and what the shortcut is. Reopen it any time from the menu or Settings → About.
- **Global shortcut** (default `⌥⇧5`) opens a full-screen region picker across every display.
- In the picker: drag to capture a **screenshot**, press **R** to switch to **recording** mode
  (**S** switches back), **Esc** cancels.
- **Esc** cancels from anywhere, throughout the countdown *and* the recording — TriCap claims a
  system-wide Escape for that span only and releases it the moment the recording ends. The HUD's
  **Stop** button is a click; there is no global stop key.
- Recording gets an optional **countdown**, a floating **stop** control with live elapsed time and
  frame count, and **head/tail trimming** in the editor.
- **Annotate** with arrow, rectangle, text, freehand pen and mosaic — with undo/redo. For a clip
  the annotations become a **fixed overlay composited onto every frame**.
- **Export** PNG, JPEG, static WebP, or Animated WebP.
- **Copy a reference** to the clipboard: a *relative* Markdown/Obsidian image reference when the
  file lands inside your configured vault root, otherwise the absolute file path.
- **After saving**, a confirmation tells you the file name, the folder, the size, and exactly what
  went on the clipboard — with a **Show in Finder** button.

Animated-WebP defaults: **12 fps, ≤ 15 s, long edge ≤ 1440 px, quality 80, loops forever, no audio.**

---

## Requirements

| | |
|---|---|
| macOS | 14.0 or later (developed and verified on macOS 26.5.2, Apple silicon) |
| Toolchain | Swift 6.0+ — **Xcode is not required**, Command Line Tools are enough |
| Dependencies | none at runtime; libwebp is compiled into the binary |

TriCap uses only public Apple APIs: ScreenCaptureKit, AppKit/SwiftUI, Core Graphics, Core Text,
ImageIO, and Carbon's `RegisterEventHotKey`. It does not touch the system screenshot app or any
private interface.

---

## Build and run

```bash
./scripts/build-app.sh debug
```

That produces `build/debug/TriCap.app`. For an optimised build:

```bash
./scripts/build-app.sh release
```

Then launch it:

```bash
open build/release/TriCap.app
```

TriCap has no Dock icon — look for the viewfinder icon in the menu bar.

> **Why a script instead of `xcodebuild`?** This project is a SwiftPM package, because the machine
> it was written on has Command Line Tools but no `Xcode.app` (so `xcodebuild` is unavailable).
> SwiftPM emits a bare executable; a menu-bar app needs a bundle with an `Info.plist` for
> `LSUIElement` and for the bundle identifier that TCC keys screen-recording permission on.
> `scripts/build-app.sh` does exactly that packaging step and nothing else.

### Tests

```bash
./scripts/test.sh
```

198 tests. The wrapper exists because SwiftPM does not put the Command Line Tools copy of
`Testing.framework` on the search path unless Xcode is the active developer directory; the script
adds the `-F` and `-rpath` flags that make `swift test` work with CLT only. With Xcode installed,
plain `swift test` also works.

### End-to-end self-test

```bash
./scripts/build-app.sh debug
caffeinate -dimsu .build/debug/TriCap --selftest ./build/selftest
```

`caffeinate -dimsu` keeps the display awake: if the screen sleeps mid-run, ScreenCaptureKit serves
a frozen composite and every recording collapses to one frame. The self-test detects that state
and reports the affected expectations as **SKIP** rather than PASS or FAIL.

Drives the real pipeline — permission, ScreenCaptureKit still capture, annotation compositing,
PNG/JPEG/WebP encoding, a 5-second recording, trimming, animated-WebP encoding — and re-reads
every file it writes. Prints `ALL CHECKS PASSED` or names the failing check. **It captures a real
region of your screen** into `build/selftest/`, which is git-ignored.

### UI snapshots

```bash
.build/debug/TriCap --render-ui-snapshots ./build/ui-snapshots
```

Renders the real settings tabs, the Getting Started window, the editor (still, clip and
single-frame clip), both selection-overlay modes, the recording HUD and countdown, the post-export
confirmation, and the status-item icon offscreen to PNG. Useful for eyeballing the interface
without a screen-recording tool.

---

## Permission

TriCap needs **Screen & System Audio Recording**. macOS asks once, the first time you capture.

- If you decline, macOS will **not ask again** — you have to enable TriCap under
  *System Settings → Privacy & Security → Screen & System Audio Recording* and relaunch it.
  TriCap detects this state and offers a button that opens the pane directly.
- Newly granted permission does not always apply to an already-running process, so TriCap tells
  you to relaunch when the switch is on but capture still fails.
- No other permission is requested. TriCap never records audio and has no microphone, camera,
  location or network entitlement.

**Ad-hoc signing caveat.** `build-app.sh` signs the bundle ad-hoc by default, so its TCC identity
is the code-directory hash, which changes on every rebuild — macOS then treats each build as a
different app and asks for permission again. Set `CODESIGN_IDENTITY` to a stable Developer ID
identity to avoid that. This repository does not sign, notarize or publish.

---

## Using it

1. Press `⌥⇧5` (or pick **Capture Region…** / **Record Region…** from the menu).
2. Drag out a region. The readout shows the exact pixel size. `R`/`S` toggle screenshot vs
   recording; `Esc` cancels.
3. For a recording: the countdown runs, then record. Click **Stop** to finish, or press `Esc` —
   from any app — to abandon it, during the countdown or during the recording.
4. Annotate. `⌘Z` / `⇧⌘Z` undo and redo. For a clip, drag the **Start**/**End** handles to trim
   and the **Frame** handle to scrub.
5. **Save**. The file lands in your save folder and the reference goes to the clipboard.

### Settings

- **General** — global shortcut (click and press keys), recording countdown, permission status.
- **Quality** — a named quality preset, the screenshot format, and an *Advanced* section with the
  real encoder parameters. See [Quality](#quality) below.
- **Output** — save folder, Markdown/Obsidian vault root, reference style (`![](path)` or
  `![[path]]`), filename prefix, clipboard behaviour.
- **About** — what TriCap is, and a way back to Getting Started.

---

## Quality

Most people should pick a preset and never look further:

| Preset | Screenshot quality | Recording longest edge | Recording frame rate | Animation quality |
|---|---|---|---|---|
| Smaller file | 65 | 960 px | 10 fps | 60 |
| **Balanced** (default) | 85 | 1440 px | 12 fps | 80 |
| Sharper | 95 | 1920 px | 15 fps | 90 |
| Up to 4K | 100 | 3840 px | 20 fps | 95 |

Every number is a real encoder argument, not a label — `QualityPresetTests` asserts the mapping.

*Up to 4K* is a ceiling, not "original size": it caps the long edge at 3840 px, which is still a
downscale on a larger display, and it deliberately stops short of the 30 fps and quality-100
ceilings — those multiply what a recording holds in memory for a difference few people would see.

**What drives file size.** For a recording, resolution and frame rate usually matter more than the
quality factor: fewer pixels and fewer frames means less to encode at all, while the quality factor
only changes how hard each frame is squeezed. How much more depends entirely on what is on screen
— a mostly-still window behaves very differently from playing video — so TriCap does not quote a
ratio it has not measured.

**PNG has no quality setting** and TriCap does not pretend otherwise. PNG is lossless: the encoder
takes no quality argument, so the Advanced section shows *Lossless — no setting* for PNG and a
stepper for JPEG, WebP and Animated WebP. (`QualityParameterRealityTests` encodes the same image
at quality 1 and 100 and asserts PNG's bytes are identical while the lossy formats' are not.)

**Your own values are never overwritten.** Editing anything in Advanced switches the preset to
**Custom** and keeps your numbers. Settings written by a build that had no presets load as Custom
with every value preserved — TriCap will not silently change the quality you were already getting.
Picking a preset is the only thing that writes those values.

### The clipboard reference

If the exported file is inside the configured vault root you get a relative reference:

```markdown
![clip](assets/clip.webp)
```

If it is anywhere else you get the plain absolute path, because a relative link would be a lie.
Containment is checked component-wise on symlink-resolved paths — so `/tmp` and `/private/tmp`
agree and `/Vault` does not swallow `/VaultBackup` — and names are compared using the *volume's own*
case rule, because on a case-sensitive volume `Vault/` and `vault/` really are different folders.
If a network volume cannot report that rule, TriCap conservatively uses an absolute path rather
than risk copying a relative reference that will not resolve.

---

## Design notes worth knowing

**Coordinate spaces.** Four of them, converted in exactly one file
([Coordinates.swift](Sources/TriCapKit/Coordinates.swift)): AppKit global points (bottom-left
origin, +y up), Quartz global points (top-left, +y down), display-local points, and display
pixels. A fifth — capture pixels — differs from display pixels only when the long-edge cap
downscales a recording; `CaptureRegion` carries both so they cannot be confused. Selections snap
*outward* to whole pixels and are clamped to the display.

**Colour.** Everything renders and exports as 8-bit **sRGB**, opaque, `R G B X`. Capture first
uses the source display's public colour profile and records whether the screen is wide-gamut or
extended-range; only then does TriCap convert to sRGB. P3/HDR downscaling preserves that provenance,
and the editor surfaces the conversion instead of silently discarding it.

**Memory.** A recording is bounded three ways: frame count (`fps × duration + 1`), a byte ceiling
on the retained frame buffer (512 MB by default), and the long-edge cap on each frame. Frames are
held PNG-compressed, and the animated encoder pulls them back one at a time, so peak usage is one
decoded frame rather than the whole clip.

**Static screens.** ScreenCaptureKit only sends a frame when the picture changed, so TriCap
measures a recording's length with a monotonic clock rather than from frame timestamps. A
recording of one second of motion followed by fourteen static seconds is a fifteen-second
animation whose last frame holds for fourteen seconds — and the duration limit still stops it on
time even if nothing ever moves.

**Animated-WebP frame coalescing.** libwebp merges a frame identical to its predecessor into that
frame's duration. The stored frame count is therefore often *lower* than the number submitted —
this is correct and shrinks the file without changing playback. If *nothing* moved for the whole
recording, libwebp drops the animation chunk entirely and writes a single-frame still WebP;
TriCap keeps that file and tells you nothing moved.

---

## Not implemented (deliberately)

OCR, scrolling capture, automatic sensitive-information detection, audio, cloud sync, GIF / APNG /
WebM, a full capture history library, and App Store distribution.

---

## Licensing

TriCap bundles [libwebp](https://chromium.googlesource.com/webm/libwebp) 1.6.0 (BSD-3-Clause) —
see [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md) and [docs/LIBWEBP.md](docs/LIBWEBP.md).

## Further reading

- [ARCHITECTURE.md](ARCHITECTURE.md) — module layout and the decisions behind it
- [REQUIREMENTS.md](REQUIREMENTS.md) — what was specified and where it is implemented
- [REVIEW_HANDOFF.md](REVIEW_HANDOFF.md) — verification commands, results, and what is *not* verified
