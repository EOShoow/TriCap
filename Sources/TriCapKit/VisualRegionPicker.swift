import CoreGraphics
import Foundation

/// One rectangle the screen content makes a case for, already resolved into the space the rest of
/// the selection path works in.
///
/// The detector reports field samples. This is the same rectangle after it has been mapped
/// through the display it was found on, which is the step that has to survive Retina scaling and
/// a second monitor sitting above or to the left of the primary one.
public struct VisualRegionCandidate: Equatable, Sendable, Identifiable {
    public let id: Int
    /// The display the rectangle was detected on.
    public let displayID: CGDirectDisplayID
    /// Frame in **AppKit global points** (bottom-left origin, +y up), matching `NSScreen.frame` —
    /// the same space ``WindowCandidate/frame`` uses, so the two are directly comparable.
    public let frame: CGRect
    /// `0...1` from ``VisualRegionDetector``.
    public let confidence: Double

    public init(id: Int, displayID: CGDirectDisplayID, frame: CGRect, confidence: Double) {
        self.id = id
        self.displayID = displayID
        self.frame = frame
        self.confidence = confidence
    }

    var area: CGFloat { max(0, frame.width) * max(0, frame.height) }
}

/// Maps detector output out of field samples and into AppKit global points.
///
/// Four spaces in one hop, so it gets its own tested function rather than being inlined at the
/// call site. `CoordinateConverter` still owns every individual conversion; this only sequences
/// them and handles the one thing it cannot: the field is a *downsample* of the display, so the
/// first step is a scale, and it is the step that silently breaks on a mixed-DPI desktop.
public enum VisualRegionMapping {

    /// Field rect (top-left origin, in samples) → AppKit global points.
    ///
    /// The rect is snapped to whole display pixels on the way through — a boundary found halfway
    /// between two samples is not real precision, and handing a fractional rect to the snapping
    /// engine would put selection edges on lines the user can never hit exactly.
    ///
    /// - Returns: `nil` if the field or the display is degenerate, or if the rectangle maps to
    ///   less than a pixel.
    public static func appKitRect(
        fromFieldRect rect: CGRect,
        fieldSize: CGSize,
        display: DisplayGeometry
    ) -> CGRect? {
        guard fieldSize.width > 0, fieldSize.height > 0,
              display.pointPixelScale > 0,
              display.quartzBounds.width > 0, display.quartzBounds.height > 0
        else { return nil }

        let pixelSize = display.pixelSize
        let scaleX = pixelSize.width / fieldSize.width
        let scaleY = pixelSize.height / fieldSize.height

        let pixels = CGRect(
            x: rect.minX * scaleX,
            y: rect.minY * scaleY,
            width: rect.width * scaleX,
            height: rect.height * scaleY
        ).integralOutward.intersection(CGRect(origin: .zero, size: pixelSize))
        guard !pixels.isNull, pixels.width >= 1, pixels.height >= 1 else { return nil }

        // Display pixels → display-local points → Quartz global → AppKit global. Every one of
        // these already exists and is tested; the value here is that they happen in this order.
        let local = CoordinateConverter.displayLocalPointRect(
            fromPixelRect: pixels, scale: display.pointPixelScale
        )
        let quartz = CoordinateConverter.quartzGlobalRect(
            fromDisplayLocalRect: local, displayBoundsInQuartzPoints: display.quartzBounds
        )
        return CoordinateConverter.appKitRect(
            fromQuartzRect: quartz, primaryHeightInPoints: display.primaryHeightInPoints
        )
    }

    /// Map a whole detection pass for one display.
    ///
    /// `startingID` keeps candidate identifiers unique across displays, which is what lets the
    /// overlay compare "is this the same rectangle I am already highlighting" by id.
    public static func candidates(
        from detected: [VisualRegionDetector.Candidate],
        fieldSize: CGSize,
        display: DisplayGeometry,
        startingID: Int = 0,
        minimumEdgeInPoints: CGFloat = 16,
        captureInsetInPixels: CGFloat = 0
    ) -> [VisualRegionCandidate] {
        var next = startingID
        return detected.compactMap { candidate in
            guard let detectedFrame = appKitRect(
                fromFieldRect: candidate.rect, fieldSize: fieldSize, display: display
            ), let frame = protectedFrame(
                detectedFrame, insetInPixels: captureInsetInPixels, display: display
            ) else { return nil }
            // Anything this small is a control, not a region, and clicking it would be a
            // surprise rather than a shortcut.
            guard frame.width >= minimumEdgeInPoints, frame.height >= minimumEdgeInPoints else {
                return nil
            }
            defer { next += 1 }
            return VisualRegionCandidate(
                id: next,
                displayID: display.displayID,
                frame: frame,
                confidence: candidate.confidence
            )
        }
    }

