import AppKit
import Carbon.HIToolbox
import TriCapKit

/// System-wide hot key registration.
///
/// `RegisterEventHotKey` is used rather than an `NSEvent` global monitor because a global monitor
/// requires Accessibility permission — a second, scarier TCC prompt on top of Screen Recording —
/// and cannot stop the key from reaching the focused app. Carbon's hot-key API is still the only
/// public way to claim a key combination system-wide without that permission.
@MainActor
public final class GlobalHotKeyMonitor {

    public static let shared = GlobalHotKeyMonitor()

    /// Four-character signature identifying TriCap's hot keys ('TRCP').
    private static let signature: OSType = 0x5452_4350
    private static let hotKeyID: UInt32 = 1

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var action: (() -> Void)?

    public private(set) var registeredCombo: HotKeyCombo?

    private init() {}

    /// Register (or re-register) the hot key.
    ///
    /// - Returns: `true` on success. `false` means another application already owns the
    ///   combination; the caller surfaces that so the user can pick a different one instead of
    ///   silently getting a dead shortcut.
    @discardableResult
    public func register(_ combo: HotKeyCombo, action: @escaping () -> Void) -> Bool {
        unregister()
        guard combo.isValid else {
            TriCapLog.app.error("refusing to register a hot key with no modifiers")
            return false
        }

        self.action = action
        installEventHandlerIfNeeded()

        var reference: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: Self.hotKeyID)
        let status = RegisterEventHotKey(
            combo.keyCode,
            combo.carbonModifiers,
            id,
            GetEventDispatcherTarget(),
            0,
            &reference
        )

        guard status == noErr, let reference else {
            TriCapLog.app.error("RegisterEventHotKey failed with status \(status, privacy: .public)")
            self.action = nil
            return false
        }

        hotKeyRef = reference
        registeredCombo = combo
        TriCapLog.app.info("registered hot key \(combo.displayString, privacy: .public)")
        return true
    }

    public func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        registeredCombo = nil
        action = nil
    }

    fileprivate func fire() {
        action?()
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), hotKeyCarbonHandler, 1, &spec, nil, &eventHandler)
    }
}

/// Carbon calls this on the main thread; it just forwards to the monitor.
private let hotKeyCarbonHandler: EventHandlerUPP = { _, event, _ in
    var id = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &id
    )
    guard status == noErr else { return status }

    MainActor.assumeIsolated {
        GlobalHotKeyMonitor.shared.fire()
    }
    return noErr
}

extension HotKeyCombo {
    /// Build a combo from a captured `NSEvent`, or `nil` if it has no usable modifier.
    public static func from(event: NSEvent) -> HotKeyCombo? {
        var carbon: UInt32 = 0
        let flags = event.modifierFlags
        if flags.contains(.command) { carbon |= CarbonModifier.command.rawValue }
        if flags.contains(.shift) { carbon |= CarbonModifier.shift.rawValue }
        if flags.contains(.option) { carbon |= CarbonModifier.option.rawValue }
        if flags.contains(.control) { carbon |= CarbonModifier.control.rawValue }

        let combo = HotKeyCombo(keyCode: UInt32(event.keyCode), carbonModifiers: carbon)
        return combo.isValid ? combo : nil
    }
}
