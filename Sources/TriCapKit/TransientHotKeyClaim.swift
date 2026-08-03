import Foundation

/// A system-wide key claimed for the length of one operation and released afterwards.
///
/// TriCap claims a bare Escape while a recording is being set up and while it runs, so the user
/// can abandon it without first bringing TriCap to the front. That claim spans two phases — the
/// countdown and the recording itself — which are driven by different objects, so the rules that
/// matter are:
///
/// - **register once, not once per phase**, or the second phase's registration fails against the
///   first (Carbon returns `eventHotKeyExistsErr` for a duplicate combination);
/// - **rebind the action without re-registering**, so handing the key from the countdown to the
///   recording cannot drop a keypress in between;
/// - **release exactly once, on every exit path**, or Escape stays swallowed system-wide after
///   TriCap is finished with it.
///
/// The registrar is injected so those rules are testable without touching the real Carbon API.
@MainActor
public final class TransientHotKeyClaim {

    /// Performs the real registration. Returns `false` when the combination is unavailable.
    public typealias Register = (HotKeyCombo, @escaping () -> Void) -> Bool
    public typealias Unregister = () -> Void

    public let combo: HotKeyCombo

    private let register: Register
    private let unregister: Unregister
    private var handler: (() -> Void)?

    public private(set) var isClaimed = false
    /// How many times the underlying registration was actually performed.
    public private(set) var registrationCount = 0
    /// How many times the underlying registration was actually released.
    public private(set) var releaseCount = 0

    public init(combo: HotKeyCombo, register: @escaping Register, unregister: @escaping Unregister) {
        self.combo = combo
        self.register = register
        self.unregister = unregister
    }

    /// Claim the key, or rebind it if it is already claimed.
    ///
    /// - Returns: `false` only when a first registration fails. A rebind always succeeds.
    @discardableResult
    public func claim(onFire: @escaping () -> Void) -> Bool {
        handler = onFire
        guard !isClaimed else { return true }

        // The registered closure indirects through `handler`, so a later `claim` swaps the action
        // without giving the key up and taking it again.
        let succeeded = register(combo) { [weak self] in self?.handler?() }
        if succeeded {
            isClaimed = true
            registrationCount += 1
        } else {
            handler = nil
        }
        return succeeded
    }

    /// Release the key. Safe to call on every exit path, and safe to call twice.
    public func release() {
        handler = nil
        guard isClaimed else { return }
        isClaimed = false
        releaseCount += 1
        unregister()
    }

    /// Fire the current action, as the real hot key would. Used by tests.
    public func simulateFire() {
        handler?()
    }
}
