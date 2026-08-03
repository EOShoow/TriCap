import Foundation
import Testing
@testable import TriCapKit

/// Two features want a bare Escape — cancelling a recording and dismissing a pin — and Carbon
/// allows a combination to be registered once. These tests pin the stacking rules that let both
/// have it without either silently losing the key.
@Suite("Shared Escape stack")
@MainActor
struct PriorityHotKeyClaimTests {

    @MainActor
    final class FakeRegistrar {
        private(set) var registrations = 0
        private(set) var releases = 0
        var shouldSucceed = true
        private var action: (() -> Void)?

        func register(_ combo: HotKeyCombo, action: @escaping () -> Void) -> Bool {
            guard shouldSucceed else { return false }
            registrations += 1
            self.action = action
            return true
        }

        func unregister() {
            releases += 1
            action = nil
        }

        func fire() { action?() }
    }

    private func makeClaim(_ registrar: FakeRegistrar) -> PriorityHotKeyClaim {
        PriorityHotKeyClaim(
            combo: .bareEscape,
            register: { registrar.register($0, action: $1) },
            unregister: { registrar.unregister() }
        )
    }

    @Test("The most recent claimant receives the key")
    func topmostWins() {
        let registrar = FakeRegistrar()
        let claim = makeClaim(registrar)

        var pinClosed = 0
        var recordingCancelled = 0

        _ = claim.push { pinClosed += 1 }
        registrar.fire()
        #expect(pinClosed == 1)

        _ = claim.push { recordingCancelled += 1 }
        registrar.fire()
        #expect(recordingCancelled == 1)
        #expect(pinClosed == 1, "the pin's handler must not also fire")
    }

    @Test("Popping the top reveals the claimant underneath")
    func poppingRestoresPrevious() {
        // The scenario: a pin is open, the user starts a recording, Escape cancels the recording,
        // and afterwards Escape must go back to closing the pin.
        let registrar = FakeRegistrar()
        let claim = makeClaim(registrar)

        var pinClosed = 0
        _ = claim.push { pinClosed += 1 }
        let recordingToken = claim.push { }

        claim.pop(recordingToken)
        registrar.fire()
        #expect(pinClosed == 1)
        #expect(claim.isClaimed, "the pin still wants Escape")
        #expect(registrar.releases == 0, "the key was never given back")
    }

    @Test("The key is registered once and released once across a whole stack")
    func singleRegistration() {
        let registrar = FakeRegistrar()
        let claim = makeClaim(registrar)

        let a = claim.push {}
        let b = claim.push {}
        let c = claim.push {}
        #expect(registrar.registrations == 1)

        claim.pop(a)
        claim.pop(b)
        #expect(registrar.releases == 0, "someone still holds it")

        claim.pop(c)
        #expect(registrar.releases == 1)
        #expect(!claim.isClaimed)
    }

    @Test("Releases arriving out of order pop the right entry")
    func outOfOrderRelease() {
        let registrar = FakeRegistrar()
        let claim = makeClaim(registrar)

        var bottom = 0
        var top = 0
        let bottomToken = claim.push { bottom += 1 }
        _ = claim.push { top += 1 }

        // The *bottom* claimant goes away first — a pin closed while a recording runs.
        claim.pop(bottomToken)
        registrar.fire()

        #expect(top == 1, "the recording still owns Escape")
        #expect(bottom == 0)
        #expect(claim.depth == 1)
    }

    @Test("Popping the same token twice is harmless")
    func doublePopIsIdempotent() {
        let registrar = FakeRegistrar()
        let claim = makeClaim(registrar)

        let token = claim.push {}
        claim.pop(token)
        claim.pop(token)
        claim.pop(nil)

        #expect(registrar.releases == 1)
        #expect(claim.depth == 0)
    }

    @Test("A refused first registration yields no token and leaves nothing to release")
    func refusedClaim() {
        let registrar = FakeRegistrar()
        registrar.shouldSucceed = false
        let claim = makeClaim(registrar)

        #expect(claim.push {} == nil)
        #expect(claim.depth == 0)
        #expect(!claim.isClaimed)

        claim.reset()
        #expect(registrar.releases == 0)
    }

    @Test("reset() drops everything, for app teardown")
    func resetClearsStack() {
        let registrar = FakeRegistrar()
        let claim = makeClaim(registrar)

        _ = claim.push {}
        _ = claim.push {}
        claim.reset()

        #expect(claim.depth == 0)
        #expect(!claim.isClaimed)
        #expect(registrar.releases == 1)
    }

    @Test("Firing an empty stack does nothing")
    func fireWithNoClaimants() {
        let registrar = FakeRegistrar()
        let claim = makeClaim(registrar)
        claim.simulateFire()   // must not trap
        #expect(claim.depth == 0)
    }
}
