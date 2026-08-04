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
| N9 | Drag, pointer-anchored scroll/pinch zoom with limits, adjustable opacity, context menu, `Esc` closes the pin the user last touched, menu closes all | `PinContentView`, `PinZoom`, `PinOpacity`, `PinWindow.makeContextMenu`, `PinFocusOrder` | *Pin zoom* (5), *Pin opacity* (2), *Pin focus order* (10) · selftest |
| N10 | Teardown releases window, bitmap and hot-key claim, and is idempotent | `PinWindow.tearDown()`, `PinboardController.close`/`closeAll` | selftest asserts the bitmap and content view are released, and that closing twice is harmless |
| N11 | `Esc` is shared between recording-cancel and pin-dismiss without either losing it | [PriorityHotKeyClaim.swift](Sources/TriCapKit/PriorityHotKeyClaim.swift) + `SharedEscapeKey` — one registration, handlers arbitrated by explicit priority (recording outranks pinning in either order) | *Shared Escape stack* (14) |
| N12 | Hovering highlights the topmost valid window; a click captures it | `WindowPicker`, [WindowSurvey.swift](Sources/CaptureCore/WindowSurvey.swift), `SelectionOverlayView.drawWindowHighlight` | *Window picking* (10) · snapshot 14 |
| N13 | Free drag still works; a click becomes a drag past a threshold, and never reverts | `SelectionGesture` (6 pt, radial, sticky) | *Click versus drag* (4) |
| N14 | Edges snap within ~8 pt of window and display edges; Option disables it | `SnapEngine` (per-axis, refuses degenerate snaps) | *Edge snapping* (9) |
| N15 | Exclude TriCap itself, off-screen/minimised, zero-size and system decoration layers; handle overlap, multi-display, negative coordinates, mixed scale factors | `WindowPicker.isSelectable` (layer 0 only) / `window(at:in:)` / `snapEdges`, `CoordinateConverter.appKitRect` | *Window picking* — self, off-screen, level ≠ 0 either side, tiny, negative coordinates, stacking order; *Snap edges* |
| N16 | A still capture goes to the clipboard by default: no editor, no file | `StillCaptureAction.copyToClipboard`, `AppDelegate.captureStill(region:forceEditor:)` | *Screenshot post-capture action* (2) · manual |
| N17 | The clipboard write offers `public.png` plus a system image, and only reports success if it happened | `PasteboardImage.write` returns `nil` when the pasteboard refuses everything; `WriteReceipt.wroteRasterData` | *Pasteboard image policy* |
| N18 | A clipboard failure is recoverable, not silent | `AppDelegate.presentClipboardFailure` offers the editor instead | manual |
| N19 | Settings shows both shortcuts separately and a post-screenshot choice; the menu keeps *Screenshot and Edit…*, *Pin from Clipboard*, *Close All Pins* | [SettingsView.swift](Sources/TriCapApp/SettingsView.swift), `AppDelegate.buildMenu` | snapshot 01 · manual |
| N20 | Original app icon: deep→bright blue viewfinder, small coral shutter dot, no text or third-party art, legible small | [scripts/generate-icon.swift](scripts/generate-icon.swift) — Core Graphics paths, *is* the source | `iconutil`/`sips`/`plutil` checks in REVIEW_HANDOFF.md · light and dark contact sheets |
| N21 | 1024 master, full `.iconset`, `.icns`, light/dark check sheets, `CFBundleIconFile`, copied in before `codesign`; menu bar stays monochrome | `Resources/AppIcon/`, [Info.plist](Resources/Info.plist), [build-app.sh](scripts/build-app.sh) | `codesign --verify` · `NSWorkspace.icon(forFile:)` probe · snapshot 06 (menu bar still a template) |

## Round 5 — Codex acceptance fixes

