import CoreGraphics
import Foundation

/// TriCap deals with four distinct rectangle spaces. Mixing them up is the single
/// most common source of "the screenshot is offset by half a screen" bugs, so every
/// conversion in the app goes through this file and nothing else.
///
/// 1. **AppKit global points** — `NSScreen.frame`, `NSWindow.frame`, mouse events.
///    Origin is the *bottom-left* of the primary screen, +y points **up**.
///    Unit is a point (1 pt = `backingScaleFactor` pixels on that display).
///
/// 2. **Quartz global points** — `CGDisplayBounds`, `CGEvent` locations.
///    Origin is the *top-left* of the primary display, +y points **down**.
///    Unit is still a point.
///
/// 3. **Display-local points** — Quartz global points minus the display's origin.
///    This is what `SCStreamConfiguration.sourceRect` wants.
///
/// 4. **Display pixels** — display-local points multiplied by that display's
///    point→pixel scale. Origin top-left, +y down. This is the *native* pixel grid.
///
/// A fifth space, **capture pixels**, is whatever `SCStreamConfiguration.width/height`
/// ends up being: it equals display pixels unless we deliberately downscale for the
/// animated-WebP long-edge cap. `CaptureRegion` keeps both so the two never get confused.
public enum CoordinateSpace: String, Sendable {
    case appKitGlobalPoints
    case quartzGlobalPoints
    case displayLocalPoints
    case displayPixels
    case capturePixels
}

/// Pure, screen-independent conversions. Everything here is deterministic and unit tested;
/// nothing touches AppKit so it can run in a test process without a window server.
public enum CoordinateConverter {

    // MARK: - AppKit (bottom-left, +y up) <-> Quartz (top-left, +y down)

    /// Flip a point between AppKit global space and Quartz global space.
    ///
    /// The transform is its own inverse, which is why one function serves both directions.
    /// `primaryHeightInPoints` is the height of the screen whose AppKit origin is `(0, 0)`
    /// — i.e. `NSScreen.screens.first!.frame.height` (AppKit guarantees index 0 is that screen).
    public static func flipY(point: CGPoint, primaryHeightInPoints: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeightInPoints - point.y)
    }

    /// Convert an AppKit global rect (bottom-left origin) to a Quartz global rect (top-left origin).
    ///
    /// Note the rect's *origin* moves from its bottom-left corner to its top-left corner,
    /// so the height participates in the flip. Getting this wrong shifts the capture by
    /// exactly the selection height, which looks plausible on small selections — hence the test.
    public static func quartzRect(fromAppKitRect rect: CGRect, primaryHeightInPoints: CGFloat) -> CGRect {
        CGRect(
            x: rect.origin.x,
            y: primaryHeightInPoints - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    /// Inverse of ``quartzRect(fromAppKitRect:primaryHeightInPoints:)``. Also self-inverse.
    public static func appKitRect(fromQuartzRect rect: CGRect, primaryHeightInPoints: CGFloat) -> CGRect {
        CGRect(
            x: rect.origin.x,
            y: primaryHeightInPoints - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    // MARK: - Quartz global <-> display local

    /// Translate a Quartz global rect into the coordinate system of one display.
    public static func displayLocalRect(fromQuartzGlobalRect rect: CGRect, displayBoundsInQuartzPoints bounds: CGRect) -> CGRect {
        rect.offsetBy(dx: -bounds.origin.x, dy: -bounds.origin.y)
    }

    /// Inverse of ``displayLocalRect(fromQuartzGlobalRect:displayBoundsInQuartzPoints:)``.
    public static func quartzGlobalRect(fromDisplayLocalRect rect: CGRect, displayBoundsInQuartzPoints bounds: CGRect) -> CGRect {
        rect.offsetBy(dx: bounds.origin.x, dy: bounds.origin.y)
    }

    // MARK: - Points <-> pixels

    /// Convert a display-local point rect to that display's native pixel grid.
    ///
    /// The result is snapped **outward** to whole pixels so a selection never silently
    /// loses the sub-pixel sliver the user dragged over, then clamped to the display so
    /// an edge drag can't ask ScreenCaptureKit for out-of-bounds pixels.
    ///
    /// - Parameters:
    ///   - rect: display-local rect in points.
    ///   - scale: the display's point→pixel scale (2.0 on Retina, 1.0 otherwise).
    ///   - displaySizeInPoints: the display's own size in points, used for clamping.
    /// - Returns: an integral pixel rect, or `nil` if the selection collapses to nothing.
    public static func pixelRect(
        fromDisplayLocalPointRect rect: CGRect,
        scale: CGFloat,
        displaySizeInPoints: CGSize
    ) -> CGRect? {
        guard scale > 0, displaySizeInPoints.width > 0, displaySizeInPoints.height > 0 else { return nil }

        let scaled = CGRect(
            x: rect.origin.x * scale,
            y: rect.origin.y * scale,
            width: rect.width * scale,
            height: rect.height * scale
        )
        let outward = scaled.integralOutward

        let displayPixels = CGRect(
            x: 0,
            y: 0,
            width: (displaySizeInPoints.width * scale).rounded(),
            height: (displaySizeInPoints.height * scale).rounded()
        )
        let clamped = outward.intersection(displayPixels)
        guard !clamped.isNull, clamped.width >= 1, clamped.height >= 1 else { return nil }
        return clamped
    }

    /// Convert an integral pixel rect back to display-local points.
    ///
    /// `SCStreamConfiguration.sourceRect` is specified in points, so after snapping the
    /// selection to the pixel grid we have to hand ScreenCaptureKit the *point* rect that
    /// corresponds exactly to those pixels — not the user's original unsnapped drag.
    public static func displayLocalPointRect(fromPixelRect rect: CGRect, scale: CGFloat) -> CGRect {
        guard scale > 0 else { return rect }
        return CGRect(
            x: rect.origin.x / scale,
            y: rect.origin.y / scale,
            width: rect.width / scale,
            height: rect.height / scale
        )
    }
}

extension CGRect {
    /// `CGRect.integral` rounds the origin down and the far edge up, which is what we want,
    /// but it is documented in terms of `standardized` rects. Selections built from a drag
    /// can be "backwards" (negative width) before standardization, so do both explicitly.
    public var integralOutward: CGRect {
        let s = standardized
        let minX = s.minX.rounded(.down)
        let minY = s.minY.rounded(.down)
        let maxX = s.maxX.rounded(.up)
        let maxY = s.maxY.rounded(.up)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

/// Aspect-preserving downscale used for the animated-WebP long-edge cap.
public enum OutputSizing {
    /// Fit `size` inside a square of `maxLongEdge` pixels, preserving aspect ratio.
    ///
    /// Never upscales. Always returns at least 1×1 so downstream encoders can't be handed
    /// a zero dimension. Both dimensions are integers because WebP works in whole pixels.
    public static func fit(pixelSize size: CGSize, maxLongEdge: Int) -> CGSize {
        let w = max(1.0, size.width.rounded())
        let h = max(1.0, size.height.rounded())
        guard maxLongEdge > 0 else { return CGSize(width: w, height: h) }
        let longEdge = max(w, h)
        guard longEdge > CGFloat(maxLongEdge) else { return CGSize(width: w, height: h) }

        let factor = CGFloat(maxLongEdge) / longEdge
        return CGSize(
            width: max(1, (w * factor).rounded()),
            height: max(1, (h * factor).rounded())
        )
    }
}
