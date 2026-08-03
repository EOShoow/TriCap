import Foundation
import Testing
@testable import TriCapKit

/// The system-wide Escape is claimed across two phases — the countdown and the recording — driven
/// by different objects. These tests pin the rules that make that safe, without touching Carbon.
@Suite("Transient hot key claim")
@MainActor
struct TransientHotKeyClaimTests {

    /// Records what the registrar was asked to do, and can refuse.
    @MainActor
    final class FakeRegistrar {
        private(set) var registrations: [HotKeyCombo] = []
        private(set) var releases = 0
        var shouldSucceed = true
        /// The action the "system" would invoke.
        private(set) var installedAction: (() -> Void)?

        func register(_ combo: HotKeyCombo, action: @escaping () -> Void) -> Bool {
            guard shouldSucceed else { return false }
            registrations.append(combo)
            installedAction = action
            return true
        }

        func unregister() {
            releases += 1
            installedAction = nil
        }

        /// Fire the key as the window server would.
        func fire() { installedAction?() }
    }

    private func makeClaim(_ registrar: FakeRegistrar) -> TransientHotKeyClaim {
        TransientHotKeyClaim(
            combo: .bareEscape,
            register: { registrar.register($0, action: $1) },
            unregister: { registrar.unregister() }
        )
    }

    @Test("A first claim registers the key")
    func firstClaimRegisters() {
        let registrar = FakeRegistrar()
        let claim = makeClaim(registrar)

        #expect(claim.claim {})
        #expect(claim.isClaimed)
        #expect(registrar.registrations == [.bareEscape])
        #expect(claim.registrationCount == 1)
    }

    @Test("Handing the key from the countdown to the recording rebinds without re-registering")
    func rebindDoesNotReRegister() {
        // The regression this guards: registering the same combination twice fails with Carbon's
        // `eventHotKeyExistsErr`, so a recording phase that re-registered would silently lose the
        // key it thought it had claimed.
        let registrar = FakeRegistrar()
        let claim = makeClaim(registrar)

        var countdownCancels = 0
        var recordingCancels = 0

        claim.claim { countdownCancels += 1 }
        registrar.fire()
        #expect(countdownCancels == 1)

        claim.claim { recordingCancels += 1 }   // hand-off
        #expect(claim.registrationCount == 1, "the key must not be surrendered and re-taken")
        #expect(registrar.releases == 0)

        registrar.fire()
        #expect(recordingCancels == 1)
        #expect(countdownCancels == 1, "the old action must not fire after the rebind")
    }

    @Test("Release gives the key back exactly once, however many times it is called")
    func releaseIsIdempotent() {
        let registrar = FakeRegistrar()
        let claim = makeClaim(registrar)

        claim.claim {}
        claim.release()
        claim.release()
        claim.release()

        #expect(!claim.isClaimed)
        #expect(registrar.releases == 1)
        #expect(claim.releaseCount == 1)
    }

    @Test("Releasing a key that was never claimed does nothing")
    func releaseWithoutClaim() {
        let registrar = FakeRegistrar()
        let claim = makeClaim(registrar)

        claim.release()
        #expect(registrar.releases == 0)
        #expect(!claim.isClaimed)
    }

    @Test("After release the action can no longer fire")
    func releasedKeyIsInert() {
        let registrar = FakeRegistrar()
        let claim = makeClaim(registrar)

        var cancels = 0
        claim.claim { cancels += 1 }
        claim.release()
        claim.simulateFire()

        #expect(cancels == 0, "a released claim must not keep cancelling recordings")
    }

    @Test("The next recording can claim the key again")
    func reclaimAfterRelease() {
        let registrar = FakeRegistrar()
        let claim = makeClaim(registrar)

        claim.claim {}
        claim.release()
        #expect(claim.claim {})

        #expect(claim.isClaimed)
        #expect(claim.registrationCount == 2)
        #expect(registrar.releases == 1)
    }

    @Test("A refused claim leaves nothing behind to release")
    func refusedClaimIsClean() {
        // Another app already owns a bare Escape. The caller shows "Esc unavailable" and carries
        // on; nothing must be released later that was never taken.
        let registrar = FakeRegistrar()
        registrar.shouldSucceed = false
        let claim = makeClaim(registrar)

        #expect(!claim.claim {})
        #expect(!claim.isClaimed)
        #expect(claim.registrationCount == 0)

        claim.release()
        #expect(registrar.releases == 0)
    }

    @Test("A refused claim never fires a stale action")
    func refusedClaimDoesNotFire() {
        let registrar = FakeRegistrar()
        registrar.shouldSucceed = false
        let claim = makeClaim(registrar)

        var cancels = 0
        _ = claim.claim { cancels += 1 }
        claim.simulateFire()
        #expect(cancels == 0)
    }

    @Test("Leaning on Escape cancels once, because the action only sets a flag")
    func repeatedFiresAreIdempotentForTheCaller() {
        // The controller's handler sets `countdownCancelled = true`; firing it repeatedly is the
        // same as firing it once. This models that contract.
        let registrar = FakeRegistrar()
        let claim = makeClaim(registrar)

        var cancelled = false
        var observedTransitions = 0
        claim.claim {
            if !cancelled { observedTransitions += 1 }
            cancelled = true
        }

        registrar.fire()
        registrar.fire()
        registrar.fire()

        #expect(cancelled)
        #expect(observedTransitions == 1)
    }

    @Test("A full countdown-then-recording cycle registers once and releases once")
    func fullCycleBalances() {
        let registrar = FakeRegistrar()
        let claim = makeClaim(registrar)

        claim.claim {}          // countdown starts
        claim.claim {}          // countdown completes, recording takes over
        claim.release()         // recording ends (or was cancelled, or failed to start)

        #expect(claim.registrationCount == 1)
        #expect(claim.releaseCount == 1)
        #expect(!claim.isClaimed)
    }
}
