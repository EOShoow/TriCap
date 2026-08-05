import AppKit
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreText
import Foundation
import TriCapKit

/// Rasterises annotations onto an image.
///
/// The renderer is deliberately the *only* place that knows about the y-flip between annotation
/// space (top-left origin, +y down, matching the editor view and the user's mental model) and
/// `CGContext` space (bottom-left origin, +y up). Everything upstream stays in one space.
///
/// For animated captures the very same item list is drawn onto **every** frame, which is what
/// makes annotations a fixed overlay rather than something that drifts frame to frame.
public enum AnnotationRenderer {

    /// Draw `base` and then every annotation, returning a new opaque sRGB image.
    public static func render(items: [AnnotationItem], onto base: CGImage) -> CGImage? {
        let width = base.width
        let height = base.height
        guard let context = ImageProcessing.makeContext(width: width, height: height) else { return nil }
        context.interpolationQuality = .high
        context.draw(base, in: CGRect(x: 0, y: 0, width: width, height: height))
        draw(items: items, in: context, canvasSize: CGSize(width: width, height: height))
        return context.makeImage()
    }

    /// Draw the annotation stack into an existing context whose contents are already the base image.
    ///
    /// `canvasSize` is in canvas pixels and must match the context's pixel size; the flip below
    /// depends on it.
    public static func draw(items: [AnnotationItem], in context: CGContext, canvasSize: CGSize) {
        guard !items.isEmpty else { return }

        context.saveGState()
        // One flip for the whole stack: after this, drawing in annotation coordinates
        // (top-left origin, +y down) lands where the user expects.
        context.translateBy(x: 0, y: canvasSize.height)
        context.scaleBy(x: 1, y: -1)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        for item in items {
            switch item.shape {
            case .arrow(let from, let to):
                drawArrow(from: from, to: to, style: item.style, in: context)
            case .rectangle(let rect):
                drawRectangle(rect, style: item.style, in: context)
            case .freehand(let points):
                drawFreehand(points, style: item.style, in: context)
            case .text(let origin, let string):
                drawText(string, at: origin, style: item.style, in: context)
            case .mosaic(let rect):
                // Mosaic samples whatever has been drawn so far — base image *and* earlier
                // annotations — so redacting on top of a highlight actually redacts it.
                drawMosaic(rect, style: item.style, in: context, canvasSize: canvasSize)
            }
        }

        context.restoreGState()
    }

    // MARK: - Individual shapes

    private static func drawArrow(from: CGPoint, to: CGPoint, style: AnnotationStyle, in ctx: CGContext) {
        let dx = to.x - from.x
        let dy = to.y - from.y
        let length = hypot(dx, dy)
        guard length > 0.5 else { return }

        let angle = atan2(dy, dx)
        // Head scales with the stroke so thin arrows do not get a comically large head.
        let headLength = min(max(style.lineWidth * 4.0, 12.0), length * 0.6)
        let headHalfWidth = headLength * 0.42
        let shaftEnd = CGPoint(
            x: to.x - cos(angle) * headLength * 0.85,
            y: to.y - sin(angle) * headLength * 0.85
        )

        ctx.setStrokeColor(style.color.cgColor)
        ctx.setFillColor(style.color.cgColor)
        ctx.setLineWidth(style.lineWidth)

        ctx.beginPath()
        ctx.move(to: from)
        ctx.addLine(to: shaftEnd)
        ctx.strokePath()

        ctx.beginPath()
        ctx.move(to: to)
        ctx.addLine(to: CGPoint(
            x: to.x - cos(angle - .pi / 2) * headHalfWidth - cos(angle) * headLength,
            y: to.y - sin(angle - .pi / 2) * headHalfWidth - sin(angle) * headLength
        ))
        ctx.addLine(to: CGPoint(
            x: to.x + cos(angle - .pi / 2) * headHalfWidth - cos(angle) * headLength,
            y: to.y + sin(angle - .pi / 2) * headHalfWidth - sin(angle) * headLength
        ))
        ctx.closePath()
        ctx.fillPath()
    }

    private static func drawRectangle(_ rect: CGRect, style: AnnotationStyle, in ctx: CGContext) {
        let r = rect.standardized
        guard r.width > 0, r.height > 0 else { return }
        if style.filled {
            ctx.setFillColor(style.color.cgColor)
            ctx.fill(r)
        } else {
            ctx.setStrokeColor(style.color.cgColor)
            ctx.setLineWidth(style.lineWidth)
            // Inset by half the stroke so the drawn outline stays inside the dragged rect.
            ctx.stroke(r.insetBy(dx: style.lineWidth / 2, dy: style.lineWidth / 2))
        }
    }

    private static func drawFreehand(_ points: [CGPoint], style: AnnotationStyle, in ctx: CGContext) {
        guard points.count >= 2 else { return }
        ctx.setStrokeColor(style.color.cgColor)
        ctx.setLineWidth(style.lineWidth)
        ctx.beginPath()
        ctx.move(to: points[0])
        for point in points.dropFirst() { ctx.addLine(to: point) }
        ctx.strokePath()
    }

