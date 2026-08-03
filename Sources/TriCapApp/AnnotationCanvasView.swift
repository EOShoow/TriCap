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

    /// Called when a drag (or a text entry) produces a finished annotation.
    var onCommit: ((AnnotationItem) -> Void)?

    private var dragStart: CGPoint?
    private var dragCurrent: CGPoint?
    private var freehandPoints: [CGPoint] = []
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
        else { return }

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
        guard dragStart != nil else { return }
        let point = canvasPoint(from: convert(event.locationInWindow, from: nil))
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
    let onCommit: (AnnotationItem) -> Void

    func makeNSView(context: Context) -> AnnotationCanvasNSView {
        let view = AnnotationCanvasNSView()
        view.onCommit = onCommit
        return view
    }

    func updateNSView(_ view: AnnotationCanvasNSView, context: Context) {
        view.canvasSize = canvasSize
        view.baseImage = baseImage
        view.committedItems = items
        view.tool = tool
        view.style = style
        view.onCommit = onCommit
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
