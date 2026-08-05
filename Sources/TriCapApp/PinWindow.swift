import AppKit
import CoreGraphics
import ExportCore
import TriCapKit

/// A pinned image: a borderless floating window showing one bitmap.
///
/// **Window level.** `.floating` — above ordinary application windows, below the menu bar, the
/// Dock, and every system panel. Deliberately *not* `.screenSaver` or `CGShieldingWindowLevel()`,
/// which the selection overlay uses: a pin is content the user parked somewhere, and content must
/// never be able to cover a password prompt, a permission sheet, or the login window.
///
/// **Focus.** The panel is non-activating and `canBecomeKey` is false, so clicking or dragging a
/// pin never takes keyboard focus from whatever the user is typing in. Escape is therefore handled
/// by the owning controller's transient hot key rather than by this window's responder chain.
@MainActor
final class PinWindow: NSPanel {

    /// The pinned bitmap, or `nil` once the pin has been torn down.
    ///
    /// Deliberately not a `let`. AppKit keeps a window that has been on screen alive for a while
    /// after `close()` — for its own bookkeeping, not because anything here still owns it — and a
    /// full-resolution screenshot is megabytes. ``tearDown()`` drops the pixels immediately so the
    /// memory goes back regardless of when the empty window shell finally disappears.
    private(set) var image: CGImage?

    let imagePixelSize: CGSize
    /// Pixels this pin contributes to the memory budget. Fixed at creation, so the budget still
    /// balances while a pin is being torn down.
    let pixelCount: Int

    /// Stable identity for `PinFocusOrder`. Deliberately not the window number: TriCap tracks its
    /// own front-to-back order rather than trusting `NSApp.windows`.
    let pinID: UInt64
    private static var nextPinID: UInt64 = 1

    private let imageView = NSImageView()
    private var dragOffset: CGPoint?
    private weak var pinDelegate: (any PinWindowDelegate)?

    // A pin must not steal focus, so it never becomes key or main.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(image: CGImage, frame: NSRect, delegate: any PinWindowDelegate) {
        self.image = image
        self.imagePixelSize = CGSize(width: image.width, height: image.height)
        self.pixelCount = image.width * image.height
        self.pinID = Self.nextPinID
        Self.nextPinID += 1
        self.pinDelegate = delegate

        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = false  // handled manually, so the drag can be clamped
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let content = PinContentView(frame: NSRect(origin: .zero, size: frame.size))
        content.owner = self
        content.wantsLayer = true
        // The old 4 pt radius read as barely-not-square. The shared radius is deliberately larger
        // than an ordinary macOS window corner, so a captured window's own rounded border cannot
        // bleed through at the pin edge. Apple's continuous curvature keeps the four corners
        // uniform; tiny pins clamp so they cannot become capsules. Display-only: Copy and Save use
        // the untouched bitmap.
        content.layer?.cornerRadius = PinAppearance.effectiveCornerRadius(for: frame.size)
        content.layer?.cornerCurve = .continuous
        content.layer?.masksToBounds = true

        imageView.image = NSImage(cgImage: image, size: imagePixelSize)
        imageView.imageScaling = .scaleAxesIndependently
        imageView.frame = content.bounds
        imageView.autoresizingMask = [.width, .height]
        content.addSubview(imageView)

