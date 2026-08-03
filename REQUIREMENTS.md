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
| M2 | `Esc` cancels | `SelectionOverlayView.keyDown`/`cancelOperation`; a **system-wide** Carbon Escape hot key during recording and while a pin is open, shared through `PriorityHotKeyClaim` ([RecordingChromeController.swift](Sources/TriCapApp/RecordingChromeController.swift), `PinboardController`); `.cancelAction` in the editor | selftest (hot-key slots) · *Shared Escape stack* · manual |
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

## Usability and quality round

| # | UX problem | Fix | Verified by |
|---|---|---|---|
| P0-1 | A menu-bar app with no Dock icon is invisible on first launch; nothing explains the icon, the shortcut or the permission | [WelcomeView.swift](Sources/TriCapApp/WelcomeView.swift), shown once via `SettingsStore.hasSeenWelcome`, reopenable from the menu and About | snapshot 09 · launch check (flag flips) |
| P0-2 | A Quality control was shown for PNG, which ignores it | `OutputFormat.usesQualityParameter`; the Advanced section shows *Lossless — no setting* | *Quality parameter reality check* (3), *Format-conditional quality controls* (4) · snapshot 08 |
| P0-3 | After saving, nothing said where the file went or what was copied | [ExportSummary.swift](Sources/ExportCore/ExportSummary.swift) + [ExportToast.swift](Sources/TriCapApp/ExportToast.swift), with **Show in Finder** | *Export summary wording* (8) · snapshot 10 |
| P0-4 | The menu bar was identical whether or not TriCap could actually capture | `AppDelegate.buildMenu` shows permission state, a fix action, and *Capture in progress…* | manual (§4) |
| P0-5 | The overlay's mode hint vanished on mouse-down and never said what release would do | Persistent mode banner, corner brackets, *Release to capture* / *Release to start recording* | snapshots 04, 11 |
| P1-6 | Quality was raw encoder parameters with no result-oriented choice | [QualityPreset.swift](Sources/TriCapKit/QualityPreset.swift) — four presets, Custom as a state, plain-language size guidance | *Quality presets* (6), *Quality preset ↔ encoder parameters* (6), *Settings migration* (5) |
| P1-7 | The recording HUD had no cancel affordance and no sense of the limit | Progress bar toward `maxDuration`, an explicit cancel/stop line, countdown caption (the wording was corrected in round 4 — see below) | snapshots 05, 12 |
| P1-8 | Tool glyphs were unlabelled with no shortcuts | Named active tool, `⌘1`–`⌘5`, purpose-first tooltips | *Annotation tool affordances* (3) · snapshots 02, 03 |
| P1-9 | Settings mixed limits with quality and always showed every parameter | Four tabs; Quality gets preset → format → advanced | snapshots 01, 08 |
| P1-10 | The editor never showed where the file would go | `Saves to …` line, plus **Show in Finder** after saving | snapshots 02, 03 |

Also fixed while testing the migration: `RecordingLimits` and `AnimatedWebPOptions` decoded
straight into their stored properties, bypassing their own clamping initializers, so a corrupt or
future settings blob could load a 999 fps / 99999 px configuration. Both now decode through the
clamping initializer (*Settings migration* → "An out-of-range legacy value is clamped").

## Round 4 — Codex acceptance fixes

