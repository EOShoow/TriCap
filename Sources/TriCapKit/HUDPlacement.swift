import CoreGraphics
import Foundation

/// Where the recording chrome goes, as pure geometry.
///
/// Extracted because the old inline version had a hole that only opens up at the sizes people
/// actually record at. It preferred a spot just below the selection, and when that did not fit it
/// moved to just *above* the selection without checking whether **that** fit either — and no
/// branch ever constrained y to the screen. A near-full-screen selection has room on neither side,
/// so the HUD landed off the top of the display: invisible, and with it an unclickable Stop
/// button, leaving the duration limit as the only way to end a recording.
///
/// `scripts/diagnostics/hud-placement-probe.swift` reproduces that with the old algorithm; on this
/// machine 8 of 12 realistic selections put the HUD outside the visible frame, including plain
/// full-screen capture.
///
/// Everything here works in **AppKit global points** and against a *visible* frame — the screen
/// minus the menu bar and the Dock — not the full display bounds. A HUD under the Dock is as
/// unclickable as one off the top.
public enum HUDPlacement {

    /// Gap between the selection and the chrome placed outside it.
    public static let gap: CGFloat = 12
    /// Smallest distance the chrome keeps from the edge of the visible frame.
    public static let edgeInset: CGFloat = 8

    /// Which of the strategies produced a placement. Useful in tests and diagnostics: it says
    /// *why* the HUD is where it is.
    public enum Strategy: String, Equatable, Sendable {
        /// Clear of the selection, below it. The default, and what most recordings get.
        case below
        /// Clear of the selection, above it.
        case above
        /// Overlapping the selection, near its bottom edge. Safe because the chrome is
        /// `sharingType = .none` and TriCap is excluded from the capture filter, so it is never
        /// recorded — it only covers what the user is looking at.
        case insideBottom
        /// Overlapping the selection, near its top edge.
        case insideTop
        /// Nothing fit anywhere sensible; the chrome is clamped into the visible frame.
        case clamped
    }

    public struct Placement: Equatable, Sendable {
        public let frame: CGRect
        public let strategy: Strategy

        public init(frame: CGRect, strategy: Strategy) {
            self.frame = frame
            self.strategy = strategy
        }
    }

    /// Place chrome of `size` relative to `region`, guaranteed inside `visibleFrame`.
    ///
    /// Order of preference: outside-below, outside-above, inside-bottom, inside-top. Whichever is
    /// chosen, the result is clamped, so the returned frame is always within the visible frame
    /// when the visible frame is large enough to hold it at all.
    ///
    /// - Parameter visibleFrame: the `visibleFrame` of the screen **the region is on** — never the
    ///   main screen by default, or the chrome for a recording on a secondary display lands on the
    ///   primary one.
    public static func place(
        size: CGSize,
        over region: CGRect,
        in visibleFrame: CGRect
    ) -> Placement {
        let safe = visibleFrame.insetBy(dx: edgeInset, dy: edgeInset)

        // A visible frame too small to hold the chrome at all: centre it and let the clamp do what
        // it can. Better a partly-visible HUD than one placed by arithmetic on a negative width.
        guard safe.width >= size.width, safe.height >= size.height else {
            return Placement(frame: centred(size: size, in: visibleFrame), strategy: .clamped)
        }

        let centredX = region.midX - size.width / 2

        let candidates: [(CGFloat, Strategy)] = [
            (region.minY - gap - size.height, .below),
            (region.maxY + gap, .above),
            (region.minY + gap, .insideBottom),
            (region.maxY - gap - size.height, .insideTop),
        ]

        for (y, strategy) in candidates {
            let frame = CGRect(x: centredX, y: y, width: size.width, height: size.height)
            // The x axis is clamped for every strategy — a selection near the left or right edge
            // would otherwise push the chrome sideways off the screen — but a candidate is only
            // accepted when its *y* already fits, because y is what distinguishes the strategies.
            let horizontallyFitted = clampedHorizontally(frame, within: safe)
            if y >= safe.minY, y + size.height <= safe.maxY {
                return Placement(frame: horizontallyFitted, strategy: strategy)
            }
        }

        // Nothing fit: put it at the bottom of the visible frame, which is where a floating
        // control is least likely to cover what the user is watching.
        let fallback = CGRect(x: centredX, y: safe.minY, width: size.width, height: size.height)
        return Placement(frame: clamped(fallback, within: safe), strategy: .clamped)
    }

    /// Place chrome centred on the region — the countdown — still guaranteed on screen.
    ///
    /// The countdown used to be centred with no clamping at all, so a small selection near the top
    /// of the screen pushed it under the menu bar.
    public static func placeCentred(
        size: CGSize,
        over region: CGRect,
        in visibleFrame: CGRect
    ) -> Placement {
        let safe = visibleFrame.insetBy(dx: edgeInset, dy: edgeInset)
        let wanted = CGRect(
            x: region.midX - size.width / 2,
            y: region.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        guard safe.width >= size.width, safe.height >= size.height else {
            return Placement(frame: centred(size: size, in: visibleFrame), strategy: .clamped)
        }
        let result = clamped(wanted, within: safe)
        return Placement(frame: result, strategy: result == wanted ? .insideBottom : .clamped)
    }

    /// Whether a frame is fully inside a visible frame — what every test here asserts, and what
    /// the runnable self-test checks against real `NSScreen` geometry.
    public static func isFullyVisible(_ frame: CGRect, in visibleFrame: CGRect) -> Bool {
        visibleFrame.contains(frame)
    }

    private static func clamped(_ frame: CGRect, within safe: CGRect) -> CGRect {
        CGRect(
            x: min(max(frame.minX, safe.minX), safe.maxX - frame.width),
            y: min(max(frame.minY, safe.minY), safe.maxY - frame.height),
            width: frame.width,
            height: frame.height
        )
    }

    private static func clampedHorizontally(_ frame: CGRect, within safe: CGRect) -> CGRect {
        CGRect(
            x: min(max(frame.minX, safe.minX), safe.maxX - frame.width),
            y: frame.minY,
            width: frame.width,
            height: frame.height
        )
    }

    private static func centred(size: CGSize, in frame: CGRect) -> CGRect {
        CGRect(
            x: frame.midX - size.width / 2,
            y: frame.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }
}
