import AppKit
import CoreGraphics
import ExportCore
import TriCapKit

/// Owns every pinned image.
///
/// One place holds the windows, the memory budget and the transient Escape claim, so "close all"
/// and "the app is quitting" are one call each and cannot leave a window or an event monitor
/// behind. Every teardown path goes through ``close(_:)`` or ``closeAll()``, both idempotent.
@MainActor
final class PinboardController: PinWindowDelegate {

    private var pins: [PinWindow] = []
    /// TriCap's own front-to-back order. `NSApp.windows` is not it — see ``PinFocusOrder``.
    private var focus = PinFocusOrder<UInt64>()
    private let limits: PinLimits
    private var settingsProvider: () -> AppSettings

    /// Escape closes the frontmost pin from anywhere, so a pin parked over another app can be
    /// dismissed without hunting for TriCap. Claimed only while at least one pin exists.
    private var escapeToken: PriorityHotKeyClaim.Token?

    /// Called when the pin count changes, so the menu can enable/disable "Close All Pins".
    var onCountChanged: (() -> Void)?

    init(limits: PinLimits = .default, settingsProvider: @escaping () -> AppSettings) {
        self.limits = limits
        self.settingsProvider = settingsProvider
    }

    var pinCount: Int { pins.count }
    var hasPins: Bool { !pins.isEmpty }
    private var totalPixels: Int { pins.reduce(0) { $0 + $1.pixelCount } }

    // MARK: - Creating

    /// What happened when the user asked for a pin.
    enum PinOutcome: Equatable {
        case pinned(pixelSize: CGSize)
        case nothingToPin(PasteboardImage.ReadFailure)
        case refused(PinLimits.Rejection)

        var userMessage: String {
            switch self {
            case .pinned(let size):
                return "Pinned \(Int(size.width)) × \(Int(size.height))"
            case .nothingToPin(let failure):
                return failure.message
            case .refused(let rejection):
                return rejection.message
            }
        }

        var isSuccess: Bool { if case .pinned = self { return true }; return false }
    }

    /// Pin whatever image is on the clipboard.
    ///
    /// Returns without creating anything when there is no image — an empty floating window is
    /// worse than a one-line notice, because there is nothing in it to explain itself.
    ///
    /// `pasteboard` is a parameter only so the runnable self-test can drive this against a private
    /// pasteboard instead of trampling the user's real clipboard; the app always uses `.general`.
    @discardableResult
    func pinFromClipboard(_ pasteboard: NSPasteboard = .general) -> PinOutcome {
        let image: CGImage
        switch PasteboardImage.read(from: pasteboard) {
        case .failure(let failure):
            TriCapLog.app.info("pin refused: \(failure.message, privacy: .public)")
            return .nothingToPin(failure)
        case .success(let read):
            image = read
        }

        let pixels = image.width * image.height
        if let rejection = limits.admit(
            newImagePixels: pixels, existingCount: pins.count, existingPixels: totalPixels
        ) {
            TriCapLog.app.info("pin refused: \(rejection.message, privacy: .public)")
            return .refused(rejection)
        }

        let anchor = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)

        let frame = PinPlacement.initialFrame(
            imageSize: CGSize(width: image.width, height: image.height),
            anchor: anchor,
            visibleFrame: visible
        )

        let pin = PinWindow(image: image, frame: frame, delegate: self)
        pins.append(pin)
        focus.insert(pin.pinID)   // a new pin is the frontmost one
        // `orderFrontRegardless` rather than `makeKeyAndOrderFront`: showing a pin must not pull
        // focus away from whatever the user is typing in.
        pin.orderFrontRegardless()

        claimEscapeIfNeeded()
        onCountChanged?()

        TriCapLog.app.info(
            "pinned \(image.width, privacy: .public)x\(image.height, privacy: .public) (\(self.pins.count, privacy: .public) open)"
        )
        return .pinned(pixelSize: CGSize(width: image.width, height: image.height))
    }

    // MARK: - Closing

    func close(_ pin: PinWindow) {
        guard let index = pins.firstIndex(where: { $0 === pin }) else { return }
        pins.remove(at: index)
        focus.remove(pin.pinID)
        pin.tearDown()
        releaseEscapeIfIdle()
        onCountChanged?()
    }

    /// Close the most recently created or interacted-with pin — what Escape means when several are
    /// open. The order comes from ``PinFocusOrder``, not from `NSApp.windows`.
    func closeFrontmost() {
        guard let id = focus.frontmost, let pin = pins.first(where: { $0.pinID == id }) else {
            // The order and the window list disagree — close something rather than nothing.
            if let fallback = pins.last { close(fallback) }
            return
        }
        close(pin)
    }

    /// The pin Escape would close. Exposed for the runnable self-test.
    var frontmostPinID: UInt64? { focus.frontmost }

    func closeAll() {
        guard !pins.isEmpty else { return }
        let existing = pins
        pins.removeAll()
        focus.removeAll()
        for pin in existing { pin.tearDown() }
        releaseEscapeIfIdle()
        onCountChanged?()
        TriCapLog.app.info("closed all pins")
    }

    // MARK: - PinWindowDelegate

    func pinDidRequestClose(_ pin: PinWindow) { close(pin) }
    func pinDidRequestCloseAll() { closeAll() }
    func pinDidInteract(_ pin: PinWindow) { focus.touch(pin.pinID) }

    func pinDidRequestCopy(_ pin: PinWindow) {
        guard let image = pin.image else { return }
        _ = PasteboardImage.write(image)
    }

    func pinDidRequestSave(_ pin: PinWindow) {
        guard let image = pin.image else { return }
        let settings = settingsProvider()
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.directoryURL = settings.saveDirectoryURL
        panel.nameFieldStringValue = OutputFileWriter.baseName(
            prefix: settings.filenamePrefix, date: Date()
        ) + ".png"
        panel.allowedContentTypes = [.png]

        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = ImageProcessing.pngData(from: image) else {
            TriCapLog.app.error("pin save failed: could not encode PNG")
            return
        }
        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            TriCapLog.app.error("pin save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Escape claim

    private func claimEscapeIfNeeded() {
        guard !pins.isEmpty, escapeToken == nil else { return }
        escapeToken = SharedEscapeKey.claim.push(priority: .pin) { [weak self] in
            self?.closeFrontmost()
        }
    }

    private func releaseEscapeIfIdle() {
        guard pins.isEmpty else { return }
        SharedEscapeKey.claim.pop(escapeToken)
        escapeToken = nil
    }
}
