import TriCapKit

/// The one bare-Escape registration in the process.
///
/// Both recording cancellation and pin dismissal want Escape, and Carbon allows a combination to
/// be registered once. `PriorityHotKeyClaim` stacks their handlers so the most recent claimant
/// wins and popping reveals the previous one — a pin open during a recording therefore does not
/// break "Escape cancels the recording", and closing the recording restores "Escape closes the
/// pin".
@MainActor
enum SharedEscapeKey {
    static let claim = PriorityHotKeyClaim(
        combo: .bareEscape,
        register: { combo, action in
            GlobalHotKeyMonitor.shared.register(
                combo, in: .escapeDismiss, allowingNoModifiers: true, action: action
            )
        },
        unregister: { GlobalHotKeyMonitor.shared.unregister(.escapeDismiss) }
    )
}