| # | Finding | Fix | Verified by |
|---|---|---|---|
| 1 | `SettingsStore`'s nested normalising write made `onChange` report `proposal → normalised`, so an edit to legacy settings that also relabelled the preset hid the hot-key change and the shortcut was never re-registered | `AppSettings.resolveUpdate` pairs the normalised value with the *real* previous one; the store suppresses its own re-entrant `didSet` — one normalisation, one persist, one notification | *Settings update resolution* (7), incl. "legacy matching preset + first hot-key edit" |
| 2 | The HUD promised "Return stops", but it is a borderless never-key panel and no global Return was ever registered | Wording is now `Esc cancels · Click Stop to finish`; the unreachable `keyEquivalent` is removed | snapshot 05 |
| 3 | The countdown claimed Esc worked from other apps but used a *local* `NSEvent` monitor; the global key was only claimed once recording began | `TransientHotKeyClaim` is claimed before the first tick and rebound — not re-registered — when the recording takes over; released on every exit path | *Transient hot key claim* (10) · selftest hand-off checks |
| 4 | `ExportSummary.detailDescription` was computed and tested but never rendered | The toast shows it for stills and clips; the panel is sized from its content so a wrapping warning is not clipped | *Export summary wording* (+3) · snapshots 10, 13 |
| 5 | `.maximum` promised "no downscaling / highest quality" while capping at 3840 px / 20 fps / 95; WebP and file-size copy stated unmeasured figures; `hasSeenWelcome` comment was inverted | Renamed *Up to 4K* with a summary quoting the real cap; format and size copy made conditional; comment corrected | *Quality presets* (+2, incl. a test that fails on any digit in format copy) |

Also fixed while renaming the preset: an unrecognised enum raw value made `decodeIfPresent`
**throw**, and `SettingsStore` reads settings with `try?` — so one renamed case would have silently
discarded the user's entire settings blob. Enum fields now decode tolerantly
(*Settings migration* → unknown preset / unknown format).

## Round 5 — pinning, window-aware selection, clipboard-first, app icon

