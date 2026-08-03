# TriCap requirements → implementation

Every row is a requirement from the brief, where it lives, and how it is verified.
`selftest` = a check in `TriCap --selftest`; `tests` = `./scripts/test.sh`; `snapshot` = a
rendered image in `build/ui-snapshots/`; `manual` = needs a human (listed in REVIEW_HANDOFF.md).

## Goals

| # | Requirement | Implementation | Verified by |
|---|---|---|---|
| G1 | Global shortcut enters region screenshot or short clip recording | [GlobalHotKey.swift](Sources/TriCapApp/GlobalHotKey.swift), [AppDelegate.swift](Sources/TriCapApp/AppDelegate.swift), [RegionSelector.swift](Sources/SelectionUI/RegionSelector.swift) | manual · log line `registered hot key ⌥⇧5` |
| G2 | Lightweight annotation UI after capture/recording | [EditorView.swift](Sources/TriCapApp/EditorView.swift), [AnnotationCanvasView.swift](Sources/TriCapApp/AnnotationCanvasView.swift) | snapshot 02, 03 |
| G3 | Export PNG, JPEG, static WebP, animated WebP | [StillImageCodec.swift](Sources/ExportCore/StillImageCodec.swift), [WebPCodec.swift](Sources/ExportCore/WebPCodec.swift) | tests · selftest |
| G4 | Save file and copy a Markdown/Obsidian-usable reference | [MarkdownReference.swift](Sources/ExportCore/MarkdownReference.swift), `AppDelegate.handleExport` | tests · selftest |
| G5 | Entirely local: no upload, no telemetry | no network API anywhere; `TriCapLog` writes to the unified log only | `grep` audit in REVIEW_HANDOFF.md |

## MVP functionality

| # | Requirement | Implementation | Verified by |
|---|---|---|---|
| M1 | Default shortcut `⌥⇧5`, changeable in settings | `HotKeyCombo.default`, `HotKeyRecorder` in [SettingsView.swift](Sources/TriCapApp/SettingsView.swift) | snapshot 01 · manual |
| M2 | `Esc` cancels | `SelectionOverlayView.keyDown`/`cancelOperation`; a **system-wide** Carbon Escape hot key during recording ([RecordingChromeController.swift](Sources/TriCapApp/RecordingChromeController.swift)); `.cancelAction` in the editor | selftest (hot-key slots) · manual |
| M3 | Region screenshot | [StillCaptureService.swift](Sources/CaptureCore/StillCaptureService.swift) | selftest |
| M4 | Region short recording | [RegionRecorder.swift](Sources/CaptureCore/RegionRecorder.swift) | selftest |
| M5 | Recording countdown | `RecordingHUD.runCountdown` | manual |
| M6 | Stop control | `RecordingHUD.showRecordingHUD` | snapshot 05 · manual |
| M7 | Head/tail trimming | `ClipTrimmer` in [ClipEditing.swift](Sources/CaptureCore/ClipEditing.swift); Start/End sliders | tests · selftest · snapshots 03, 07 |
| M8 | Arrow, rectangle, text, freehand, mosaic | [AnnotationRenderer.swift](Sources/AnnotationCore/AnnotationRenderer.swift) | tests · snapshot 02 |
| M9 | Undo / redo | [AnnotationDocument.swift](Sources/AnnotationCore/AnnotationDocument.swift) | tests (14 cases) |
| M10 | Clip annotations are a fixed overlay on all frames | `ExportService.encodeStreaming` composites the same item list per frame | tests · selftest (per-frame pixel probe) |
| M11 | Animated WebP defaults: 12 fps, ≤15 s, long edge ≤1440 px, quality 80, infinite loop, no audio | `RecordingLimits()`, `AnimatedWebPOptions()`, `config.capturesAudio = false` | tests · selftest · browser check |
| M12 | Configurable save directory and optional vault root | [AppSettings.swift](Sources/TriCapKit/AppSettings.swift), Output tab | snapshot 01 · selftest |
| M13 | Relative Markdown reference inside the root, file path otherwise | `MarkdownReference.reference` | tests (13 cases) · selftest |
| M14 | Handle filename conflicts, cancel, encode failure, disk-write failure | `OutputFileWriter` (three atomic claim strategies), `RecordingSession` latched cancel, `TriCapError`, `ExportService` cleanup | tests · selftest |

## Hard constraints

