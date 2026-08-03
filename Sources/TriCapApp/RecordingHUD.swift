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
    /// The Stop button, so the self-test can hit-test it. Internal, not public.
    private(set) var stopButton: NSButton?
    private var frameLabel: NSTextField?
    private var borderWindow: NSWindow?
    private var escapeNotice: NSTextField?
    private var hintLabel: NSTextField?
    private var progressBar: NSProgressIndicator?
    private var countdownHintLabel: NSTextField?
    private var countdownLabel: NSTextField?

    /// One proxy per HUD instance. A shared singleton would let a second recording's HUD rebind
    /// the first one's Stop button.
    /// Internal rather than private so the self-test can assert the one-stop-per-click rule.
    let stopProxy = HUDStopProxy()

    public init() {}

    // MARK: - Countdown

    /// Show the pre-roll countdown panel. Cancellation is the caller's business — see
    /// `RecordingChromeController`, which owns the system-wide Escape claim.
    public func showCountdown(seconds: Int, over region: CaptureRegion) {
        dismissCountdown()

        let window = makeFloatingWindow(size: Self.countdownSize, centeredOn: region)
        guard let content = window.contentView else { return }
        populateCountdown(content, seconds: seconds)
        window.orderFrontRegardless()
        countdownWindow = window
    }

    public static let countdownSize = CGSize(width: 180, height: 176)

    /// Build the countdown panel's contents.
    ///
    /// Shared with the offscreen UI-snapshot renderer so the screenshot is the real panel.
    public func populateCountdown(_ content: NSView, seconds: Int) {
        content.appearance = NSAppearance(named: .darkAqua)

        let label = NSTextField(labelWithString: "\(seconds)")
        label.font = .systemFont(ofSize: 84, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.frame = CGRect(x: 0, y: 52, width: content.bounds.width, height: 100)
        content.addSubview(label)
        countdownLabel = label

        let caption = NSTextField(labelWithString: "Recording starts…")
        caption.font = .systemFont(ofSize: 12, weight: .medium)
        caption.textColor = NSColor.white.withAlphaComponent(0.85)
        caption.alignment = .center
        caption.frame = CGRect(x: 0, y: 32, width: content.bounds.width, height: 18)
        content.addSubview(caption)

        let cancelHint = NSTextField(labelWithString: "Esc to cancel")
        cancelHint.font = .systemFont(ofSize: 11)
        cancelHint.textColor = NSColor.white.withAlphaComponent(0.6)
        cancelHint.alignment = .center
        cancelHint.frame = CGRect(x: 0, y: 14, width: content.bounds.width, height: 16)
        content.addSubview(cancelHint)
        countdownHintLabel = cancelHint
    }

    /// Update the big number without rebuilding the panel.
    public func updateCountdown(remaining: Int) {
        countdownLabel?.stringValue = "\(remaining)"
    }

    /// Say that Escape could not be claimed, rather than promising a key that does nothing.
    public func showCountdownEscapeUnavailable() {
        countdownHintLabel?.stringValue = "Esc unavailable"
        countdownHintLabel?.textColor = NSColor.systemYellow
    }

    public func dismissCountdown() {
        countdownWindow?.orderOut(nil)
        countdownWindow?.close()
        countdownWindow = nil
        countdownLabel = nil
        countdownHintLabel = nil
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
        stopProxy.rearm()
        stopProxy.handler = onStop
        stopButton = stop
        stop.bezelStyle = .rounded
        // Deliberately no `keyEquivalent`. The HUD is a borderless, never-key floating panel, so a
        // key equivalent on it can never fire — advertising Return as a way to stop was a promise
        // the window could not keep. Escape works because it is a real system-wide hot key.
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
        let hint = NSTextField(labelWithString: "Esc cancels · Click Stop to finish")
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
        stopButton = nil
        frameLabel = nil
        escapeNotice = nil
        hintLabel = nil
        progressBar = nil
        countdownHintLabel = nil
        countdownLabel = nil
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
        let placement = HUDPlacement.placeCentred(
            size: size,
            over: region.appKitGlobalRect,
            in: Self.visibleFrame(for: region)
        )
        return makeFloatingWindow(size: size, origin: placement.frame.origin)
    }

    private func makeFloatingWindow(size: CGSize, belowTopOf region: CaptureRegion) -> NSWindow {
        let placement = HUDPlacement.place(
            size: size,
            over: region.appKitGlobalRect,
            in: Self.visibleFrame(for: region)
        )
        TriCapLog.app.debug(
            "HUD placed \(placement.strategy.rawValue, privacy: .public) at \(placement.frame.debugDescription, privacy: .public)"
        )
        return makeFloatingWindow(size: size, origin: placement.frame.origin)
    }

    /// The visible frame of the screen the region is actually on.
    ///
    /// Matched by `CGDirectDisplayID` rather than by taking `NSScreen.main`: a recording on a
    /// secondary display must not put its Stop button on the primary one. Falls back to whichever
    /// screen contains the region, then to main, so a display disconnected mid-capture still
    /// produces chrome somewhere reachable.
    static func visibleFrame(for region: CaptureRegion) -> CGRect {
        let wanted = region.display.displayID
        let matching = NSScreen.screens.first { screen in
            let number = screen.deviceDescription[.init("NSScreenNumber")] as? NSNumber
            return number?.uint32Value == wanted
        }
        let screen = matching
            ?? NSScreen.screens.first { $0.frame.intersects(region.appKitGlobalRect) }
            ?? NSScreen.main
        return screen?.visibleFrame ?? region.display.appKitBounds
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

/// `NSButton` needs an Objective-C target; this keeps the closure alive without leaking it.
/// Deliberately *not* a singleton — see `RecordingHUD.stopProxy`.
@MainActor
final class HUDStopProxy: NSObject {
    var handler: (() -> Void)?
    /// How many clicks were delivered, including the ones swallowed. Exposed for the self-test.
    private(set) var clickCount = 0
    private var hasFired = false

    /// Stopping is a one-way door. `RecordingSession` already latches its own stop, but the button
    /// stays clickable for the moment between the click and the HUD disappearing, and a
    /// double-click there should not queue a second stop for the *next* recording to inherit.
    @objc func fire() {
        clickCount += 1
        guard !hasFired else { return }
        hasFired = true
        handler?()
    }

    /// Reset for a new recording. The proxy is per-`RecordingHUD`, but a HUD outlives one clip.
    func rearm() {
        hasFired = false
        clickCount = 0
    }
}
