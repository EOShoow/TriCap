import Foundation

/// One system-wide key shared by several features, arbitrated by **declared priority**.
///
/// Two things in TriCap want a bare Escape: cancelling a recording, and dismissing a pin. Carbon
/// refuses a duplicate registration (`eventHotKeyExistsErr`), so whichever claimed second would
/// silently get nothing — a pin left open would break recording cancellation, which is the more
/// important of the two.
///
/// This keeps a single underlying registration and picks the handler by priority, **not by the
/// order the claims happen to arrive in**. An earlier design fired the most recent claimant, which
/// worked for "pin open, then record" and quietly failed for "recording running, then pin" — the
/// pin would take Escape and the recording could no longer be cancelled. Cancelling a recording is
/// the claim that must always win while it exists, and that cannot depend on call order.
///
/// Within one priority the most recent claimant wins, which is what makes several pins behave like
/// a stack. Each claimant holds an opaque token and releases exactly its own entry, so releases
/// arriving out of order cannot leave the wrong handler in charge.
@MainActor
public final class PriorityHotKeyClaim {

    /// Who wins when more than one claimant wants the key.
    ///
    /// Higher wins. The values are spaced so a level can be inserted between them later without
    /// renumbering.
    public struct Priority: RawRepresentable, Comparable, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        /// Dismissing a pinned image. Loses to a running recording.
        public static let pin = Priority(rawValue: 100)
        /// Cancelling a countdown or a recording. Always wins while it is held.
        public static let recording = Priority(rawValue: 1000)

        public static func < (lhs: Priority, rhs: Priority) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// Opaque handle identifying one claim.
    public struct Token: Hashable, Sendable {
        fileprivate let id: UInt64
    }

    private struct Entry {
        let token: Token
        let priority: Priority
        /// Tie-breaker within a priority: higher is more recent.
        let sequence: UInt64
        let handler: () -> Void
    }

    private let claim: TransientHotKeyClaim
    private var entries: [Entry] = []
    private var nextID: UInt64 = 1
    private var nextSequence: UInt64 = 1

    public init(combo: HotKeyCombo, register: @escaping TransientHotKeyClaim.Register, unregister: @escaping TransientHotKeyClaim.Unregister) {
        self.claim = TransientHotKeyClaim(combo: combo, register: register, unregister: unregister)
    }

    public var depth: Int { entries.count }
    public var isClaimed: Bool { claim.isClaimed }
    public var registrationCount: Int { claim.registrationCount }
    public var releaseCount: Int { claim.releaseCount }

    /// The priority that would currently receive the key, or `nil` if nobody holds it.
    public var activePriority: Priority? { active?.priority }

    /// Take the key at `priority`. Existing claimants keep their entries.
    ///
    /// Claiming at a *lower* priority than the current holder succeeds and returns a token — the
    /// claim is registered and will take effect as soon as the higher-priority holder releases —
    /// but it does not take the key now. That is deliberate: pinning an image while a recording is
    /// running must not disarm Escape-to-cancel, and the pin must still get Escape afterwards
    /// without having to re-claim.
    ///
    /// - Returns: a token to pass to ``pop(_:)``, or `nil` if the very first registration failed —
    ///   in which case the caller must tell the user the key is unavailable rather than assume it
    ///   is wired up.
    public func push(priority: Priority, _ handler: @escaping () -> Void) -> Token? {
        let token = Token(id: nextID)
        nextID += 1
        let sequence = nextSequence
        nextSequence += 1
        entries.append(Entry(token: token, priority: priority, sequence: sequence, handler: handler))

        // The underlying claim always dispatches through `fireActive`, so pushing after the first
        // time is a rebind rather than a fresh registration.
        let claimed = claim.claim { [weak self] in self?.fireActive() }
        guard claimed else {
            entries.removeAll { $0.token == token }
            return nil
        }
        return token
    }

    /// Give up one claim. Safe to call twice, and safe to call out of order.
    public func pop(_ token: Token?) {
        guard let token else { return }
        entries.removeAll { $0.token == token }
        if entries.isEmpty { claim.release() }
    }

    /// Drop every claim — used when the app is tearing down.
    public func reset() {
        entries.removeAll()
        claim.release()
    }

    /// Fire the key, as the window server would. Exposed for tests.
    public func simulateFire() {
        fireActive()
    }

    /// Highest priority wins; within a priority, the most recent claim wins.
    private var active: Entry? {
        entries.max { left, right in
            left.priority == right.priority
                ? left.sequence < right.sequence
                : left.priority < right.priority
        }
    }

    private func fireActive() {
        active?.handler()
    }
}