| # | Finding | Fix | Verified by |
|---|---|---|---|
| 1 | `PriorityHotKeyClaim` fired the *most recent* claim, so a pin created **during** a recording took Escape and cancellation stopped working. Passing only depended on call order. | An explicit `Priority` (`.recording` > `.pin`); the active handler is the highest priority, most recent within a priority. A lower-priority claim is still registered and takes over automatically on release. | *Shared Escape stack* (14, incl. both orderings, no-preemption, restore-after-release, out-of-order and idempotent release) · selftest §Escape priority against the real Carbon claim |
| 2 | `closeFrontmost` derived order from `NSApp.windows.firstIndex`, which keeps creation order — so Escape closed the **oldest** pin, and clicking a pin changed nothing. | [PinFocusOrder](Sources/TriCapKit/PinGeometry.swift) maintained by TriCap: newest pin in front, `pinDidInteract` (mouse-down, scroll, magnify, right-click) brings a pin forward, `remove` falls back to the one behind. | *Pin focus order* (10) · selftest asserts newest-is-front, interaction reorders, Escape closes the touched pin, and prints the `NSApp.windows` order to show it is *not* used |
| 3 | `isSelectable` allowed `level <= 0` and `snapEdges` was built from the **raw** candidate list, so the Finder desktop, wallpaper windows, `underbelly` and Display Backstop became hover targets and snap lines. | `level == WindowPicker.ordinaryApplicationLayer` (0 exactly); `WindowPicker.snapEdges` derives from the same filter, and `RegionSelector` builds `candidates` and `snapEdges` from it. Display bounds are still always included. | *Window picking* (+3), *Snap edges come from the same filtered list* (5) · selftest lists this machine's real levels and asserts the filter |
| 4 | `copyStillToClipboard` showed *only* the colour advisory on a P3/HDR display, so the common path on a modern Mac never said the screenshot had been copied. | [ClipboardCopyNotice](Sources/ExportCore/PasteboardImage.swift) always leads with `Copied W × H`; a colour advisory is appended to the same notice, never substituted. | *Clipboard copy notice* (7, covering sRGB, P3/HDR, image-only, and both together) |

## Round 7 — HUD placement and export performance

### A. The recording HUD could land off screen

| # | Requirement | Implementation | Verified by |
|---|---|---|---|
| P1 | Reproduce with a pure-geometry probe before changing anything | [hud-placement-probe.swift](scripts/diagnostics/hud-placement-probe.swift) — full screen, ≥90% height, flush top/bottom, small screens, negative-coordinate secondary | **8 of 12 realistic selections landed outside the visible frame** on this machine, plain full-screen included |
| P2 | A testable placement policy against the *matching* screen's `visibleFrame`, never main by default | [HUDPlacement.swift](Sources/TriCapKit/HUDPlacement.swift); `RecordingHUD.visibleFrame(for:)` matches by `CGDirectDisplayID` | *HUD placement* (15) · selftest against every attached display |
| P3 | Order: outside-below → outside-above → inside → always within a safe inset | `HUDPlacement.place`, `Strategy` names the branch taken | *HUD placement* — `prefersBelow`, `fallsBackToAbove`, `fallsBackToInside`, 300-case sweep |
| P4 | The countdown too | `HUDPlacement.placeCentred` | *HUD placement* — `countdownNearTheMenuBar`, `countdownSweep` |
| P5 | Stop is hit-testable and one click stops once | `HUDStopProxy` latches; `stopButton` exposed for hit-testing | selftest — `hitTest` returns the button; three clicks → one stop |
| P6 | Near-full-screen snapshot; the old logic must fail the tests | snapshot `15-hud-placement-near-fullscreen.png` | reverting to the old algorithm fails 6 tests / 140 sweep cases (recorded in REVIEW_HANDOFF §0.000) |
| P7 | `sharingType = .none`, TriCap excluded from capture, window level unchanged | untouched in `makeFloatingWindow` | code review · the HUD is still absent from every recorded frame in the selftest |

### B. Animated WebP export took far too long

