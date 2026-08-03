import CoreGraphics
import Foundation

/// One window the screenshot overlay might offer to capture.
///
/// A value type deliberately: the picking rules below are the part most likely to be wrong on a
/// multi-display, overlapping-window desktop, and they must be testable without a window server.
/// `SelectionUI` builds these from `SCShareableContent` once, when the overlay opens, and then
/// hit-tests locally — polling ScreenCaptureKit on every mouse-move would be far too slow.
public struct WindowCandidate: Equatable, Sendable, Identifiable {
    public let id: UInt32
    /// Frame in **AppKit global points** (bottom-left origin, +y up), matching `NSScreen.frame`.
    public let frame: CGRect
    /// `CGWindowLevel`. 0 is the ordinary application layer.
    public let level: Int
    public let isOnScreen: Bool
    public let bundleIdentifier: String?
    public let title: String?
    /// Front-to-back position as reported by the window server: 0 is frontmost.
    public let stackingIndex: Int

    public init(
        id: UInt32,
        frame: CGRect,
        level: Int = 0,
        isOnScreen: Bool = true,
        bundleIdentifier: String? = nil,
        title: String? = nil,
        stackingIndex: Int = 0
    ) {
        self.id = id
        self.frame = frame
        self.level = level
        self.isOnScreen = isOnScreen
        self.bundleIdentifier = bundleIdentifier
        self.title = title
        self.stackingIndex = stackingIndex
    }
}

/// Chooses the window under the pointer.
public enum WindowPicker {

    /// Windows smaller than this in either dimension are ignored.
    ///
    /// The window server publishes a lot of 1×1 and zero-size helper windows; offering one as a
    /// capture target produces an empty screenshot.
    public static let minimumUsefulEdge: CGFloat = 8

    /// Whether a candidate may ever be offered.
    ///
    /// - Excludes TriCap itself, so the selection overlay and the recording HUD are never targets.
    /// - Excludes off-screen, hidden and minimised windows, which have stale frames.
    /// - Excludes anything above the ordinary application layer: the menu bar, the Dock, status
    ///   items, screen-saver and security windows all live there, and none of them is a thing a
    ///   user means by "that window".
    public static func isSelectable(_ window: WindowCandidate, ownBundleIdentifier: String?) -> Bool {
        guard window.isOnScreen else { return false }
        guard window.level <= 0 else { return false }
        guard window.frame.width >= minimumUsefulEdge, window.frame.height >= minimumUsefulEdge else {
            return false
        }
        if let ownBundleIdentifier, window.bundleIdentifier == ownBundleIdentifier { return false }
        return true
    }

    /// The frontmost selectable window containing `point` (AppKit global points).
    ///
    /// Overlapping windows resolve by stacking order, not by area: the one actually visible at
    /// that pixel is the one the user is pointing at.
    public static func window(
        at point: CGPoint,
        in candidates: [WindowCandidate],
        ownBundleIdentifier: String? = nil
    ) -> WindowCandidate? {
        candidates
            .filter { isSelectable($0, ownBundleIdentifier: ownBundleIdentifier) }
            .filter { $0.frame.contains(point) }
            .min { $0.stackingIndex < $1.stackingIndex }
    }

    /// All selectable windows, front to back. Useful for tests and for debugging overlap.
    public static func selectableWindows(
        in candidates: [WindowCandidate],
        ownBundleIdentifier: String? = nil
    ) -> [WindowCandidate] {
        candidates
            .filter { isSelectable($0, ownBundleIdentifier: ownBundleIdentifier) }
            .sorted { $0.stackingIndex < $1.stackingIndex }
    }
}

/// Distinguishes a click from a drag, and remembers which one is in progress.
///
/// Without an explicit threshold, the hand tremor in a click turns "capture this window" into a
/// four-pixel manual selection.
public struct SelectionGesture: Equatable, Sendable {
    /// How far the pointer must travel before a press becomes a region drag.
    public static let dragThreshold: CGFloat = 6

    public enum Mode: Equatable, Sendable {
        /// Still within the threshold: releasing here captures the highlighted window.
        case tentative
        /// Past the threshold: this is a manual region selection.
        case dragging
    }

    public let origin: CGPoint
    public private(set) var mode: Mode = .tentative

    public init(origin: CGPoint) {
        self.origin = origin
    }

    /// Feed a new pointer position. Once dragging, always dragging — coming back within the
    /// threshold must not flip the gesture back to a window click mid-drag.
    public mutating func update(to point: CGPoint) {
        guard mode == .tentative else { return }
        if Self.exceedsThreshold(from: origin, to: point) { mode = .dragging }
    }

    public static func exceedsThreshold(from origin: CGPoint, to point: CGPoint) -> Bool {
        hypot(point.x - origin.x, point.y - origin.y) > dragThreshold
    }
}

/// Pulls a dragged selection onto nearby window and display edges.
public enum SnapEngine {

    /// How close an edge must be, in points, before the selection snaps to it.
    public static let threshold: CGFloat = 8

    /// Snap `rect` to whichever candidate edges are within ``threshold``.
    ///
    /// Each axis is considered independently, and each side snaps to its nearest edge, so a
    /// selection can align its left edge to one window and its right edge to another. The rect's
    /// size is allowed to change — that is the point of snapping to an edge rather than to a grid.
    ///
    /// - Parameter enabled: `false` returns `rect` untouched, which is what holding Option does.
    public static func snap(
        rect: CGRect,
        to edges: [CGRect],
        enabled: Bool = true,
        threshold: CGFloat = SnapEngine.threshold
    ) -> CGRect {
        guard enabled, !edges.isEmpty else { return rect }
        let standardized = rect.standardized

        let verticalLines = edges.flatMap { [$0.minX, $0.maxX] }
        let horizontalLines = edges.flatMap { [$0.minY, $0.maxY] }

        // Each axis is guarded on its own. A thin selection near one edge can snap both of its
        // horizontal sides onto the same line, which would collapse it — but that is no reason to
        // throw away a perfectly good snap on the other axis.
        let (minX, maxX) = snappedSpan(
            low: standardized.minX, high: standardized.maxX, lines: verticalLines, threshold: threshold
        )
        let (minY, maxY) = snappedSpan(
            low: standardized.minY, high: standardized.maxY, lines: horizontalLines, threshold: threshold
        )
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Snap one axis, falling back to the original span if snapping would collapse or invert it.
    private static func snappedSpan(
        low: CGFloat,
        high: CGFloat,
        lines: [CGFloat],
        threshold: CGFloat
    ) -> (CGFloat, CGFloat) {
        let snappedLow = nearest(low, in: lines, threshold: threshold)
        let snappedHigh = nearest(high, in: lines, threshold: threshold)
        guard snappedHigh > snappedLow else { return (low, high) }
        return (snappedLow, snappedHigh)
    }

    /// The nearest candidate line within `threshold`, or `value` unchanged.
    public static func nearest(_ value: CGFloat, in lines: [CGFloat], threshold: CGFloat) -> CGFloat {
        var best = value
        var bestDistance = threshold
        for line in lines {
            let distance = abs(line - value)
            if distance <= bestDistance {
                bestDistance = distance
                best = line
            }
        }
        return best
    }
}
