import AnnotationCore
import AppKit
import CoreGraphics
import SwiftUI
import TriCapKit

/// The editable canvas: the capture, the committed annotations, and the shape being drawn.
///
/// The view is `isFlipped`, so its coordinate system already matches annotation space (top-left
/// origin, +y down) up to a uniform scale — the only conversion left is the aspect-fit transform
/// between view points and canvas pixels, which lives in ``canvasPoint(from:)``.
final class AnnotationCanvasNSView: NSView {

    var baseImage: CGImage? { didSet { needsDisplay = true } }
    var canvasSize: CGSize = .zero { didSet { needsDisplay = true } }
    var committedItems: [AnnotationItem] = [] { didSet { needsDisplay = true } }
    var tool: AnnotationTool = .arrow
    var style: AnnotationStyle = .default

    /// Committed crop in canvas pixels, drawn as a dimmed surround whenever set.
    var cropRect: CGRect? { didSet { if oldValue != cropRect { needsDisplay = true } } }
    /// While `true`, drags define the crop rectangle instead of drawing annotations.
    var isCropActive = false { didSet { if oldValue != isCropActive { needsDisplay = true } } }

    /// Called when a drag (or a text entry) produces a finished annotation.
    var onCommit: ((AnnotationItem) -> Void)?
    /// Called with the raw drag endpoints (canvas pixels) when a crop drag finishes; the model
    /// normalises and clamps, so the view never decides geometry policy.
    var onCropCommitted: ((CGPoint, CGPoint) -> Void)?

    private var dragStart: CGPoint?
    private var dragCurrent: CGPoint?
    private var freehandPoints: [CGPoint] = []
    private var cropDragStart: CGPoint?
    private var cropDragCurrent: CGPoint?
    private var textField: NSTextField?
    private var textOrigin: CGPoint?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Geometry

    /// Where the capture is drawn inside the view, preserving aspect ratio.
    var imageRect: CGRect {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return bounds }
        let scale = min(bounds.width / canvasSize.width, bounds.height / canvasSize.height)
        let size = CGSize(width: canvasSize.width * scale, height: canvasSize.height * scale)
        return CGRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private var displayScale: CGFloat {
        guard canvasSize.width > 0 else { return 1 }
        return imageRect.width / canvasSize.width
    }

    /// View point → canvas pixel, clamped to the canvas so a drag off the edge still produces a
    /// valid annotation instead of coordinates outside the exported image.
    func canvasPoint(from viewPoint: CGPoint) -> CGPoint {
        let rect = imageRect
        guard rect.width > 0, rect.height > 0 else { return .zero }
        let x = (viewPoint.x - rect.minX) / displayScale
        let y = (viewPoint.y - rect.minY) / displayScale
        return CGPoint(
            x: x.clamped(to: 0...canvasSize.width),
            y: y.clamped(to: 0...canvasSize.height)
        )
    }

    private func viewPoint(fromCanvas point: CGPoint) -> CGPoint {
        let rect = imageRect
        return CGPoint(x: rect.minX + point.x * displayScale, y: rect.minY + point.y * displayScale)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        context.setFillColor(NSColor.underPageBackgroundColor.cgColor)
        context.fill(bounds)

        let rect = imageRect
        guard let baseImage, rect.width > 0, rect.height > 0 else { return }

        // The view is flipped but CGContext is not, so draw the image through an explicit flip.
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.minY + rect.height)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .high
        context.draw(baseImage, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        context.restoreGState()

        // Render annotations at canvas resolution, then scale the result down into the view, so
        // what is on screen is exactly what will be exported.
        var items = committedItems
        if let preview = inProgressItem() { items.append(preview) }
        guard !items.isEmpty,
              let overlayContext = ImageProcessing.makeContext(
                  width: Int(canvasSize.width), height: Int(canvasSize.height)
              )
        else {
            drawCropOverlay(in: context)
            return
        }

        // Transparent overlay: draw onto a copy of the base so alpha handling stays trivial, then
        // blit only the annotated pixels back. Using the base as the backdrop keeps mosaic correct.
        overlayContext.draw(baseImage, in: CGRect(origin: .zero, size: canvasSize))
        AnnotationRenderer.draw(items: items, in: overlayContext, canvasSize: canvasSize)
        guard let overlay = overlayContext.makeImage() else { return }

        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.minY + rect.height)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .high
        context.draw(overlay, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        context.restoreGState()

        drawCropOverlay(in: context)
    }

