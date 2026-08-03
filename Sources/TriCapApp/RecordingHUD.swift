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

    public init() {}

    // MARK: - Countdown

    /// Count `seconds` down over the selection. Returns `false` if the user pressed Esc.
    public func runCountdown(seconds: Int, over region: CaptureRegion) async -> Bool {
        guard seconds > 0 else { return true }

        let window = makeFloatingWindow(size: CGSize(width: 160, height: 160), centeredOn: region)
        let label = NSTextField(labelWithString: "\(seconds)")
        label.font = .systemFont(ofSize: 84, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.frame = CGRect(x: 0, y: 30, width: 160, height: 100)
        window.contentView?.addSubview(label)
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

        let window = makeFloatingWindow(size: CGSize(width: 268, height: 56), belowTopOf: region)
        guard let content = window.contentView else { return }

        let stop = NSButton(title: "Stop", target: StopProxy.shared, action: #selector(StopProxy.fire))
        StopProxy.shared.handler = onStop
        stop.bezelStyle = .rounded
        stop.keyEquivalent = "\r"
        stop.frame = CGRect(x: 196, y: 14, width: 58, height: 28)
        content.addSubview(stop)

        let dot = NSView(frame: CGRect(x: 16, y: 24, width: 10, height: 10))
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 5
        content.addSubview(dot)

        let elapsed = NSTextField(labelWithString: "0.0 s")
        elapsed.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        elapsed.textColor = .white
        elapsed.frame = CGRect(x: 34, y: 28, width: 150, height: 20)
        content.addSubview(elapsed)
        elapsedLabel = elapsed

        let frames = NSTextField(labelWithString: "0 frames")
        frames.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        frames.textColor = NSColor.white.withAlphaComponent(0.7)
        frames.frame = CGRect(x: 34, y: 10, width: 150, height: 16)
        content.addSubview(frames)
        frameLabel = frames

        window.orderFrontRegardless()
        hudWindow = window
    }

    public func update(progress: RecordingProgress, limits: RecordingLimits) {
        elapsedLabel?.stringValue = String(format: "%.1f s / %.0f s", progress.elapsed, limits.maxDuration)
        frameLabel?.stringValue = "\(progress.frameCount) frames · \(progress.retainedBytes / 1_048_576) MB"
    }

    public func dismiss() {
        StopProxy.shared.handler = nil
        for window in [hudWindow, borderWindow, countdownWindow].compactMap({ $0 }) {
            window.orderOut(nil)
            window.close()
        }
        hudWindow = nil
        borderWindow = nil
        countdownWindow = nil
        elapsedLabel = nil
        frameLabel = nil
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
@MainActor
private final class StopProxy: NSObject {
    static let shared = StopProxy()
    var handler: (() -> Void)?

    @objc func fire() { handler?() }
}