    /// Pull a visual boundary inward before it becomes a capture rectangle.
    ///
    /// An edge detector has to look across the colour transition that makes a page or image
    /// visible. The transition itself — anti-aliasing, a dark outline or a coloured rim — is not
    /// usually content the user wants in the result. This keeps a small, **physical-pixel** guard
    /// on every side. Applying it on the native pixel grid (rather than rounding a point inset at
    /// the call site) makes a 3 px guard mean 3 px on both 1× and Retina displays.
    ///
    /// A zero inset preserves the raw mapped rectangle for callers that need geometry only. A
    /// requested guard is capped so a small but otherwise valid region can never collapse.
    public static func protectedFrame(
        _ detectedFrame: CGRect,
        insetInPixels: CGFloat,
        display: DisplayGeometry
    ) -> CGRect? {
        guard detectedFrame.width > 0, detectedFrame.height > 0, display.pointPixelScale > 0 else {
            return nil
        }

        let requested = max(0, insetInPixels.rounded(.up))
        guard requested > 0 else { return detectedFrame }

        // AppKit global coordinates may be negative, or have a non-integral origin on a
        // neighbouring display. Move into display-local coordinates before quantising so the
        // source-pixel guard remains anchored to the sampled display, not to the desktop origin.
        let rawPixels = CGRect(
            x: (detectedFrame.minX - display.appKitBounds.minX) * display.pointPixelScale,
            y: (detectedFrame.minY - display.appKitBounds.minY) * display.pointPixelScale,
            width: detectedFrame.width * display.pointPixelScale,
            height: detectedFrame.height * display.pointPixelScale
        ).integralOutward
        // Keep the guard integral in source pixels. A half-pixel fallback would be rounded back
        // outward by `CaptureRegion` and could reintroduce the very rim this protects against.
        let maximumInset = max(0, ((min(rawPixels.width, rawPixels.height) - 1) / 2).rounded(.down))
        let inset = min(requested, maximumInset)
        let protectedPixels = rawPixels.insetBy(dx: inset, dy: inset)
        guard protectedPixels.width >= 1, protectedPixels.height >= 1 else { return nil }

        return CGRect(
            x: display.appKitBounds.minX + protectedPixels.minX / display.pointPixelScale,
            y: display.appKitBounds.minY + protectedPixels.minY / display.pointPixelScale,
            width: protectedPixels.width / display.pointPixelScale,
            height: protectedPixels.height / display.pointPixelScale
        )
    }
}

/// What a click at the current pointer position would capture.
public enum SelectionTarget: Equatable, Sendable {
    case window(WindowCandidate)
    case visualRegion(VisualRegionCandidate)

    /// The rectangle, in AppKit global points. Hover highlighting, the pixel readout, the click
    /// and the snap set all read this one value, so they cannot disagree about what is being
    /// offered.
    public var frame: CGRect {
        switch self {
        case .window(let window): return window.frame
        case .visualRegion(let region): return region.frame
        }
    }

    public var isVisualRegion: Bool {
        if case .visualRegion = self { return true }
        return false
    }

    /// Stable within one selection session; used to tell "still the same target" from "moved onto
    /// something else" without redrawing on every mouse-move.
    public var identity: String {
        switch self {
        case .window(let window): return "w\(window.id)"
        case .visualRegion(let region): return "v\(region.id)"
        }
    }
}

/// Decides between the window under the pointer and the rectangles the pixels suggest.
///
/// Kept apart from ``VisualRegionDetector`` on purpose. Detection answers "what rectangles are
/// there, and how sure am I"; this answers "which one did the user mean" — a different question,
/// with different failure modes, tested separately.
public enum VisualRegionPicker {

    public struct Options: Sendable, Equatable {