| # | Requirement | Implementation | Verified by |
|---|---|---|---|
| Q1 | Baseline on identical high-motion material, ≥3 runs, median | `TriCap --benchmark-export`, paced at the real frame interval | 1440×900, 181 frames: **median 177.0 s** [163.1, 177.0, 238.6] |
| Q2 | Find the real cost before optimising | per-frame profile in the benchmark | `WebPAnimEncoderAdd` **857 ms/frame**; PNG decode 0.1 ms, pixel extraction 8.7 ms, assemble 0.2 ms total |
| Q3 | Encode during recording, libwebp touched only on one serial context, never in the SCK callback | [LivePreEncoder.swift](Sources/ExportCore/LivePreEncoder.swift) + [WebPAnimEncoderSession.swift](Sources/ExportCore/WebPAnimEncoderSession.swift); fed by `RegionRecorder.onFrameAccepted` outside the frame lock | *Live pre-encoder* (12), *Long-lived WebP animation encoder* (8) · selftest |
| Q4 | Bounded queue; backlog or failure abandons the fast path without blocking capture, growing memory, or losing material | `maxBacklog`, `Abandonment`, PNG frames untouched throughout | *Live pre-encoder* — `backlogAbandons`, `backlogIsBounded` · selftest forces a backlog |
| Q5 | Cancel, auto-stop, encode failure and quit all release the encoder | `LivePreEncoder.cancel()`, `deinit`, `AppDelegate.applicationWillTerminate` | *Live pre-encoder* — `cancelReleases`, `cancelIsIdempotent`, `submitAfterCancel` · selftest |
| Q6 | Reuse only for full range + no annotations + unchanged canvas/quality/lossless/method/loop/timeline | [PreEncodeReuse](Sources/ExportCore/PreEncodedAnimation.swift) — a pure function defaulting to *no* | *Pre-encode reuse policy* (10) · selftest exercises every fallback |
| Q7 | Trim, annotate and parameter changes still go through per-frame encoding | `ExportService.exportAnimation` branches on the decision only | selftest — the trimmed export is a valid animation of the trimmed length |
| Q8 | Frame-count bounds, playback length, loop, colour notice, static collapse and post-write verification all preserved | untouched; both routes share the same verification | selftest — the two paths agree on canvas, frame count, playback length, every timestamp and loop count |
| Q9 | ≥50% median tail-latency reduction, or data proving otherwise | `AnimationEncodeStrategy.balanced` + pre-encoding | **177.0 s → 0.85 s, a 99.5% reduction.** Strategy alone accounts for 93.6%; pre-encoding takes the remainder |
| Q10 | Report in-recording cost separately from tail latency | benchmark measures frame lateness against the delivery slot | worst lateness 0.2 ms, **0 dropped frames** in all three arms |
| Q11 | selftest covers fast-path hit, every fallback, forced backlog, cancel cleanup, output consistency and a perf diagnostic | `--selftest` §Live pre-encoding | 21 checks, all passing |

The one thing that could **not** be computed live is the animation's end timestamp: it depends on
the measured wall-clock duration, which is only final once capture stops. Per-frame timestamps are
computed by [IncrementalTimeline](Sources/TriCapKit/IncrementalTimeline.swift), the single rule
`ClipTiming` also runs — pinned by *Live and batch timelines agree* (3), because a one-millisecond
divergence would make the pre-encoded file silently wrong for the timeline it claims.

## Round 8 — banner layering, system mosaic, login item, release boundary

### A. The mode banner is always on top (P0)

| # | Requirement | Implementation | Verified by |
|---|---|---|---|
| A1 | Verify the actual cause before changing anything | Read of `draw(_:)`: banner drawn first, then selection punch (`.copy`+clear) and highlight (`.copy`+12% black) replace its pixels. Not a window-level problem | failing tests measured the exact erase values (alpha 0.0 / 0.121) |
| A2 | Fix by draw order inside the same overlay, no extra window | mask → highlight/selection + readouts → banner **last** ([SelectionOverlayView.swift](Sources/SelectionUI/SelectionOverlayView.swift)) | *Selection mode banner stays on top* (10; 7 fail on the old order) |
| A3 | Banner never erased, never in the capture | overlay windows are `sharingType=.none`, dismissed before capture, and the SCK filter excludes TriCap | code paths re-verified this round |
| A4 | Regressions + real-view snapshots for every overlap | highlight through banner, selection through banner, full-screen, top edge, Retina 2×, recording mode, punch/lift still work | tests + snapshots 16, 17 |

### B. System mosaic (P0)

