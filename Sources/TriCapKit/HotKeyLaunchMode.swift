import Foundation

/// What kind of capture a session ended up being. `SelectionUI` has its own `CaptureMode` for the
/// picker; this is the settings-side vocabulary for remembering it, kept in TriCapKit so the
/// launch decision below stays pure and testable.
public enum CaptureIntent: String, Codable, CaseIterable, Sendable {
    case still
    case recording
}

/// What the capture hot key opens.
///
/// The picker itself can always switch modes mid-selection (`R`/`S`), so this only decides the
/// *starting* mode. `rememberLast` is the shipped default: a run of recordings should not demand
/// an extra keystroke per capture just because screenshots came first alphabetically.
public enum HotKeyLaunchMode: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Always open in screenshot mode — the pre-existing behaviour.
    case alwaysStill
    /// Always open in recording mode.
    case alwaysRecording
    /// Open in whatever mode the last completed selection used.
    case rememberLast

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .alwaysStill: return "Always screenshot"
        case .alwaysRecording: return "Always recording"
        case .rememberLast: return "Remember last used"
        }
    }

    public var summary: String {
        switch self {
        case .alwaysStill:
            return "The shortcut always opens ready to take a screenshot. Press R to switch to recording."
        case .alwaysRecording:
            return "The shortcut always opens ready to record. Press S to switch to a screenshot."
        case .rememberLast:
            return "The shortcut opens in whichever mode you completed last. The banner at the top always shows which one, and R / S switches instantly."
        }
    }

    /// The mode the hot key should open with.
    ///
    /// Pure on purpose: the fixed modes ignore history entirely, so a stale or missing
    /// `lastUsed` can never leak into them.
    public func effectiveIntent(lastUsed: CaptureIntent) -> CaptureIntent {
        switch self {
        case .alwaysStill: return .still
        case .alwaysRecording: return .recording
        case .rememberLast: return lastUsed
        }
    }
}
