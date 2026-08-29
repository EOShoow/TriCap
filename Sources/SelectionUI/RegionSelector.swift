import AppKit
import TriCapKit

/// Geometry passed to `NSWindow.init(contentRect:styleMask:backing:defer:screen:)`.
///
/// When an explicit `screen` is supplied, AppKit interprets `contentRect.origin` relative to that
/// screen. Passing `NSScreen.frame` here therefore applies a secondary display's non-zero origin
/// twice. The primary display hid the bug because its origin is `(0, 0)`.
enum SelectionOverlayPlacement {
    static func contentRect(forScreenFrame frame: CGRect) -> CGRect {
        CGRect(origin: .zero, size: frame.size)
    }
}

/// Drives the full-screen region picker.
///
/// One overlay window is created per display and they cooperate: whichever view receives the
/// `mouseDown` starts the drag, but the selection rectangle is kept in AppKit global points and
/// broadcast to *every* overlay, so a drag that crosses monitors renders as one rectangle.
/// When the drag ends, the display with the largest overlap wins and the selection is resolved
/// into a ``CaptureRegion`` (which clips it to that display and snaps it to whole pixels).
@MainActor
public final class RegionSelector {

    /// The picker's mode vocabulary is ``CaptureFlow`` itself — quick screenshot, screenshot to
    /// the editor, or a recording. The flow lives in the overlay (cycled with `R`, `S` jumps to
    /// the edit flow) rather than in a pre-selection dialog, so one hot key reaches all three
    /// without an extra click.
    public enum Outcome: Sendable {
        case selected(CaptureRegion, CaptureFlow)
        case cancelled
    }

    private var windows: [SelectionOverlayWindow] = []
    private var views: [SelectionOverlayView] = []
    private var displays: [DisplayGeometry] = []

    private var mode: CaptureFlow = .quickStill
    private var anchor: CGPoint?
    private var gesture: SelectionGesture?

    /// Windows the user may click to capture, snapshotted once when the overlay opens.
    ///
    /// Polling the window server on every mouse-move would be far too slow; a list taken at open
    /// time is also what the user sees, because the overlay covers everything anyway.
    ///
    /// Already filtered by `WindowPicker.isSelectable` — see ``snapEdges``.
    private var candidates: [WindowCandidate] = []

    /// Rectangles read off the screen pixels, which arrive *after* the overlay is already up.
    ///
    /// Detection costs tens of milliseconds and must not delay the crosshair, so the overlay opens
    /// with window highlighting working and these land a moment later. Everything that consumes
    /// them — the highlight, the readout, the click, the snap set — is refreshed at that point, so
    /// there is no state in which one of them knows about a rectangle and another does not.
    private var visualRegions: [VisualRegionCandidate] = []
    private var highlighted: SelectionTarget?
    /// Edges the drag snaps to: the **same** filtered windows as ``candidates``, plus every
    /// display.
    ///
    /// These two must come from one filtered list. Building the snap set from the raw candidates
    /// meant the desktop, Notification Centre widgets and the Dock's wallpaper window contributed
    /// snap lines even though none of them could be hovered or clicked — full-screen edges that
    /// masquerade as screen edges and drag a selection somewhere the user did not aim.
    private var snapEdges: [CGRect] = []
    private var continuation: CheckedContinuation<Outcome, Never>?
    private var previouslyActiveApp: NSRunningApplication?

    public init() {}

