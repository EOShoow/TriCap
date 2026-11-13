import AppKit
import CoreGraphics
import TriCapKit

/// Listens for Command-Command system-wide.
///
/// Carbon hot keys cannot bind a bare modifier, so this one gesture uses a listen-only event tap,
/// which needs macOS Input Monitoring. The tap never changes or blocks an event, and it only reads
/// *that* an ordinary key went down and which modifiers are held — never which key, never text.
/// Without the permission nothing is installed and nothing prompts; the menu command still works.
@MainActor
final class DoubleCommandMonitor {

    static let shared = DoubleCommandMonitor()

    /// Called on the main thread once per recognised gesture.
    var onTrigger: (() -> Void)?

    var isRunning: Bool { tap != nil }

    private var tap: CFMachPort?
    private var recognizer = DoubleCommandTap()

    // Device-dependent bits of `CGEventFlags` (NX_DEVICELCMDKEYMASK / NX_DEVICERCMDKEYMASK).
    private static let leftCommandBit: UInt64 = 0x08
    private static let rightCommandBit: UInt64 = 0x10
    private static let otherModifiers: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskSecondaryFn]

    private init() {}

    static var isAllowed: Bool { CGPreflightListenEventAccess() }

    /// Shows the system prompt the first time only; later calls return the stored answer.
    @discardableResult
    static func requestAccess() -> Bool { CGRequestListenEventAccess() }

    static func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
        NSWorkspace.shared.open(url)
    }

    /// Install the tap if Input Monitoring is allowed. Idempotent, and never prompts.
    @discardableResult
    func start() -> Bool {
        if tap != nil { return true }
        guard Self.isAllowed else { return false }

        let mask = (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
            | (CGEventMask(1) << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                if let refcon {
                    let monitor = Unmanaged<DoubleCommandMonitor>.fromOpaque(refcon).takeUnretainedValue()
                    // The run-loop source is on the main run loop, so this already is the main thread.
                    MainActor.assumeIsolated { monitor.handle(type, event) }
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            TriCapLog.app.error("Command-Command event tap could not be created")
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        TriCapLog.app.info("Command-Command listening")
        return true
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            recognizer = DoubleCommandTap()
        case .keyDown:
            recognizer.keyPressed()
        case .flagsChanged:
            let flags = event.flags
            let bothBits = Self.leftCommandBit | Self.rightCommandBit
            let fired = recognizer.modifiersChanged(
                command: flags.contains(.maskCommand),
                bothCommands: flags.rawValue & bothBits == bothBits,
                others: !flags.intersection(Self.otherModifiers).isEmpty,
                at: TimeInterval(event.timestamp) / 1_000_000_000
            )
            if fired { onTrigger?() }
        default:
            break
        }
    }
}
