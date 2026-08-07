import AppKit
import TriCapKit

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
    private var highlighted: WindowCandidate?
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
    /// - Parameter windowCandidates: selectable windows, front to back. Empty disables
    ///   click-to-capture-window and leaves only free-form dragging, which is the correct
    ///   degradation when the window list cannot be read.
    public func selectRegion(
        initialMode: CaptureFlow,
        windowCandidates: [WindowCandidate] = []
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
        self.snapEdges = WindowPicker.snapEdges(
            in: windowCandidates,
            displayBounds: displays.map(\.appKitBounds),
            ownBundleIdentifier: ownBundle
        )

        // Remember who was in front so a cancelled capture puts focus back where it was.
        previouslyActiveApp = NSWorkspace.shared.frontmostApplication

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            presentOverlays()
        }
    }

    // MARK: - Overlay lifecycle

    private func presentOverlays() {
        for screen in NSScreen.screens {
            let window = SelectionOverlayWindow(
                contentRect: screen.frame,
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

        // A click on a highlighted window captures that window.
        if isClick, let window = highlighted,
           let display = DisplaySurvey.displayWithLargestOverlap(of: window.frame, in: displays),
           let region = CaptureRegion(appKitGlobalRect: window.frame, display: display) {
            TriCapLog.selection.info(
                "captured window \(window.id, privacy: .public) \(Int(region.displayPixelRect.width), privacy: .public)x\(Int(region.displayPixelRect.height), privacy: .public)px"
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
        guard window?.id != highlighted?.id else { return }
        highlighted = window

        var pixelSize: CGSize?
        if let window,
           let display = DisplaySurvey.displayWithLargestOverlap(of: window.frame, in: displays),
           let region = CaptureRegion(appKitGlobalRect: window.frame, display: display) {
            pixelSize = region.nativePixelSize
        }
        for view in views {
            view.highlightedWindow = window?.frame
            view.highlightedWindowPixelSize = pixelSize
        }
    }

    private func clearHighlight() {
        guard highlighted != nil else { return }
        highlighted = nil
        for view in views {
            view.highlightedWindow = nil
            view.highlightedWindowPixelSize = nil
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