    /// Present the picker and wait for the user to choose a region or cancel.
    /// - Parameters:
    ///   - windowCandidates: selectable windows, front to back. Empty disables
    ///     click-to-capture-window and leaves only free-form dragging, which is the correct
    ///     degradation when the window list cannot be read.
    ///   - visualRegions: supplies rectangles detected in the screen pixels. Called once, off the
    ///     main actor, while the overlay is already up; it may take as long as it needs and may
    ///     return nothing. Defaults to nothing, which is exactly the behaviour that existed
    ///     before visual regions.
    public func selectRegion(
        initialMode: CaptureFlow,
        windowCandidates: [WindowCandidate] = [],
        visualRegions: (@Sendable () async -> [VisualRegionCandidate])? = nil
    ) async -> Outcome {
        let displays = DisplaySurvey.currentDisplays()
        guard !displays.isEmpty else { return .cancelled }
        self.displays = displays
        self.mode = initialMode
        // One filtered list feeds both hit-testing and snapping, so they can never disagree about
        // what counts as a window.
        let ownBundle = Bundle.main.bundleIdentifier
        self.candidates = WindowPicker.selectableWindows(
            in: windowCandidates, ownBundleIdentifier: ownBundle
        )
        self.visualRegions = []
        rebuildSnapEdges()

        // Remember who was in front so a cancelled capture puts focus back where it was.
        previouslyActiveApp = NSWorkspace.shared.frontmostApplication

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            presentOverlays()

            guard let detectRegions = visualRegions else { return }
            Task { @MainActor [weak self] in
                let detected = await detectRegions()
                self?.install(visualRegions: detected)
            }
        }
    }

    /// Adopt the detected rectangles once they arrive.
    ///
    /// Ignored if the overlay has already closed — a detection finishing after the user has
    /// clicked must not resurrect a highlight or mutate a finished selection.
    private func install(visualRegions detected: [VisualRegionCandidate]) {
        guard continuation != nil, !detected.isEmpty else { return }
        visualRegions = detected
        rebuildSnapEdges()

        // The pointer has not moved, so nothing would otherwise re-run hit-testing; without this
        // the user has to jiggle the mouse before the feature appears to exist.
        if anchor == nil {
            updateHighlight(at: NSEvent.mouseLocation)
        }
    }

    /// Snap targets: windows, displays and confident visual rectangles — the same filtered set
    /// that can be hovered and clicked. Rebuilt whenever that set changes.
    private func rebuildSnapEdges() {
        snapEdges = VisualRegionPicker.snapEdges(
            windows: candidates,
            displayBounds: displays.map(\.appKitBounds),
            visualRegions: visualRegions,
            ownBundleIdentifier: Bundle.main.bundleIdentifier
        )
    }

    // MARK: - Overlay lifecycle

    private func presentOverlays() {
        for screen in NSScreen.screens {
            let window = SelectionOverlayWindow(
                contentRect: SelectionOverlayPlacement.contentRect(forScreenFrame: screen.frame),
                styleMask: .borderless,
                backing: .buffered,
                defer: false,
                screen: screen
            )
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = false
            window.isReleasedWhenClosed = false
            // Above the menu bar and the Dock, but still an ordinary window we own.
            window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            // Keep the dimming layer out of other apps' screen recordings.
            window.sharingType = .none

            let view = SelectionOverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.autoresizingMask = [.width, .height]
            view.delegate = self
            view.mode = mode
            window.contentView = view

            windows.append(window)
            views.append(view)
            window.orderFrontRegardless()
        }

        NSApp.activate(ignoringOtherApps: true)
        windows.first?.makeKeyAndOrderFront(nil)
        windows.first?.makeFirstResponder(views.first)
        NSCursor.crosshair.push()
        TriCapLog.selection.info(
            "selection overlays presented on \(self.windows.count, privacy: .public) display(s) mode=\(self.mode.rawValue, privacy: .public)"
        )
    }

    private func dismissOverlays() {
        NSCursor.pop()
        for window in windows {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        windows.removeAll()
        views.removeAll()
        anchor = nil
    }

    private func finish(_ outcome: Outcome) {
        guard let continuation else { return }
        self.continuation = nil
        dismissOverlays()

        if case .cancelled = outcome {
            // Hand focus back so a cancelled capture is invisible to the user's workflow.
            previouslyActiveApp?.activate()
        }
        previouslyActiveApp = nil

        continuation.resume(returning: outcome)
    }

    private func broadcast(selection: CGRect?) {
        // A nil selection means "nothing dragged yet"; the overlay then shows the window highlight.
        var pixelSize: CGSize?
        if let selection,
           let display = DisplaySurvey.displayWithLargestOverlap(of: selection, in: displays),
           let region = CaptureRegion(appKitGlobalRect: selection, display: display) {
            pixelSize = region.nativePixelSize
        }
        for view in views {
            view.globalSelection = selection
            view.selectionPixelSize = pixelSize
        }
    }

    private func applyMode() {
        for view in views {
            view.mode = mode
        }
    }
}

extension RegionSelector: SelectionOverlayDelegate {

    func overlayDidHover(at point: CGPoint) {
        // Only while no drag is in progress; a highlight competing with a live selection is noise.
        guard anchor == nil else { return }
        updateHighlight(at: point)
    }