    /// Text is drawn through CoreText so the renderer works identically inside and outside a
    /// view hierarchy (annotation compositing for animated frames happens off the main thread).
    private static func drawText(_ string: String, at origin: CGPoint, style: AnnotationStyle, in ctx: CGContext) {
        guard !string.isEmpty else { return }

        let font = NSFont.systemFont(ofSize: style.fontSize, weight: .semibold)
        let lines = string.components(separatedBy: .newlines)
        let lineHeight = style.fontSize * 1.25

        for (index, line) in lines.enumerated() where !line.isEmpty {
            let attributed = NSAttributedString(string: line, attributes: [
                .font: font,
                .foregroundColor: NSColor(cgColor: style.color.cgColor) ?? .systemRed,
            ])
            let ctLine = CTLineCreateWithAttributedString(attributed)

            // The context is y-flipped for annotation space, so flip the text matrix back to
            // keep glyphs upright, and position the baseline manually.
            ctx.saveGState()
            let baselineY = origin.y + lineHeight * CGFloat(index) + style.fontSize
            ctx.translateBy(x: origin.x, y: baselineY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.textPosition = .zero
            CTLineDraw(ctLine, ctx)
            ctx.restoreGState()
        }
    }

    /// One `CIContext` for every mosaic ever drawn.
    ///
    /// Creating a context per frame would rebuild the GPU pipeline 181 times per animated export;
    /// `CIContext` is documented immutable and thread-safe, so a single shared instance serves the
    /// still path (main thread) and animated-frame compositing (detached task) simultaneously —
    /// pinned by the concurrent-render test. `CIFilter` instances are *not* thread-safe and are
    /// created per call, which is cheap.
    ///
    /// Working and output space are both sRGB, matching the renderer's canvas, so no conversion
    /// sneaks in between the snapshot and the redraw.
    /// The `@unchecked Sendable` box exists for SDK portability, not as a shortcut: `CIContext`
    /// is documented immutable and thread-safe, and the concurrent-render test pins that six
    /// parallel renders through this one context produce byte-identical output. The macOS 26 SDK
    /// marks `CIContext` `Sendable` (so a bare `static let` compiles there, and an explicit
    /// `nonisolated(unsafe)` draws an "unnecessary" warning); the macOS 15 SDK does not, and a
    /// bare `static let` fails Swift 6's concurrency check — the exact build failure a tester hit
    /// on macOS 15.6. The box compiles clean on both.
    private struct SendableCIContext: @unchecked Sendable { let context: CIContext }
    private static var mosaicContext: CIContext { mosaicContextBox.context }
    private static let mosaicContextBox: SendableCIContext = {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        return SendableCIContext(context: CIContext(options: [
            .workingColorSpace: srgb,
            .outputColorSpace: srgb,
            .cacheIntermediates: false,
        ]))
    }()

    /// Pixelate a region with Core Image's `CIPixellate`.
    ///
    /// This replaced a hand-written crop→downscale→nearest-neighbour-upscale implementation whose
    /// crop rect was double-flipped — `CGImage.cropping(to:)` already works in row space, where an
    /// annotation-space rect needs no conversion — so it pixelated the **vertically mirrored**
    /// band. Over a mostly-light page that painted large white blocks unrelated to the covered
    /// content. `scripts/diagnostics/mosaic-mirror-probe.swift` reproduces the defect standalone;
    /// `MosaicTests` pins the fix.
    ///
    /// Geometry notes, all pinned by tests:
    /// - `CIImage` coordinates are bottom-left-origin, so the annotation-space rect converts once,
    ///   explicitly, into `ciRect`.
    /// - The input is clamped to its extent before filtering so edge blocks sample real pixels
    ///   rather than the transparent void beyond the image — no dark or hollow fringes.
    /// - The pixel grid is anchored to the canvas's top-left corner, not to the rect, so dragging
    ///   or trimming the region never makes the grid crawl.
    ///
    /// This is visual obscuration, **not** security-grade redaction: a pixelated block is a
    /// deterministic function of the pixels beneath it. For secrets, cover with a filled
    /// rectangle instead.
    private static func drawMosaic(_ rect: CGRect, style: AnnotationStyle, in ctx: CGContext, canvasSize: CGSize) {
        let r = rect.standardized.integralOutward
            .intersection(CGRect(origin: .zero, size: canvasSize))
        guard !r.isNull, r.width >= 1, r.height >= 1 else { return }

        // Snapshot the whole canvas: the mosaic must sample the base image *and* every annotation
        // drawn before it, or redacting on top of a highlight would not redact the highlight.
        guard let snapshot = ctx.makeImage() else { return }

        let filter = CIFilter.pixellate()
        filter.inputImage = CIImage(cgImage: snapshot).clampedToExtent()
        filter.scale = Float(max(2, style.mosaicBlockSize))
        // Canvas top-left in Core Image's bottom-left-origin space: the grid anchor. (Pixellate
        // samples each block at its centre, with blocks tiled from `center` — probed empirically,
        // see the placement tests.)
        filter.center = CGPoint(x: 0, y: canvasSize.height)

        // Render the WHOLE pixellated canvas and cut the band afterwards, in CGImage row space —
        // where the annotation-space rect needs no conversion at all. Cropping the *CIImage*
        // output to the band instead returned wrong pixels whenever a block's centre sample point
        // fell outside the crop (probed: a 100-px block cropped at x ≥ 60 came back with the
        // neighbouring block's colour), and a band crop excludes sample points routinely once the
        // block size approaches the band size.
        let fullExtent = CGRect(origin: .zero, size: canvasSize)
        guard let output = filter.outputImage?.cropped(to: fullExtent),
              let fullPixelated = mosaicContext.createCGImage(
                  output,
                  from: fullExtent,
                  format: .RGBA8,
                  colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
              ),
              let pixelated = fullPixelated.cropping(to: r) else { return }

        ctx.saveGState()
        ctx.interpolationQuality = .none
        // Undo the outer flip for this one draw: `ctx.draw` would otherwise paint the pixelated
        // tile upside-down inside the mosaic rect.
        ctx.translateBy(x: r.midX, y: r.midY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(pixelated, in: CGRect(x: -r.width / 2, y: -r.height / 2, width: r.width, height: r.height))
        ctx.restoreGState()
    }
}