| # | Requirement | Implementation | Verified by |
|---|---|---|---|
| B1 | Reproduce before asserting a root cause | [mosaic-mirror-probe.swift](scripts/diagnostics/mosaic-mirror-probe.swift): red top band pixelated → came back blue. The crop was double-flipped, sampling the mirrored band — white blocks on light pages | probe output recorded in the commit |
| B2 | Replace with `CIPixellate`; no hand-written averaging/scaling, no custom shaders | [AnnotationRenderer.swift](Sources/AnnotationCore/AnnotationRenderer.swift) `drawMosaic` | *Mosaic* (13; 3 fail on the old code) |
| B3 | Zero third-party deps; MetalPetal only with benchmark evidence | Core Image measured **3.2 ms/frame** on a real 800×600 capture (selftest prints it) — no case for a dependency; GPUImage3 not adopted | selftest diagnostic |
| B4 | Shared `CIContext`, thread safety, colour space, alpha | one static sRGB `CIContext` (`cacheIntermediates` off); filters per call; opaque output | concurrency test (6 parallel renders byte-equal), P3 and transparent-input tests |
| B5 | Canvas-anchored grid, no drift | `filter.center` = canvas top-left; probe established pixellate samples block centres tiled from `center` | grid test (130 mismatches on old code) |
| B6 | `mosaicBlockSize` semantics kept, copy fixed | block edge in pixels (now exact); tooltip says "pixelate", not "blur"; no data migration | tests + copy diff |
| B7 | Layer order: covers earlier, later stays visible; outside untouched; no white blocks/holes | full-canvas snapshot sampled, band cut in CGImage row space (a CI-side band crop returns wrong pixels when a block's sample point falls outside it — probed) | ordering, outside-untouched, edge-clip, alpha tests; reworked legacy AnnotationTests case pins the crop hazard |
| B8 | One render path for preview and every export format | unchanged: everything goes through `AnnotationRenderer.render` | determinism test (two calls byte-equal) |
| B9 | Document the security boundary | ARCHITECTURE.md: pixelation is visual obscuration, not redaction; use a filled rectangle for secrets. No new tool this round | doc |

### C. Launch at login

| # | Requirement | Implementation | Verified by |
|---|---|---|---|
| C1 | `SMAppService.mainApp` only; macOS 14+; no LaunchAgent/helper/private API | [LoginItemController.swift](Sources/TriCapApp/LoginItemController.swift) | code audit |
| C2 | Off by default; system status the only truth, no parallel Bool | no `AppSettings` field; status re-read on pane appearance and after every action | *Login item status mapping* / *toggle decisions* (8) |
| C3 | Settings toggle + a11y copy; all four statuses handled inline; approval opens Login Items | Startup section in [SettingsView.swift](Sources/TriCapApp/SettingsView.swift); `LoginItemPresentation` in [LoginItem.swift](Sources/TriCapKit/LoginItem.swift) | tests + snapshots 01, 19 |
| C4 | Idempotent register/unregister; errors never dressed as success | `LoginItemAction.action(forDesired:current:)`; controller re-reads status after every action, shows thrown errors inline | tests |
| C5 | No real logout/login performed | — | listed as unverified in REVIEW_HANDOFF §4.11 and release/RELEASE_PLAN.md |

### D. Install & release boundary

| # | Requirement | Implementation | Verified by |
|---|---|---|---|
| D1 | Version-controlled release plan | [release/RELEASE_PLAN.md](release/RELEASE_PLAN.md) | — |
| D2 | Never claim the current bundle is distributable | plan states arm64 + ad-hoc, release **BLOCKED** | — |
| D3 | Reproducible DMG packaging, fail-closed, no credentials | [package-release.sh](scripts/package-release.sh): Developer ID + Hardened Runtime + timestamp + notarytool + staple when present; `--local-test` otherwise; outputs to gitignored `build/dist` | both gates and the local-test DMG exercised on this machine |
| D4 | Release template with honest sections | [release/RELEASE_TEMPLATE.md](release/RELEASE_TEMPLATE.md): Minimum requirement ≠ Verified environments; Not yet verified; Known limitations | — |
| D5 | Release stays BLOCKED without Developer ID + accepted notarization | plan §blockers; no tag/upload; no Gatekeeper workaround anywhere | `security find-identity`: 0 identities |
| D6 | Apple Silicon only until Universal 2 is real | plan + template say arm64-only | — |

## Deliverables

| Deliverable | Location |
|---|---|
| Buildable, runnable Swift/AppKit/SwiftUI project | this repository; `./scripts/build-app.sh` |
| README (features, build, run, permission, usage, limits) | [README.md](README.md) |
| Architecture / requirements docs | [ARCHITECTURE.md](ARCHITECTURE.md), this file |
| libwebp licence and integration notes | [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md), [docs/LIBWEBP.md](docs/LIBWEBP.md) |
| Automated tests | `Tests/TriCapTests/` (418), `./scripts/test.sh` |
| App icon source and outputs | [scripts/generate-icon.swift](scripts/generate-icon.swift), `Resources/AppIcon/` |
| Export performance harness | `TriCap --benchmark-export` ([ExportBenchmark.swift](Sources/TriCapApp/ExportBenchmark.swift)) |
| Review handoff | [REVIEW_HANDOFF.md](REVIEW_HANDOFF.md) |