| # | Constraint | How it is met | Verified by |
|---|---|---|---|
| C1 | No private interfaces of the system screenshot app | Only ScreenCaptureKit / AppKit / SwiftUI / Core Graphics / Core Text / ImageIO / Carbon `RegisterEventHotKey` | symbol audit in REVIEW_HANDOFF.md |
| C2 | Correctly handle screen-recording permission not-determined / denied / re-granted | [ScreenRecordingPermission.swift](Sources/CaptureCore/ScreenRecordingPermission.swift) + three distinct alerts | tests · selftest reports live state · manual for the prompt itself |
| C3 | Distinguish AppKit point / display pixel / capture pixel / Retina scale | [Coordinates.swift](Sources/TriCapKit/Coordinates.swift), [CaptureRegion.swift](Sources/TriCapKit/CaptureRegion.swift) | tests (25 cases) · selftest |
| C4 | Predictable sRGB output; no silent HDR conversion | SCK `colorSpaceName` left unset so output uses the display-native profile; source wide/EDR metadata in `DisplayGeometry`; profile-preserving downscale; explicit `ImageProcessing.normalizedToSRGB` + `ColorSpaceOutcome.userFacingNotice` | colour-provenance tests · selftest asserts final capture is sRGB |
| C5 | Ceilings on duration, frame rate, size, frame buffer and memory | `RecordingLimits`, `FrameBuffer`, `queueDepth`, streaming export, **monotonic wall-clock duration ceiling** in `RegionRecorder.tick()` | tests · selftest (static-screen section) |
| C6 | Re-read the working directory before starting | done first; the directory was empty and not a git repo | session log |
| C7 | `git init` is fine; no push / release / signing / notarization | repo initialised, no remote, ad-hoc signature only | `git remote -v` is empty |
| C8 | Out of scope: OCR, scrolling capture, sensitive-info detection, audio, cloud sync, GIF/APNG/WebM, full history library, App Store | none implemented | — |
| C9 | If a public API or libwebp integration blocks, keep evidence — do not use private APIs | nothing was blocked; libwebp vendored from source | — |

## Review rounds 2–3 — fixes

Raised by Codex against `83a8c12`, then independently re-reviewed against `f521ac6`.

| # | Issue | Fix | Verified by |
|---|---|---|---|
| A1 | `isCapturing` released once the HUD appeared, so a repeated trigger overwrote the live recorder, HUD, stop target and cancel key | [RecordingSession.swift](Sources/CaptureCore/RecordingSession.swift) (`RecordingSession`, `CaptureSessionGate`), [AppDelegate.swift](Sources/TriCapApp/AppDelegate.swift) `beginCapture`/`recordClip` now await full teardown; per-instance `HUDStopProxy` replaces the singleton | *Recording session lifecycle* (10), *Capture session gate* (5) |
| A2 | Duration ceiling was checked only when a frame arrived, so a static screen recorded past the limit indefinitely and the static tail was lost | Monotonic `ContinuousClock` tick in `RegionRecorder`, latched once; `RecordedClip.wallClockDuration`; `ClipTrimmer.trimmedDuration`; `ClipTiming.timeline(totalDuration:)` | *Trimmed duration semantics* (8), *Recorded clip duration* (4), *Animated WebP timeline* (10) · selftest §static-screen |
| A3 | `finish()` originally lost colour state; its first fix still allowed an in-flight callback to append after stop/cancel | `StreamOutput.commit` shares a lock with `stopAccepting`; teardown removes output, stops capture, drains `sampleQueue`, then snapshots colour/first-frame state | *Colour space propagation* (9), *Recording stream commit barrier* (2) · selftest |
| A4 | `window → model → onClosed → window` retain cycle leaked every editor and its frames | [EditorPresenter.swift](Sources/TriCapApp/EditorPresenter.swift) with a weak window box | selftest §editor window lifecycle (weak-reference assertions) |
| A5 | Recording `Esc` used a *local* monitor, so it stopped working the moment the user focused the app being recorded | Carbon bare-Escape hot key in a dedicated slot, claimed only while recording ([GlobalHotKey.swift](Sources/TriCapApp/GlobalHotKey.swift), `RecordingChromeController`) | selftest §recording-cancel hot key (8) |
| B6 | A rejected new shortcut left no working shortcut | [HotKeyRegistrationPolicy.swift](Sources/TriCapKit/HotKeyRegistrationPolicy.swift) rolls back and reverts the setting | *Hot key registration roll-back* (6) |
| B7 | Containment was unconditionally case-insensitive; the first fix defaulted unknown volumes back to insensitive | `MarkdownReference.CaseSensitivity` from `volumeSupportsCaseSensitiveNamesKey`, with conservative `.sensitive` fallback and a pure comparison function | *Markdown containment case sensitivity* (6) |
| B8 | `link(2)` failure on exFAT/SMB failed the whole write; the first `O_EXCL` fallback ignored delayed `fsync`/`close` failures | `renamex_np(RENAME_EXCL)` then `open(O_CREAT\|O_EXCL)` fallbacks; final claim is removed and failure returned when flush or close fails | *Output file claim strategies* (13, including injected delayed-I/O errors) |
| B9 | HUD Stop button was dark-on-dark | `.darkAqua` appearance on the HUD content view | snapshot 05 |
| B10 | A one-frame clip's sliders exposed index 1 | `ClipTrimUI` + the editor hides the sliders entirely | *Clip trim slider ranges* (4) · snapshot 07 |

## Deliverables

| Deliverable | Location |
|---|---|
| Buildable, runnable Swift/AppKit/SwiftUI project | this repository; `./scripts/build-app.sh` |
| README (features, build, run, permission, usage, limits) | [README.md](README.md) |
| Architecture / requirements docs | [ARCHITECTURE.md](ARCHITECTURE.md), this file |
| libwebp licence and integration notes | [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md), [docs/LIBWEBP.md](docs/LIBWEBP.md) |
| Automated tests | `Tests/TriCapTests/` (198), `./scripts/test.sh` |
| Review handoff | [REVIEW_HANDOFF.md](REVIEW_HANDOFF.md) |