    /// The crop being displayed right now: the in-progress drag beats the committed rect.
    private var displayedCropRect: CGRect? {
        if let a = cropDragStart, let b = cropDragCurrent {
            return CGRect(from: a, to: b)
        }
        return cropRect
    }

    /// Dim everything the crop will cut away, and outline what stays.
    ///
    /// Deliberately drawn on top of the annotation overlay: the crop is the last step of the
    /// export pipeline, and the preview must stack the same way.
    private func drawCropOverlay(in context: CGContext) {
        guard isCropActive || cropRect != nil else { return }
        guard let crop = displayedCropRect, crop.width >= 1, crop.height >= 1 else { return }

        let image = imageRect
        let scale = displayScale
        let cropView = CGRect(
            x: image.minX + crop.minX * scale,
            y: image.minY + crop.minY * scale,
            width: crop.width * scale,
            height: crop.height * scale
        ).intersection(image)
        guard !cropView.isNull else { return }

        context.saveGState()
        context.setFillColor(NSColor.black.withAlphaComponent(0.5).cgColor)
        // Four side bands instead of even-odd clipping: nothing here may touch the pixels inside
        // the crop, and bands cannot.
        let bands = [
            CGRect(x: image.minX, y: image.minY, width: image.width, height: cropView.minY - image.minY),
            CGRect(x: image.minX, y: cropView.maxY, width: image.width, height: image.maxY - cropView.maxY),
            CGRect(x: image.minX, y: cropView.minY, width: cropView.minX - image.minX, height: cropView.height),
            CGRect(x: cropView.maxX, y: cropView.minY, width: image.maxX - cropView.maxX, height: cropView.height),
        ]
        for band in bands where band.width > 0 && band.height > 0 { context.fill(band) }

        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(1.5)
        context.stroke(cropView.insetBy(dx: 0.75, dy: 0.75))
        context.restoreGState()

        // Live size readout, so the user is not cropping blind.
        let label = "\(Int(crop.width)) × \(Int(crop.height)) px" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = label.size(withAttributes: attributes)
        let badge = CGRect(
            x: cropView.minX,
            y: max(bounds.minY, cropView.minY - size.height - 10),
            width: size.width + 12,
            height: size.height + 6
        )
        context.setFillColor(NSColor.black.withAlphaComponent(0.72).cgColor)
        context.addPath(CGPath(roundedRect: badge, cornerWidth: 5, cornerHeight: 5, transform: nil))
        context.fillPath()
        label.draw(at: CGPoint(x: badge.minX + 6, y: badge.minY + 3), withAttributes: attributes)
    }

