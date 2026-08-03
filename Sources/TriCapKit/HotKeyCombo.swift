import Foundation

/// A global hot key expressed the way Carbon's `RegisterEventHotKey` wants it.
///
/// Carbon modifier masks are used rather than `NSEvent.ModifierFlags` because the
/// registration API is the Carbon one (`RegisterEventHotKey` remains the only public,
/// non-accessibility-permission way to grab a system-wide key on macOS).
public struct HotKeyCombo: Codable, Equatable, Hashable, Sendable {
    /// Virtual key code (`kVK_*`), e.g. 23 for the top-row `5`.
    public var keyCode: UInt32
    /// Carbon modifier mask: `cmdKey` 256, `shiftKey` 512, `optionKey` 2048, `controlKey` 4096.
    public var carbonModifiers: UInt32

    public init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    public enum CarbonModifier: UInt32, Sendable, CaseIterable {
        case command = 256
        case shift = 512
        case option = 2048
        case control = 4096
    }

    public func contains(_ modifier: CarbonModifier) -> Bool {
        carbonModifiers & modifier.rawValue != 0
    }

    /// `true` when at least one of ⌘ ⌥ ⌃ ⇧ is held.
    public var hasModifier: Bool {
        carbonModifiers & (CarbonModifier.command.rawValue
            | CarbonModifier.shift.rawValue
            | CarbonModifier.option.rawValue
            | CarbonModifier.control.rawValue) != 0
    }

    /// Keys that may be claimed system-wide *without* a modifier.
    ///
    /// Strictly the function row. A modifier-less hot key is swallowed everywhere, so binding a
    /// letter or a digit would make that character untypeable in every application — which is why
    /// this is an allow-list of specific key codes rather than a "no modifier needed" flag.
    /// Escape is deliberately absent: it is claimed only transiently, during a recording, through
    /// `TransientHotKeyClaim`, never as a persistent shortcut.
    public static let bareKeyAllowList: Set<UInt32> = [
        122, 120, 99, 118,        // F1 F2 F3 F4
        96, 97, 98, 100,          // F5 F6 F7 F8
        101, 109, 103, 111,       // F9 F10 F11 F12
        105, 107, 113, 106,       // F13 F14 F15 F16
        64, 79, 80, 90,           // F17 F18 F19 F20
    ]

    /// Whether this key code may stand alone as a shortcut.
    public var isAllowedAsBareKey: Bool {
        Self.bareKeyAllowList.contains(keyCode)
    }

    /// Whether the user may bind this combination as a persistent shortcut.
    public var isValid: Bool {
        hasModifier || isAllowedAsBareKey
    }

    /// `⌥⇧5` — order matches the macOS menu convention (⌃⌥⇧⌘).
    public var displayString: String {
        var s = ""
        if contains(.control) { s += "⌃" }
        if contains(.option) { s += "⌥" }
        if contains(.shift) { s += "⇧" }
        if contains(.command) { s += "⌘" }
        s += Self.keyName(for: keyCode)
        return s
    }

    /// A bare Escape, used only as the transient recording-cancel key.
    ///
    /// ``isValid`` is deliberately `false` for this combination — Escape is not on
    /// ``bareKeyAllowList``, so it can never be selected as a persistent shortcut. Claiming it
    /// requires an explicit opt-in, and it is held only for the length of one
    /// countdown-plus-recording. See `TransientHotKeyClaim`.
    public static let bareEscape = HotKeyCombo(keyCode: 53, carbonModifiers: 0)

    /// TriCap's default *capture* shortcut: Option+Shift+5, chosen to sit next to the system
    /// ⇧⌘5 without colliding.
    public static let `default` = HotKeyCombo(
        keyCode: 23,  // kVK_ANSI_5
        carbonModifiers: CarbonModifier.option.rawValue | CarbonModifier.shift.rawValue
    )

    /// TriCap's default *pin* shortcut: a bare F3.
    ///
    /// F3 is Mission Control's factory binding on Apple keyboards. macOS resolves that in the
    /// user's favour — whoever registered first keeps it — so TriCap detects a failed registration
    /// and says so rather than quietly moving to another key. See `HotKeyRegistrationPolicy`.
    public static let defaultPin = HotKeyCombo(keyCode: 99, carbonModifiers: 0)  // kVK_F3

    /// Virtual-key → label for an ANSI layout.
    ///
    /// Deliberately a fixed table rather than a `UCKeyTranslate` round trip: the label is
    /// cosmetic, and a static map cannot fail, cannot block on the input-source server, and
    /// stays identical between the settings sheet and the menu-bar item.
    public static func keyName(for keyCode: UInt32) -> String {
        if let named = namedKeys[keyCode] { return named }
        return "Key \(keyCode)"
    }

    private static let namedKeys: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
        24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
        30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
        36: "↩", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\",
        43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 48: "⇥", 49: "Space",
        50: "`", 51: "⌫", 53: "⎋",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9",
        103: "F11", 109: "F10", 111: "F12",
        118: "F4", 120: "F2", 122: "F1",
        105: "F13", 107: "F14", 113: "F15", 106: "F16",
        64: "F17", 79: "F18", 80: "F19", 90: "F20",
        123: "←", 124: "→", 125: "↓", 126: "↑",
    ]
}