| # | Requirement | Implementation | Verified by |
|---|---|---|---|
| N1 | An independent global **pin** shortcut, default bare `F3`, registered/migrated/rolled back separately from the screenshot shortcut | `AppSettings.pinHotKey`, `GlobalHotKeyMonitor.Slot.pinFromClipboard`, `AppDelegate.registerPinHotKey` | *Bare-key allow list* (6), *Independent shortcut registration* (3), *Pin shortcut migration* (5) · selftest §pin hot key |
| N2 | Modifier-less binding restricted to explicit function keys — never letters or digits | `HotKeyCombo.bareKeyAllowList` (F1–F20), `isValid` | *Bare-key allow list* — refuses A, 5, Space, Return, Delete, Escape |
| N3 | A failed `F3` registration (Mission Control) is reported and re-bindable — never silently substituted | `AppDelegate.pinShortcutUnavailableMessage`, `HotKeyRegistrationPolicy` rollback | *Independent shortcut registration* · selftest reports which branch this machine takes |
| N4 | Read PNG / TIFF / system image objects from the pasteboard; every press makes an independent pin | [PasteboardImage.swift](Sources/ExportCore/PasteboardImage.swift), `PinboardController.pinFromClipboard` | *Pasteboard image policy* (9) · selftest §pin windows |
| N5 | Nothing on the clipboard creates no window, only a notice | `PinOutcome.nothingToPin`, `ExportToast.showNotice` | selftest (empty and text-only clipboards) |
| N6 | Count / pixel / memory ceilings on pins | `PinLimits` (12 pins, 120 MP total, 40 MP each) | *Pin memory limits* (7) · selftest (ceiling refuses the third pin) |
| N7 | Borderless, never takes keyboard focus, above ordinary windows but below system security UI, all Spaces + full-screen | [PinWindow.swift](Sources/TriCapApp/PinWindow.swift) — `.floating`, `canBecomeKey == false`, `.nonactivatingPanel`, `orderFrontRegardless()` | selftest asserts level, key-window and collection behaviour on real windows |
| N8 | A pin fits its display and can never be dragged irretrievably off-screen | `PinPlacement.initialFrame` / `clampReachable` / `clampFullyOnScreen` | *Pin placement* (7) |
| N9 | Drag, pointer-anchored scroll/pinch zoom with limits, adjustable opacity, context menu, `Esc` closes, menu closes all | `PinContentView`, `PinZoom`, `PinOpacity`, `PinWindow.makeContextMenu` | *Pin zoom* (5), *Pin opacity* (2) · selftest |
| N10 | Teardown releases window, bitmap and hot-key claim, and is idempotent | `PinWindow.tearDown()`, `PinboardController.close`/`closeAll` | selftest asserts the bitmap and content view are released, and that closing twice is harmless |
| N11 | `Esc` is shared between recording-cancel and pin-dismiss without either losing it | [PriorityHotKeyClaim.swift](Sources/TriCapKit/PriorityHotKeyClaim.swift) + `SharedEscapeKey` — one registration, a stack of handlers | *Shared Escape stack* (8) |
| N12 | Hovering highlights the topmost valid window; a click captures it | `WindowPicker`, [WindowSurvey.swift](Sources/CaptureCore/WindowSurvey.swift), `SelectionOverlayView.drawWindowHighlight` | *Window picking* (10) · snapshot 14 |
| N13 | Free drag still works; a click becomes a drag past a threshold, and never reverts | `SelectionGesture` (6 pt, radial, sticky) | *Click versus drag* (4) |
| N14 | Edges snap within ~8 pt of window and display edges; Option disables it | `SnapEngine` (per-axis, refuses degenerate snaps) | *Edge snapping* (9) |
| N15 | Exclude TriCap itself, off-screen/minimised, zero-size and system decoration layers; handle overlap, multi-display, negative coordinates, mixed scale factors | `WindowPicker.isSelectable` / `window(at:in:)`, `CoordinateConverter.appKitRect` | *Window picking* — self, off-screen, level > 0, tiny, negative coordinates, stacking order |
| N16 | A still capture goes to the clipboard by default: no editor, no file | `StillCaptureAction.copyToClipboard`, `AppDelegate.captureStill(region:forceEditor:)` | *Screenshot post-capture action* (2) · manual |
| N17 | The clipboard write offers `public.png` plus a system image, and only reports success if it happened | `PasteboardImage.write` returns `nil` when the pasteboard refuses everything; `WriteReceipt.wroteRasterData` | *Pasteboard image policy* |
| N18 | A clipboard failure is recoverable, not silent | `AppDelegate.presentClipboardFailure` offers the editor instead | manual |
| N19 | Settings shows both shortcuts separately and a post-screenshot choice; the menu keeps *Screenshot and Edit…*, *Pin from Clipboard*, *Close All Pins* | [SettingsView.swift](Sources/TriCapApp/SettingsView.swift), `AppDelegate.buildMenu` | snapshot 01 · manual |
| N20 | Original app icon: deep→bright blue viewfinder, small coral shutter dot, no text or third-party art, legible small | [scripts/generate-icon.swift](scripts/generate-icon.swift) — Core Graphics paths, *is* the source | `iconutil`/`sips`/`plutil` checks in REVIEW_HANDOFF.md · light and dark contact sheets |
| N21 | 1024 master, full `.iconset`, `.icns`, light/dark check sheets, `CFBundleIconFile`, copied in before `codesign`; menu bar stays monochrome | `Resources/AppIcon/`, [Info.plist](Resources/Info.plist), [build-app.sh](scripts/build-app.sh) | `codesign --verify` · `NSWorkspace.icon(forFile:)` probe · snapshot 06 (menu bar still a template) |

## Deliverables

| Deliverable | Location |
|---|---|
| Buildable, runnable Swift/AppKit/SwiftUI project | this repository; `./scripts/build-app.sh` |
| README (features, build, run, permission, usage, limits) | [README.md](README.md) |
| Architecture / requirements docs | [ARCHITECTURE.md](ARCHITECTURE.md), this file |
| libwebp licence and integration notes | [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md), [docs/LIBWEBP.md](docs/LIBWEBP.md) |
| Automated tests | `Tests/TriCapTests/` (339), `./scripts/test.sh` |
| App icon source and outputs | [scripts/generate-icon.swift](scripts/generate-icon.swift), `Resources/AppIcon/` |
| Review handoff | [REVIEW_HANDOFF.md](REVIEW_HANDOFF.md) |
