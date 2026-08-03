import AppKit
import Carbon.HIToolbox
import TriCapKit

/// System-wide hot key registration.
///
/// `RegisterEventHotKey` is used rather than an `NSEvent` global monitor because a global monitor
/// requires Accessibility permission — a second, scarier TCC prompt on top of Screen Recording —
/// and cannot stop the key from reaching the focused app. Carbon's hot-key API is still the only
/// public way to claim a key combination system-wide without that permission.
///
/// The monitor holds several independent *slots* so the transient recording-cancel key can be
/// claimed and released without disturbing the user's configured capture shortcut.
@MainActor
public final class GlobalHotKeyMonitor {

    public static let shared = GlobalHotKeyMonitor()

    /// Independent registrations. The raw value is the Carbon hot-key id, so the C callback can
    /// route an event back to the right action.
    public enum Slot: UInt32, CaseIterable, Sendable {
        /// The user's configurable capture shortcut. Always registered while TriCap runs.
        case primaryCapture = 1
        /// A bare Escape, claimed *only* for the duration of a recording.
        case recordingCancel = 2
    }

    /// Four-character signature identifying TriCap's hot keys ('TRCP').
    private static let signature: OSType = 0x5452_4350

    private struct Registration {
        let ref: EventHotKeyRef
        let combo: HotKeyCombo
        let action: () -> Void
    }

    private var registrations: [UInt32: Registration] = [:]
    private var eventHandler: EventHandlerRef?

    private init() {}

    /// The combination currently claimed in `slot`, if any.
    public func combo(in slot: Slot) -> HotKeyCombo? {
        registrations[slot.rawValue]?.combo
    }

    public func isRegistered(_ slot: Slot) -> Bool {
        registrations[slot.rawValue] != nil
    }

    /// Backwards-compatible accessor for the primary capture shortcut.
    public var registeredCombo: HotKeyCombo? { combo(in: .primaryCapture) }

    /// Register (or re-register) `combo` in `slot`.
    ///
    /// - Parameter allowingNoModifiers: normally a modifier-less shortcut is refused, because it
    ///   would swallow ordinary typing system-wide. The recording-cancel slot deliberately opts in:
    ///   a bare Escape is exactly what the user expects to abort a recording, and it is claimed for
    ///   at most the length of one recording.
    /// - Returns: `false` when the combination is unavailable (another application owns it) or
    ///   invalid. The previous registration in that slot is *not* restored here — see
    ///   ``HotKeyRegistrationPolicy`` for the roll-back the app applies.
    @discardableResult
    public func register(
        _ combo: HotKeyCombo,
        in slot: Slot,
        allowingNoModifiers: Bool = false,
        action: @escaping () -> Void
    ) -> Bool {
        unregister(slot)

        guard combo.isValid || allowingNoModifiers else {
            TriCapLog.app.error("refusing to register a hot key with no modifiers in slot \(slot.rawValue, privacy: .public)")
            return false
        }

        installEventHandlerIfNeeded()

        var reference: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: slot.rawValue)
        let status = RegisterEventHotKey(
            combo.keyCode,
            combo.carbonModifiers,
            id,
            GetEventDispatcherTarget(),
            0,
            &reference
        )

        guard status == noErr, let reference else {
            // -9878 is `eventHotKeyExistsErr`: some other process already owns the combination.
            TriCapLog.app.error(
                "RegisterEventHotKey(\(combo.displayString, privacy: .public)) failed with status \(status, privacy: .public)"
            )
            return false
        }

        registrations[slot.rawValue] = Registration(ref: reference, combo: combo, action: action)
        TriCapLog.app.info(
            "registered hot key \(combo.displayString, privacy: .public) in slot \(slot.rawValue, privacy: .public)"
        )
        return true
    }

    public func unregister(_ slot: Slot) {
        guard let existing = registrations.removeValue(forKey: slot.rawValue) else { return }
        UnregisterEventHotKey(existing.ref)
        TriCapLog.app.info(
            "released hot key \(existing.combo.displayString, privacy: .public) from slot \(slot.rawValue, privacy: .public)"
        )
    }

    public func unregisterAll() {
        for slot in Slot.allCases { unregister(slot) }
    }

    fileprivate func fire(id: UInt32) {
        registrations[id]?.action()
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), hotKeyCarbonHandler, 1, &spec, nil, &eventHandler)
    }
}

/// Carbon calls this on the main thread; it just routes to the matching slot.
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
        GlobalHotKeyMonitor.shared.fire(id: id.id)
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
