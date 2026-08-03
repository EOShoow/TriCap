import AppKit
import CaptureCore
import TriCapKit

/// Floating panels shown around a recording: the pre-roll countdown and the live stop control.
///
/// Both are `sharingType = .none`, and the capture filter already excludes TriCap's own windows,
/// so neither ends up inside the recording.
@MainActor
public final class RecordingHUD {

    private var countdownWindow: NSWindow?
    private var hudWindow: NSWindow?
    private var elapsedLabel: NSTextField?
    private var frameLabel: NSTextField?
    private var borderWindow: NSWindow?
    private var escapeNotice: NSTextField?
    private var hintLabel: NSTextField?
    private var progressBar: NSProgressIndicator?
    private var countdownHintLabel: NSTextField?

    /// One proxy per HUD instance. A shared singleton would let a second recording's HUD rebind
    /// the first one's Stop button.
    private let stopProxy = HUDStopProxy()

    public init() {}

    // MARK: - Countdown

    /// Count `seconds` down over the selection. Returns `false` if the user pressed Esc.
    public func runCountdown(seconds: Int, over region: CaptureRegion) async -> Bool {
        guard seconds > 0 else { return true }

        let window = makeFloatingWindow(size: CGSize(width: 180, height: 176), centeredOn: region)
        let label = NSTextField(labelWithString: "\(seconds)")
        label.font = .systemFont(ofSize: 84, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.frame = CGRect(x: 0, y: 52, width: 180, height: 100)
        window.contentView?.addSubview(label)

        let caption = NSTextField(labelWithString: "Recording starts…")
        caption.font = .systemFont(ofSize: 12, weight: .medium)
        caption.textColor = NSColor.white.withAlphaComponent(0.85)
        caption.alignment = .center
        caption.frame = CGRect(x: 0, y: 32, width: 180, height: 18)
        window.contentView?.addSubview(caption)

        let cancelHint = NSTextField(labelWithString: "Esc to cancel")
        cancelHint.font = .systemFont(ofSize: 11)
        cancelHint.textColor = NSColor.white.withAlphaComponent(0.6)
        cancelHint.alignment = .center
        cancelHint.frame = CGRect(x: 0, y: 14, width: 180, height: 16)
        window.contentView?.addSubview(cancelHint)
        countdownHintLabel = cancelHint
        window.orderFrontRegardless()
        countdownWindow = window

        let cancelled = CancelWatcher()
        defer {
            cancelled.stop()
            window.orderOut(nil)
            window.close()
            countdownWindow = nil
        }

        for remaining in stride(from: seconds, through: 1, by: -1) {
            label.stringValue = "\(remaining)"
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } catch {
                return false
            }
            if cancelled.wasCancelled { return false }
        }
        return !cancelled.wasCancelled
    }

    // MARK: - Live HUD

    /// Show the stop control and the region outline. `onStop` fires when the user clicks Stop.
    public func showRecordingHUD(region: CaptureRegion, onStop: @escaping () -> Void) {
        showRegionOutline(region)

        let window = makeFloatingWindow(size: Self.hudSize, belowTopOf: region)
        guard let content = window.contentView else { return }
        populateHUD(content, onStop: onStop)
        window.orderFrontRegardless()
        hudWindow = window
    }

    /// Size of the live HUD panel.
    public static let hudSize = CGSize(width: 300, height: 74)