    func overlayDidBeginDrag(at point: CGPoint) {
        anchor = point
        gesture = SelectionGesture(origin: point)
        // Keep the highlight up: until the pointer passes the drag threshold this is still a click.
        broadcast(selection: nil)
    }

    func overlayDidDrag(to point: CGPoint, snapping: Bool) {
        guard let anchor else { return }
        gesture?.update(to: point)

        // Below the threshold the press is still a window click, so nothing is drawn as a region.
        guard gesture?.mode == .dragging else { return }
        clearHighlight()

        let raw = CGRect(from: anchor, to: point)
        broadcast(selection: SnapEngine.snap(rect: raw, to: snapEdges, enabled: snapping))
    }

    func overlayDidEndDrag(at point: CGPoint) {
        guard let anchor else {
            finish(.cancelled)
            return
        }
        let isClick = gesture?.mode != .dragging
        self.anchor = nil
        self.gesture = nil

        // A click captures whatever is highlighted — the very rectangle the user was looking at,
        // whether the window server named it or the pixels did.
        if isClick, let target = highlighted,
           let display = DisplaySurvey.displayWithLargestOverlap(of: target.frame, in: displays),
           let region = CaptureRegion(appKitGlobalRect: target.frame, display: display) {
            TriCapLog.selection.info(
                "captured \(target.identity, privacy: .public) \(Int(region.displayPixelRect.width), privacy: .public)x\(Int(region.displayPixelRect.height), privacy: .public)px"
            )
            finish(.selected(region, mode))
            return
        }

        let rect = SnapEngine.snap(
            rect: CGRect(from: anchor, to: point),
            to: snapEdges,
            enabled: !NSEvent.modifierFlags.contains(.option)
        )

        // A click without a drag means "changed my mind", not "capture a 0x0 region".
        guard rect.width >= 1, rect.height >= 1,
              let display = DisplaySurvey.displayWithLargestOverlap(of: rect, in: displays),
              let region = CaptureRegion(appKitGlobalRect: rect, display: display)
        else {
            TriCapLog.selection.info("selection dismissed: degenerate drag")
            finish(.cancelled)
            return
        }

        TriCapLog.selection.info(
            "selection \(Int(region.displayPixelRect.width), privacy: .public)x\(Int(region.displayPixelRect.height), privacy: .public)px on display \(region.display.displayID, privacy: .public)"
        )
        finish(.selected(region, mode))
    }

    func overlayDidCancel() {
        TriCapLog.selection.info("selection cancelled")
        finish(.cancelled)
    }

    /// `nil` advances the cycle (the `R` key); a concrete flow jumps straight to it (the `S` key).
    func overlayDidRequestMode(_ requested: CaptureFlow?) {
        mode = requested ?? mode.next
        applyMode()
    }

    // MARK: - Window highlight

    private func updateHighlight(at point: CGPoint) {
        let window = WindowPicker.window(at: point, in: candidates, ownBundleIdentifier: Bundle.main.bundleIdentifier)
        let target = VisualRegionPicker.target(at: point, window: window, visualRegions: visualRegions)
        guard target?.identity != highlighted?.identity else { return }
        highlighted = target

        var pixelSize: CGSize?
        if let frame = target?.frame,
           let display = DisplaySurvey.displayWithLargestOverlap(of: frame, in: displays),
           let region = CaptureRegion(appKitGlobalRect: frame, display: display) {
            pixelSize = region.nativePixelSize
        }
        for view in views {
            view.highlightedWindow = target?.frame
            view.highlightedWindowPixelSize = pixelSize
            view.highlightIsVisualRegion = target?.isVisualRegion ?? false
        }
    }

    private func clearHighlight() {
        guard highlighted != nil else { return }
        highlighted = nil
        for view in views {
            view.highlightedWindow = nil
            view.highlightedWindowPixelSize = nil
            view.highlightIsVisualRegion = false
        }
    }
}

extension CGRect {
    /// Rectangle spanned by two corners, in either order.
    init(from a: CGPoint, to b: CGPoint) {
        self.init(
            x: Swift.min(a.x, b.x),
            y: Swift.min(a.y, b.y),
            width: abs(a.x - b.x),
            height: abs(a.y - b.y)
        )
    }
}