        /// The bar a detected rectangle must clear before it may be offered *at all*.
        ///
        /// Below it the rectangle does not exist as far as the rest of the app is concerned: no
        /// highlight, no click target, no snap line. That is the whole "fall back to the window"
        /// rule — there is no separate fallback path to get wrong, because a rectangle that does
        /// not clear this bar never enters the picture.
        public var minConfidence: Double

        /// A visual rectangle this close in area to the window it sits in is *the* window, drawn
        /// slightly differently. The window's geometry comes from the window server and is exact,
        /// so it wins.
        ///
        /// This is also the guard the brief asks for: a near-window-sized flat background cannot
        /// take the window's place.
        public var windowDominanceAreaFraction: CGFloat

        /// How much of the rectangle must lie inside the window under the pointer before it is
        /// believable as content *of* that window.
        public var minContainmentInWindow: CGFloat

        public init(
            minConfidence: Double = 0.62,
            windowDominanceAreaFraction: CGFloat = 0.85,
            minContainmentInWindow: CGFloat = 0.6
        ) {
            self.minConfidence = minConfidence
            self.windowDominanceAreaFraction = windowDominanceAreaFraction
            self.minContainmentInWindow = minContainmentInWindow
        }

        public static let `default` = Options()
    }

    /// Every candidate confident enough to be offered, smallest first.
    ///
    /// Smallest first is the nesting rule: a panel inside a canvas inside a window is three
    /// plausible targets, and the innermost one is the one the pointer is most specifically on.
    public static func offerable(
        _ candidates: [VisualRegionCandidate],
        options: Options = .default
    ) -> [VisualRegionCandidate] {
        candidates
            .filter { $0.confidence >= options.minConfidence && $0.area > 0 }
            .sorted { lhs, rhs in
                if lhs.area != rhs.area { return lhs.area < rhs.area }
                return lhs.confidence > rhs.confidence
            }
    }

    /// The smallest offerable rectangle containing `point`.
    public static func visualRegion(
        at point: CGPoint,
        in candidates: [VisualRegionCandidate],
        options: Options = .default
    ) -> VisualRegionCandidate? {
        offerable(candidates, options: options).first { $0.frame.contains(point) }
    }

    /// What a click at `point` should capture.
    ///
    /// - A confident rectangle nested inside the window wins: that is the feature.
    /// - A rectangle that is essentially the window, or that mostly lies outside it, loses: the
    ///   window server's frame is better evidence than an inferred edge.
    /// - Nothing confident, or nothing at all, and the window is the answer — which is exactly
    ///   the behaviour that existed before any of this.
    public static func target(
        at point: CGPoint,
        window: WindowCandidate?,
        visualRegions: [VisualRegionCandidate],
        options: Options = .default
    ) -> SelectionTarget? {
        guard let region = visualRegion(at: point, in: visualRegions, options: options) else {
            return window.map(SelectionTarget.window)
        }
        guard let window else { return .visualRegion(region) }

        let windowArea = max(0, window.frame.width) * max(0, window.frame.height)
        guard windowArea > 0 else { return .visualRegion(region) }

        if region.area >= windowArea * options.windowDominanceAreaFraction {
            return .window(window)
        }

        let overlap = region.frame.intersection(window.frame)
        let contained = overlap.isNull ? 0 : (overlap.width * overlap.height) / region.area
        guard contained >= options.minContainmentInWindow else { return .window(window) }

        return .visualRegion(region)
    }

    /// The rectangles a drag may snap to: everything ``WindowPicker/snapEdges(in:displayBounds:ownBundleIdentifier:)``
    /// already offers, plus the visual rectangles confident enough to be clicked.
    ///
    /// Same filtered list as highlighting, for the same reason the window path works that way: a
    /// rectangle the user cannot click must not silently tug their selection either. Holding
    /// Option still disables snapping wholesale — that switch lives in `SnapEngine` and this does
    /// not touch it.
    public static func snapEdges(
        windows: [WindowCandidate],
        displayBounds: [CGRect],
        visualRegions: [VisualRegionCandidate],
        ownBundleIdentifier: String? = nil,
        options: Options = .default
    ) -> [CGRect] {
        WindowPicker.snapEdges(
            in: windows, displayBounds: displayBounds, ownBundleIdentifier: ownBundleIdentifier
        ) + offerable(visualRegions, options: options).map(\.frame)
    }
}
