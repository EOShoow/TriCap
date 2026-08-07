import CoreGraphics
import Foundation

/// Geometry for the editor's crop rectangle.
///
/// Crop rects live in **canvas pixel space** (top-left origin, +y down — the same space as
/// annotations), and they are always integral: the exported bitmap is cut with
/// `CGImage.cropping(to:)`, which works on whole pixels, so a fractional rect would silently
/// shift the cut by up to a pixel relative to what the editor displayed.
public enum CropGeometry {

    /// Smaller than this on either edge and a drag is treated as a slip, not a crop.
    public static let minimumEdge: CGFloat = 8

    /// Turn a drag (any corner order, possibly beyond the canvas) into a committed crop rect.
    ///
    /// Returns `nil` for a degenerate drag — the caller should keep whatever crop was already
    /// set, so a stray click in crop mode never destroys a carefully placed rectangle.
    public static func cropRect(
        dragFrom a: CGPoint,
        to b: CGPoint,
        canvasSize: CGSize,
        minimumEdge: CGFloat = CropGeometry.minimumEdge
    ) -> CGRect? {
        guard canvasSize.width >= 1, canvasSize.height >= 1 else { return nil }
        let canvas = CGRect(origin: .zero, size: canvasSize)
        let raw = CGRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(a.x - b.x),
            height: abs(a.y - b.y)
        ).intersection(canvas)
        guard !raw.isNull else { return nil }

        // Round each edge to the nearest pixel boundary, then re-clamp: rounding can push an
        // edge one pixel past the canvas.
        let minX = raw.minX.rounded().clamped(to: 0...canvasSize.width)
        let minY = raw.minY.rounded().clamped(to: 0...canvasSize.height)
        let maxX = raw.maxX.rounded().clamped(to: 0...canvasSize.width)
        let maxY = raw.maxY.rounded().clamped(to: 0...canvasSize.height)
        let rect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)

        guard rect.width >= minimumEdge, rect.height >= minimumEdge else { return nil }
        return rect
    }

    /// The crop that actually changes anything, or `nil`.
    ///
    /// A rect covering the whole canvas is no crop at all — treating it as one would make the
    /// export take the slow path (and re-encode a pre-encoded animation) for a no-op.
    public static func effectiveCrop(_ rect: CGRect?, canvasSize: CGSize) -> CGRect? {
        guard let rect else { return nil }
        let canvas = CGRect(origin: .zero, size: canvasSize)
        let clamped = rect.intersection(canvas)
        guard !clamped.isNull, clamped.width >= 1, clamped.height >= 1 else { return nil }
        return clamped == canvas ? nil : clamped
    }

    /// Whether `rect` is a valid crop for `canvasSize`: integral, non-empty, inside the canvas.
    /// The export path refuses anything else rather than guessing.
    public static func isValid(_ rect: CGRect, canvasSize: CGSize) -> Bool {
        guard rect.minX == rect.minX.rounded(), rect.minY == rect.minY.rounded(),
              rect.width == rect.width.rounded(), rect.height == rect.height.rounded(),
              rect.width >= 1, rect.height >= 1
        else { return false }
        return CGRect(origin: .zero, size: canvasSize).contains(rect)
    }
}
