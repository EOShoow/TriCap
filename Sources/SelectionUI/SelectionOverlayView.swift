import AppKit
import TriCapKit

/// Callbacks the overlay view sends to its controller. All points are in **AppKit global points**.
@MainActor
protocol SelectionOverlayDelegate: AnyObject {
    func overlayDidBeginDrag(at point: CGPoint)
    func overlayDidDrag(to point: CGPoint)
    func overlayDidEndDrag(at point: CGPoint)
    func overlayDidCancel()
    /// `nil` toggles; an explicit value selects that mode.
    func overlayDidRequestMode(_ requested: RegionSelector.CaptureMode?)
}

/// One full-screen dimming layer with the live selection rectangle punched out of it.
///
/// There is one of these per display. They all draw the *same* global selection rect, so a drag
/// that starts on one monitor and ends on another looks like a single continuous rectangle.
public final class SelectionOverlayView: NSView {

    weak var delegate: (any SelectionOverlayDelegate)?

    /// Current selection in AppKit global points, or `nil` before the first drag.
    public var globalSelection: CGRect? {
        didSet { if oldValue != globalSelection { needsDisplay = true } }
    }

    /// Pixel size of the current selection, shown in the readout. `nil` hides the readout.
    public var selectionPixelSize: CGSize? {
        didSet { if oldValue != selectionPixelSize { needsDisplay = true } }
    }

    /// Short instruction shown while nothing is selected yet.
    public var hintText: String = "Drag to select a region · Esc to cancel" {
        didSet { if oldValue != hintText { needsDisplay = true } }
    }

    /// Tints the selection border red so the mode is obvious before the user commits.
    public var isRecordingMode = false {
        didSet { if oldValue != isRecordingMode { needsDisplay = true } }
    }

    private var isDragging = false

    public override init(frame frameRect: NSRect) { super.init(frame: frameRect) }
    public required init?(coder: NSCoder) { super.init(coder: coder) }

    override public var acceptsFirstResponder: Bool { true }
    override public var isFlipped: Bool { false }
    override public func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Drawing

    override public func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        context.setFillColor(NSColor.black.withAlphaComponent(0.35).cgColor)
        context.fill(bounds)

        guard let selection = globalSelection else {
            drawHint(in: context)
            return
        }

        let local = convertFromGlobal(selection)
        let visible = local.intersection(bounds)
        guard !visible.isNull, visible.width > 0, visible.height > 0 else { return }

        // Punch the selection out of the dimming layer so the user sees the real pixels.
        context.setBlendMode(.copy)
        context.setFillColor(NSColor.clear.cgColor)
        context.fill(visible)
        context.setBlendMode(.normal)

        context.setStrokeColor((isRecordingMode ? NSColor.systemRed : NSColor.controlAccentColor).cgColor)
        // Hairline at the display's native resolution. Falls back to 1 pt when the view has no
        // window, which happens only in the offscreen UI-snapshot renderer.
        context.setLineWidth(1.0 / max(1, window?.backingScaleFactor ?? 1))
        context.stroke(visible.insetBy(dx: 0.5, dy: 0.5))

        drawReadout(near: visible, in: context)
    }

    private func drawHint(in context: CGContext) {
        guard !isDragging else { return }
        let text = hintText as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attributes)
        let origin = CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2)
        let padded = CGRect(origin: origin, size: size).insetBy(dx: -14, dy: -10)

        context.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
        let path = CGPath(roundedRect: padded, cornerWidth: 8, cornerHeight: 8, transform: nil)
        context.addPath(path)
        context.fillPath()

        text.draw(at: origin, withAttributes: attributes)
    }

    /// `1280 × 800 px` badge pinned just outside the selection.
    private func drawReadout(near rect: CGRect, in context: CGContext) {
        guard let pixelSize = selectionPixelSize, pixelSize.width >= 1, pixelSize.height >= 1 else { return }

        let text = "\(Int(pixelSize.width)) × \(Int(pixelSize.height)) px" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attributes)

        // Prefer above the selection; fall back to inside it when there is no room.
        var origin = CGPoint(x: rect.minX, y: rect.maxY + 8)
        if origin.y + size.height > bounds.maxY { origin.y = rect.maxY - size.height - 8 }
        origin.x = min(max(bounds.minX + 6, origin.x), bounds.maxX - size.width - 6)

        let badge = CGRect(origin: origin, size: size).insetBy(dx: -8, dy: -5)
        context.setFillColor(NSColor.black.withAlphaComponent(0.72).cgColor)
        context.addPath(CGPath(roundedRect: badge, cornerWidth: 5, cornerHeight: 5, transform: nil))
        context.fillPath()

        text.draw(at: origin, withAttributes: attributes)
    }

    // MARK: - Coordinate helpers

    /// AppKit global points → this view's coordinates.
    private func convertFromGlobal(_ rect: CGRect) -> CGRect {
        guard let window else { return rect }
        let windowRect = window.convertFromScreen(rect)
        return convert(windowRect, from: nil)
    }

    private func globalPoint(for event: NSEvent) -> CGPoint {
        guard let window else { return event.locationInWindow }
        return window.convertPoint(toScreen: event.locationInWindow)
    }

    // MARK: - Events

    override public func mouseDown(with event: NSEvent) {
        isDragging = true
        delegate?.overlayDidBeginDrag(at: globalPoint(for: event))
    }

    override public func mouseDragged(with event: NSEvent) {
        delegate?.overlayDidDrag(to: globalPoint(for: event))
    }

    override public func mouseUp(with event: NSEvent) {
        isDragging = false
        delegate?.overlayDidEndDrag(at: globalPoint(for: event))
    }

    override public func rightMouseDown(with event: NSEvent) {
        delegate?.overlayDidCancel()
    }

    /// Esc arrives here via the responder chain's `cancelOperation:` action.
    override public func cancelOperation(_ sender: Any?) {
        delegate?.overlayDidCancel()
    }

    override public func keyDown(with event: NSEvent) {
        // 53 == kVK_Escape. Handled explicitly as well as via cancelOperation so the overlay
        // still cancels if the key equivalent is swallowed elsewhere.
        if event.keyCode == 53 {
            delegate?.overlayDidCancel()
            return
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "r":
            delegate?.overlayDidRequestMode(.recording)
        case "s":
            delegate?.overlayDidRequestMode(.still)
        case " ", "\t":
            delegate?.overlayDidRequestMode(nil)
        default:
            super.keyDown(with: event)
        }
    }

    override public func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }
}

/// Borderless, click-through-proof window that sits above everything including the menu bar.
final class SelectionOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