    private func inProgressItem() -> AnnotationItem? {
        switch tool {
        case .freehand:
            guard freehandPoints.count >= 2 else { return nil }
            return AnnotationItem(shape: .freehand(points: freehandPoints), style: style)
        case .arrow:
            guard let start = dragStart, let current = dragCurrent else { return nil }
            return AnnotationItem(shape: .arrow(from: start, to: current), style: style)
        case .rectangle:
            guard let start = dragStart, let current = dragCurrent else { return nil }
            return AnnotationItem(shape: .rectangle(CGRect(from: start, to: current)), style: style)
        case .mosaic:
            guard let start = dragStart, let current = dragCurrent else { return nil }
            return AnnotationItem(shape: .mosaic(CGRect(from: start, to: current)), style: style)
        case .text:
            return nil
        }
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        commitPendingText()
        let point = canvasPoint(from: convert(event.locationInWindow, from: nil))

        if isCropActive {
            cropDragStart = point
            cropDragCurrent = point
            needsDisplay = true
            return
        }

        if tool == .text {
            beginTextEntry(at: point)
            return
        }

        dragStart = point
        dragCurrent = point
        freehandPoints = [point]
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = canvasPoint(from: convert(event.locationInWindow, from: nil))
        if cropDragStart != nil {
            cropDragCurrent = point
            needsDisplay = true
            return
        }
        guard dragStart != nil else { return }
        dragCurrent = point
        if tool == .freehand {
            // Coalesce: without this a fast stroke stores thousands of near-identical points,
            // which bloats the undo snapshots for no visual gain.
            if let last = freehandPoints.last, hypot(point.x - last.x, point.y - last.y) < 1.5 { return }
            freehandPoints.append(point)
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let start = cropDragStart {
            let end = canvasPoint(from: convert(event.locationInWindow, from: nil))
            cropDragStart = nil
            cropDragCurrent = nil
            needsDisplay = true
            onCropCommitted?(start, end)
            return
        }
        defer {
            dragStart = nil
            dragCurrent = nil
            freehandPoints = []
            needsDisplay = true
        }
        guard dragStart != nil else { return }
        dragCurrent = canvasPoint(from: convert(event.locationInWindow, from: nil))
        if let item = inProgressItem() { onCommit?(item) }
    }

    // MARK: - Text entry

    private func beginTextEntry(at point: CGPoint) {
        let field = NSTextField(frame: .zero)
        field.isBordered = true
        field.bezelStyle = .roundedBezel
        field.font = NSFont.systemFont(ofSize: max(11, style.fontSize * displayScale), weight: .semibold)
        field.textColor = NSColor(cgColor: style.color.cgColor) ?? .systemRed
        field.placeholderString = "Text"
        field.target = self
        field.action = #selector(textFieldCommitted(_:))

        let origin = viewPoint(fromCanvas: point)
        let width = min(320, max(120, imageRect.maxX - origin.x))
        field.frame = CGRect(x: origin.x, y: origin.y, width: width, height: max(24, style.fontSize * displayScale + 10))

        addSubview(field)
        window?.makeFirstResponder(field)
        textField = field
        textOrigin = point
    }

    @objc private func textFieldCommitted(_ sender: NSTextField) {
        commitPendingText()
    }

    /// Commit whatever is in the floating text field and remove it.
    func commitPendingText() {
        guard let field = textField, let origin = textOrigin else { return }
        let string = field.stringValue
        textField = nil
        textOrigin = nil
        field.removeFromSuperview()
        window?.makeFirstResponder(self)

        guard !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        onCommit?(AnnotationItem(shape: .text(origin: origin, string: string), style: style))
    }

    override func cancelOperation(_ sender: Any?) {
        if textField != nil {
            textField?.removeFromSuperview()
            textField = nil
            textOrigin = nil
            window?.makeFirstResponder(self)
            needsDisplay = true
        }
    }
}

/// SwiftUI bridge for ``AnnotationCanvasNSView``.
struct AnnotationCanvas: NSViewRepresentable {
    let baseImage: CGImage?
    let canvasSize: CGSize
    let items: [AnnotationItem]
    let tool: AnnotationTool
    let style: AnnotationStyle
    let cropRect: CGRect?
    let isCropActive: Bool
    let onCommit: (AnnotationItem) -> Void
    let onCropCommitted: (CGPoint, CGPoint) -> Void

    func makeNSView(context: Context) -> AnnotationCanvasNSView {
        let view = AnnotationCanvasNSView()
        view.onCommit = onCommit
        view.onCropCommitted = onCropCommitted
        return view
    }

    func updateNSView(_ view: AnnotationCanvasNSView, context: Context) {
        view.canvasSize = canvasSize
        view.baseImage = baseImage
        view.committedItems = items
        view.tool = tool
        view.style = style
        view.cropRect = cropRect
        view.isCropActive = isCropActive
        view.onCommit = onCommit
        view.onCropCommitted = onCropCommitted
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
