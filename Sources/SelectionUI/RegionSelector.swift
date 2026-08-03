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

    /// What the user intends to do with the region being selected.
    ///
    /// The mode lives in the overlay (toggled with `R` / `S`) rather than in a pre-selection
    /// dialog, so one hot key reaches both a screenshot and a recording without an extra click.
    public enum CaptureMode: String, Sendable, Equatable {
        case still
        case recording

        public var toggled: CaptureMode { self == .still ? .recording : .still }

        public var hint: String {
            switch self {
            case .still:
                return "Drag to capture a screenshot   ·   R to record instead   ·   Esc to cancel"
            case .recording:
                return "Drag to record a clip   ·   S for a screenshot instead   ·   Esc to cancel"
            }
        }
    }

    public enum Outcome: Sendable {
        case selected(CaptureRegion, CaptureMode)
        case cancelled
    }

    private var windows: [SelectionOverlayWindow] = []
    private var views: [SelectionOverlayView] = []
    private var displays: [DisplayGeometry] = []

    private var mode: CaptureMode = .still
    private var anchor: CGPoint?
    private var continuation: CheckedContinuation<Outcome, Never>?
    private var previouslyActiveApp: NSRunningApplication?

    public init() {}

    /// Present the picker and wait for the user to choose a region or cancel.
    public func selectRegion(initialMode: CaptureMode) async -> Outcome {
        let displays = DisplaySurvey.currentDisplays()
        guard !displays.isEmpty else { return .cancelled }
        self.displays = displays
        self.mode = initialMode

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
            view.hintText = mode.hint
            view.isRecordingMode = mode == .recording
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
            view.hintText = mode.hint
            view.isRecordingMode = mode == .recording
        }
    }
}

extension RegionSelector: SelectionOverlayDelegate {

    func overlayDidBeginDrag(at point: CGPoint) {
        anchor = point
        broadcast(selection: CGRect(from: point, to: point))
    }

    func overlayDidDrag(to point: CGPoint) {
        guard let anchor else { return }
        broadcast(selection: CGRect(from: anchor, to: point))
    }

    func overlayDidEndDrag(at point: CGPoint) {
        guard let anchor else {
            finish(.cancelled)
            return
        }
        let rect = CGRect(from: anchor, to: point)
        self.anchor = nil

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

    func overlayDidRequestMode(_ requested: CaptureMode?) {
        mode = requested ?? mode.toggled
        applyMode()
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
