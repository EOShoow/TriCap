import Foundation

/// Legacy two-state capture vocabulary, kept for settings compatibility.
///
/// Blobs written before the three-flow picker stored `lastCaptureIntent: still|recording`, and a
/// downgraded build still reads it. ``CaptureFlow`` is the vocabulary everything else uses now;
/// this type survives only at the persistence boundary (decode migration and the mirror field).
public enum CaptureIntent: String, Codable, CaseIterable, Sendable {
    case still
    case recording
}

/// What one press of the capture hot key does, end to end.
///
/// The old model was two-dimensional: the picker chose still/recording, and a *setting*
/// (`stillCaptureAction`) decided what happened to a finished screenshot. That hid the most
/// common fork — "just give me the clipboard" versus "let me annotate" — behind a trip to
/// Settings. The flow collapses both into one value the picker cycles through with `R`.
public enum CaptureFlow: String, Codable, CaseIterable, Sendable {
    /// Screenshot → clipboard immediately, and a copy is saved to the output folder in the
    /// background. No window appears.
    case quickStill
    /// Screenshot → annotation editor; saving is an explicit step there.
    case editStill
    /// Record a clip → editor (trim, annotate, export).
    case recording

    /// The `R` key's cycle, in the order a user reaches for them: fast shot, careful shot, clip.
    public var next: CaptureFlow {
        switch self {
        case .quickStill: return .editStill
        case .editStill: return .recording
        case .recording: return .quickStill
        }
    }

    /// Shown in the picker's mode banner.
    public var displayName: String {
        switch self {
        case .quickStill: return "Quick screenshot"
        case .editStill: return "Screenshot and edit"
        case .recording: return "Record a clip"
        }
    }

    /// What a legacy settings blob meant. A recorded `still` intent needs `stillCaptureAction`
    /// to know *which* still flow it was, because that fork used to live in the setting.
    public init(legacyIntent: CaptureIntent, stillAction: StillCaptureAction) {
        switch legacyIntent {
        case .recording: self = .recording
        case .still: self = stillAction == .openEditor ? .editStill : .quickStill
        }
    }

    /// The two-state value a downgraded build should see for this flow.
    public var legacyIntent: CaptureIntent {
        self == .recording ? .recording : .still
    }
}

/// What the capture hot key opens.
///
/// The picker itself can always cycle flows mid-selection (`R`), so this only decides the
/// *starting* flow. `rememberLast` is the shipped default: a run of recordings should not demand
/// an extra keystroke per capture just because screenshots came first alphabetically.
public enum HotKeyLaunchMode: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Always open in a screenshot flow — the pre-existing behaviour. Which of the two still
    /// flows depends on `stillCaptureAction`, exactly as the old build's post-capture fork did.
    case alwaysStill
    /// Always open in recording mode.
    case alwaysRecording
    /// Open in whatever flow the last completed selection used.
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
            return "The shortcut always opens ready for a screenshot — quick or edit, following the Default screenshot flow setting. R cycles quick screenshot → screenshot and edit → recording."
        case .alwaysRecording:
            return "The shortcut always opens ready to record. R cycles quick screenshot → screenshot and edit → recording; S jumps straight to screenshot and edit."
        case .rememberLast:
            return "The shortcut opens in whichever flow you completed last — the banner at the top always shows which one. R cycles quick screenshot → screenshot and edit → recording."
        }
    }

    /// The flow the hot key should open with.
    ///
    /// Pure on purpose: the fixed modes ignore history entirely, so a stale or missing
    /// `lastUsed` can never leak into them. `stillAction` resolves ``alwaysStill`` to a concrete
    /// still flow, preserving what that setting always meant.
    public func effectiveFlow(lastUsed: CaptureFlow, stillAction: StillCaptureAction) -> CaptureFlow {
        switch self {
        case .alwaysStill: return CaptureFlow(legacyIntent: .still, stillAction: stillAction)
        case .alwaysRecording: return .recording
        case .rememberLast: return lastUsed
        }
    }
}
