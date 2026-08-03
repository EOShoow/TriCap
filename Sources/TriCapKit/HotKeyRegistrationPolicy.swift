import Foundation

/// What to do when the user picks a shortcut the system refuses to give us.
///
/// Registration can fail for a reason TriCap cannot control — another application already owns the
/// combination. The one outcome that must never happen is being left with *no* working shortcut,
/// which is what a naive "unregister the old one, register the new one" does when the second step
/// fails. This policy is a pure function so that behaviour is testable without Carbon.
public enum HotKeyRegistrationPolicy {

    public struct Result: Equatable, Sendable {
        /// The combination that is actually registered afterwards, or `nil` if none is.
        public let active: HotKeyCombo?
        /// `true` when `desired` failed and the previous combination was put back.
        public let rolledBack: Bool

        /// `true` only when neither the desired nor the previous combination could be claimed.
        public var lostShortcut: Bool { active == nil }

        public init(active: HotKeyCombo?, rolledBack: Bool) {
            self.active = active
            self.rolledBack = rolledBack
        }
    }

    /// Try `desired`; on failure fall back to `previous`.
    ///
    /// - Parameter register: performs the actual registration and reports success. It is called at
    ///   most twice, and never twice with the same combination.
    public static func apply(
        desired: HotKeyCombo,
        previous: HotKeyCombo?,
        register: (HotKeyCombo) -> Bool
    ) -> Result {
        if register(desired) {
            return Result(active: desired, rolledBack: false)
        }
        guard let previous, previous != desired else {
            return Result(active: nil, rolledBack: false)
        }
        if register(previous) {
            return Result(active: previous, rolledBack: true)
        }
        return Result(active: nil, rolledBack: false)
    }
}