        contentView = content
    }

    /// Called by the content view on every user interaction: tell the controller, and come forward
    /// so what the user sees matches what Escape will close.
    fileprivate func noteInteraction() {
        pinDelegate?.pinDidInteract(self)
        orderFrontRegardless()
    }

    // MARK: - Teardown

    /// Release everything this pin holds and close the window. Idempotent.
    ///
    /// Ordering matters: the bitmap has to be dropped from *both* the image view and this window's
    /// own reference, otherwise closing merely hides a window that is still holding a screenshot.
    func tearDown() {
        endDrag()
        orderOut(nil)
        imageView.image = nil
        contentView = nil
        image = nil
        pinDelegate = nil
        close()
    }

    // MARK: - Interaction

    func beginDrag(at screenPoint: CGPoint) {
        dragOffset = CGPoint(x: screenPoint.x - frame.minX, y: screenPoint.y - frame.minY)
    }

    func continueDrag(to screenPoint: CGPoint) {
        guard let dragOffset else { return }
        let proposed = CGRect(
            origin: CGPoint(x: screenPoint.x - dragOffset.x, y: screenPoint.y - dragOffset.y),
            size: frame.size
        )
        setFrame(PinPlacement.clampReachable(proposed, within: visibleFrameForCurrentScreen()), display: true)
    }

    func endDrag() { dragOffset = nil }

    /// Zoom around `anchor` (screen coordinates) by a multiplicative `factor`.
    func zoom(by factor: CGFloat, anchor: CGPoint) {
        let current = PinZoom.scale(of: frame, imageSize: imagePixelSize)
        let proposed = PinZoom.clamp(current * factor)
        guard proposed != current else { return }
        applyScale(proposed, anchor: anchor)
    }

    /// Re-derive the (clamped) radius after any size change, so a pin zoomed far down still
    /// rounds sensibly and everything else keeps the one shared radius.
    private func refreshCornerRadius() {
        contentView?.layer?.cornerRadius = PinAppearance.effectiveCornerRadius(for: frame.size)
        invalidateShadow()
    }

    func applyScale(_ scale: CGFloat, anchor: CGPoint? = nil) {
        let anchorPoint = anchor ?? CGPoint(x: frame.midX, y: frame.midY)
        let proposed = PinZoom.frame(
            forScale: scale,
            imageSize: imagePixelSize,
            currentFrame: frame,
            anchor: anchorPoint
        )
        setFrame(PinPlacement.clampReachable(proposed, within: visibleFrameForCurrentScreen()), display: true)
        refreshCornerRadius()
    }

    func showAtOriginalSize() {
        applyScale(1)
    }

    func fitToScreen() {
        let visible = visibleFrameForCurrentScreen()
        let scale = PinPlacement.fitScale(imageSize: imagePixelSize, in: visible)
        applyScale(scale)
        setFrame(PinPlacement.clampFullyOnScreen(frame, within: visible), display: true)
        refreshCornerRadius()
    }

    func setPinOpacity(_ value: CGFloat) {
        alphaValue = PinOpacity.clamp(value)
    }

    var pinOpacity: CGFloat { alphaValue }

    private func visibleFrameForCurrentScreen() -> CGRect {
        screen?.visibleFrame
            ?? NSScreen.screens.first(where: { $0.frame.intersects(frame) })?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    }

    // MARK: - Menu actions

    @objc func actionOriginalSize() { showAtOriginalSize() }
    @objc func actionFitToScreen() { fitToScreen() }
    @objc func actionCopy() { pinDelegate?.pinDidRequestCopy(self) }
    @objc func actionSave() { pinDelegate?.pinDidRequestSave(self) }
    @objc func actionClose() { pinDelegate?.pinDidRequestClose(self) }
    @objc func actionCloseAll() { pinDelegate?.pinDidRequestCloseAll() }

    @objc func actionSetOpacity(_ sender: NSMenuItem) {
        setPinOpacity(CGFloat(sender.tag) / 100.0)
    }

    func makeContextMenu() -> NSMenu {
        let menu = NSMenu()

        menu.addItem(item("Original Size", #selector(actionOriginalSize)))
        menu.addItem(item("Fit to Screen", #selector(actionFitToScreen)))
        menu.addItem(.separator())
        menu.addItem(item("Copy", #selector(actionCopy)))
        menu.addItem(item("Save…", #selector(actionSave)))
        menu.addItem(.separator())

        let opacity = NSMenu()
        for step in PinOpacity.steps {
            let entry = NSMenuItem(
                title: PinOpacity.label(for: step),
                action: #selector(actionSetOpacity(_:)),
                keyEquivalent: ""
            )
            entry.target = self
            entry.tag = Int((step * 100).rounded())
            entry.state = abs(pinOpacity - step) < 0.01 ? .on : .off
            opacity.addItem(entry)
        }
        let opacityItem = NSMenuItem(title: "Opacity", action: nil, keyEquivalent: "")
        opacityItem.submenu = opacity
        menu.addItem(opacityItem)

        menu.addItem(.separator())
        menu.addItem(item("Close", #selector(actionClose)))
        menu.addItem(item("Close All Pins", #selector(actionCloseAll)))
        return menu
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = self
        return entry
    }
}

@MainActor
protocol PinWindowDelegate: AnyObject {
    func pinDidRequestClose(_ pin: PinWindow)
    func pinDidRequestCloseAll()
    func pinDidRequestCopy(_ pin: PinWindow)
    func pinDidRequestSave(_ pin: PinWindow)
    /// The user touched this pin — clicked, dragged, scrolled, pinched or right-clicked it. The
    /// controller uses this to keep its own front-to-back order, since a non-activating panel
    /// generates no key/main-window notifications to infer it from.
    func pinDidInteract(_ pin: PinWindow)
}

/// The pin's content view: drags, scroll/pinch zoom, and the context menu.
private final class PinContentView: NSView {
    weak var owner: PinWindow?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { false }

    private func screenPoint(for event: NSEvent) -> CGPoint {
        guard let window else { return event.locationInWindow }
        return window.convertPoint(toScreen: event.locationInWindow)
    }

    override func mouseDown(with event: NSEvent) {
        owner?.noteInteraction()
        owner?.beginDrag(at: screenPoint(for: event))
    }

    override func mouseDragged(with event: NSEvent) {
        owner?.continueDrag(to: screenPoint(for: event))
    }

    override func mouseUp(with event: NSEvent) {
        owner?.endDrag()
    }

    override func scrollWheel(with event: NSEvent) {
        guard let owner else { return }
        owner.noteInteraction()
        // A trackpad reports fractional precise deltas; a mouse wheel reports whole lines. Both
        // end up as a small multiplicative step so the feel is comparable.
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 300.0 : event.scrollingDeltaY / 20.0
        guard delta != 0 else { return }
        owner.zoom(by: 1 + delta, anchor: screenPoint(for: event))
    }

    override func magnify(with event: NSEvent) {
        guard let owner else { return }
        owner.noteInteraction()
        owner.zoom(by: 1 + event.magnification, anchor: screenPoint(for: event))
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        owner?.noteInteraction()
        return owner?.makeContextMenu()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }
}