    /// Build the HUD's contents into `content`.
    ///
    /// Shared with the offscreen UI-snapshot renderer so a screenshot of "the recording HUD" is
    /// the real thing rather than a hand-maintained copy that can drift out of date.
    public func populateHUD(_ content: NSView, onStop: @escaping () -> Void) {

        // The HUD is a dark panel, so its controls must be drawn in dark mode; the default
        // (light) appearance renders the push button as dark text on a dark bezel, which is
        // what the first UI snapshot showed.
        content.appearance = NSAppearance(named: .darkAqua)

        let stop = NSButton(title: "Stop", target: stopProxy, action: #selector(HUDStopProxy.fire))
        stopProxy.handler = onStop
        stop.bezelStyle = .rounded
        stop.keyEquivalent = "\r"
        stop.contentTintColor = .white
        stop.frame = CGRect(x: 226, y: 32, width: 58, height: 28)
        content.addSubview(stop)

        let dot = NSView(frame: CGRect(x: 16, y: 42, width: 10, height: 10))
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 5
        content.addSubview(dot)

        let elapsed = NSTextField(labelWithString: "0.0 s")
        elapsed.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        elapsed.textColor = .white
        elapsed.frame = CGRect(x: 34, y: 46, width: 180, height: 20)
        content.addSubview(elapsed)
        elapsedLabel = elapsed

        let frames = NSTextField(labelWithString: "0 frames")
        frames.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        frames.textColor = NSColor.white.withAlphaComponent(0.7)
        frames.frame = CGRect(x: 34, y: 30, width: 180, height: 16)
        content.addSubview(frames)
        frameLabel = frames

        // How close the recording is to its own ceiling. Without it the limit arrives as a
        // surprise: the clip simply stops.
        let progress = NSProgressIndicator(frame: CGRect(x: 16, y: 22, width: 268, height: 4))
        progress.isIndeterminate = false
        progress.style = .bar
        progress.minValue = 0
        progress.maxValue = 1
        progress.doubleValue = 0
        content.addSubview(progress)
        progressBar = progress

        // The global Escape hot key is claimed for the whole recording; say so, because a
        // key that works everywhere is worthless if nobody knows it exists.
        let hint = NSTextField(labelWithString: "Esc cancels · Return stops")
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = NSColor.white.withAlphaComponent(0.6)
        hint.frame = CGRect(x: 16, y: 5, width: 268, height: 14)
        content.addSubview(hint)
        hintLabel = hint
    }

    public func update(progress: RecordingProgress, limits: RecordingLimits) {
        elapsedLabel?.stringValue = String(format: "%.1f s / %.0f s", progress.elapsed, limits.maxDuration)
        frameLabel?.stringValue = "\(progress.frameCount) frames · \(progress.retainedBytes / 1_048_576) MB"
        progressBar?.doubleValue = min(1, progress.elapsed / max(0.001, limits.maxDuration))
    }

    public func dismiss() {
        stopProxy.handler = nil
        for window in [hudWindow, borderWindow, countdownWindow].compactMap({ $0 }) {
            window.orderOut(nil)
            window.close()
        }
        hudWindow = nil
        borderWindow = nil
        countdownWindow = nil
        elapsedLabel = nil
        frameLabel = nil
        escapeNotice = nil
        hintLabel = nil
        progressBar = nil
        countdownHintLabel = nil
    }

    /// Replace the "Esc to cancel" affordance with an honest notice when the global Escape hot key
    /// could not be claimed (another application already owns it).
    public func showEscapeUnavailableNotice() {
        guard escapeNotice == nil else { return }
        // Replace the hint rather than adding a second line that contradicts it.
        hintLabel?.stringValue = "Esc unavailable — click Stop"
        hintLabel?.textColor = NSColor.systemYellow
        escapeNotice = hintLabel
    }

    // MARK: - Chrome

    private func showRegionOutline(_ region: CaptureRegion) {
        let frame = region.appKitGlobalRect.insetBy(dx: -2, dy: -2)
        let window = NSWindow(
            contentRect: frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) - 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.sharingType = .none

        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        view.layer?.borderColor = NSColor.systemRed.cgColor
        view.layer?.borderWidth = 2
        view.layer?.cornerRadius = 2
        window.contentView = view
        window.orderFrontRegardless()
        borderWindow = window
    }

    private func makeFloatingWindow(size: CGSize, centeredOn region: CaptureRegion) -> NSWindow {
        let rect = region.appKitGlobalRect
        let origin = CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)
        return makeFloatingWindow(size: size, origin: origin)
    }

    private func makeFloatingWindow(size: CGSize, belowTopOf region: CaptureRegion) -> NSWindow {
        let rect = region.appKitGlobalRect
        // Prefer just below the region; fall back to just above when the region touches the
        // bottom of its display.
        var origin = CGPoint(x: rect.midX - size.width / 2, y: rect.minY - size.height - 12)
        if origin.y < region.display.appKitBounds.minY + 8 {
            origin.y = rect.maxY + 12
        }
        origin.x = min(
            max(region.display.appKitBounds.minX + 8, origin.x),
            region.display.appKitBounds.maxX - size.width - 8
        )
        return makeFloatingWindow(size: size, origin: origin)
    }

    private func makeFloatingWindow(size: CGSize, origin: CGPoint) -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(origin: origin, size: size),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.sharingType = .none

        let content = NSView(frame: NSRect(origin: .zero, size: size))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.82).cgColor
        content.layer?.cornerRadius = 12
        window.contentView = content
        return window
    }
}

/// Watches for Esc while the countdown runs.
@MainActor
private final class CancelWatcher {
    private var monitor: Any?
    private(set) var wasCancelled = false

    init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.wasCancelled = true
                return nil
            }
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// `NSButton` needs an Objective-C target; this keeps the closure alive without leaking it.
/// Deliberately *not* a singleton — see `RecordingHUD.stopProxy`.
@MainActor
private final class HUDStopProxy: NSObject {
    var handler: (() -> Void)?

    @objc func fire() { handler?() }
}
