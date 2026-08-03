import Foundation

/// One system-wide key shared by several features, where the most recent claimant wins.
///
/// Two things in TriCap want a bare Escape: cancelling a recording, and dismissing a pin. Carbon
/// refuses a duplicate registration (`eventHotKeyExistsErr`), so whichever claimed second would
/// silently get nothing — a pin left open would break recording cancellation, which is the more
/// important of the two.
///
/// This keeps a single underlying registration and a *stack* of handlers. The top of the stack
/// fires; popping reveals the one beneath. So: pin open → Escape closes the pin; start a recording
/// → Escape cancels the recording; recording ends → Escape closes the pin again. Each claimant
/// holds an opaque token and pops exactly its own entry, so releases arriving out of order cannot
/// leave the wrong handler on top.
@MainActor
public final class PriorityHotKeyClaim {

    /// Opaque handle identifying one claim.
    public struct Token: Hashable, Sendable {
        fileprivate let id: UInt64
    }

    private struct Entry {
        let token: Token
        let handler: () -> Void
    }

    private let claim: TransientHotKeyClaim
    private var stack: [Entry] = []
    private var nextID: UInt64 = 1

    public init(combo: HotKeyCombo, register: @escaping TransientHotKeyClaim.Register, unregister: @escaping TransientHotKeyClaim.Unregister) {
        self.claim = TransientHotKeyClaim(combo: combo, register: register, unregister: unregister)
    }

    public var depth: Int { stack.count }
    public var isClaimed: Bool { claim.isClaimed }
    public var registrationCount: Int { claim.registrationCount }
    public var releaseCount: Int { claim.releaseCount }

    /// Take the key. The previous claimant keeps its place underneath.
    ///
    /// - Returns: a token to pass to ``pop(_:)``, or `nil` if the very first registration failed —
    ///   in which case the caller must tell the user the key is unavailable rather than assume it
    ///   is wired up.
    public func push(_ handler: @escaping () -> Void) -> Token? {
        let token = Token(id: nextID)
        nextID += 1
        stack.append(Entry(token: token, handler: handler))

        // The underlying claim always fires the *current* top of the stack, so pushing after the
        // first time is a rebind rather than a fresh registration.
        let claimed = claim.claim { [weak self] in self?.fireTopmost() }
        guard claimed else {
            stack.removeAll { $0.token == token }
            return nil
        }
        return token
    }

    /// Give up one claim. Safe to call twice, and safe to call out of order.
    public func pop(_ token: Token?) {
        guard let token else { return }
        stack.removeAll { $0.token == token }
        if stack.isEmpty { claim.release() }
    }

    /// Drop every claim — used when the app is tearing down.
    public func reset() {
        stack.removeAll()
        claim.release()
    }

    /// Fire the key, as the window server would. Exposed for tests.
    public func simulateFire() {
        fireTopmost()
    }

    private func fireTopmost() {
        stack.last?.handler()
    }
}
