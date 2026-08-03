import Foundation
import Testing
@testable import TriCapKit

/// Two features want a bare Escape — cancelling a recording and dismissing a pin — and Carbon
/// allows a combination to be registered once. These tests pin the arbitration rules that let both
/// have it without either silently losing the key.
@Suite("Shared Escape stack")
@MainActor
struct PriorityHotKeyClaimTests {

    typealias Priority = PriorityHotKeyClaim.Priority

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

    @Test("Recording outranks a pin when the pin claimed first")
    func recordingWinsWhenPinClaimedFirst() {
        let registrar = FakeRegistrar()
        let claim = makeClaim(registrar)

        var pinClosed = 0
        var recordingCancelled = 0

        _ = claim.push(priority: .pin) { pinClosed += 1 }
        registrar.fire()
        #expect(pinClosed == 1)

        _ = claim.push(priority: .recording) { recordingCancelled += 1 }
        registrar.fire()
        #expect(recordingCancelled == 1)
        #expect(pinClosed == 1, "the pin's handler must not also fire")
    }

    @Test("Recording outranks a pin created *during* the recording")
    func recordingWinsWhenPinClaimedSecond() {
        // The regression. With a last-push-wins stack this passed only in the other order: pinning
        // an image mid-recording quietly took Escape, and the recording could no longer be
        // cancelled from another app — the exact thing the global Escape exists for.
        let registrar = FakeRegistrar()
        let claim = makeClaim(registrar)

        var pinClosed = 0
        var recordingCancelled = 0

        _ = claim.push(priority: .recording) { recordingCancelled += 1 }
        _ = claim.push(priority: .pin) { pinClosed += 1 }

        registrar.fire()
        #expect(recordingCancelled == 1, "Escape must still cancel the recording")
        #expect(pinClosed == 0, "the pin must not have taken the key")
        #expect(claim.activePriority == .recording)
    }

    @Test("Priority decides, not call order", arguments: [true, false])
    func orderIndependence(recordingFirst: Bool) {
        let registrar = FakeRegistrar()
        let claim = makeClaim(registrar)

        var pin = 0
        var recording = 0
        if recordingFirst {
            _ = claim.push(priority: .recording) { recording += 1 }
            _ = claim.push(priority: .pin) { pin += 1 }
        } else {
            _ = claim.push(priority: .pin) { pin += 1 }
            _ = claim.push(priority: .recording) { recording += 1 }
        }

        registrar.fire()
        #expect(recording == 1)
        #expect(pin == 0)
    }

    @Test("A lower-priority claim still gets a token and takes over on release")
    func lowPriorityClaimIsQueuedNotDropped() {
        // Pinning during a recording must not fail — the pin just waits its turn, and must not
        // have to re-claim once the recording ends.
        let registrar = FakeRegistrar()
        let claim = makeClaim(registrar)

        var pin = 0
        let recordingToken = claim.push(priority: .recording) {}
        let pinToken = claim.push(priority: .pin) { pin += 1 }

        #expect(pinToken != nil, "the pin's claim is registered, just outranked")
        #expect(claim.depth == 2)

        claim.pop(recordingToken)
        registrar.fire()
        #expect(pin == 1, "the pin takes over without re-claiming")
        #expect(claim.activePriority == .pin)
        #expect(claim.isClaimed)
        #expect(registrar.releases == 0, "the key was never given back")
    }

    @Test("Within one priority the most recent claimant wins")
    func mostRecentWinsWithinAPriority() {
        // Several pins: Escape closes the newest, then the one behind it.
        let registrar = FakeRegistrar()
        let claim = makeClaim(registrar)

        var first = 0
        var second = 0
        _ = claim.push(priority: .pin) { first += 1 }
        let secondToken = claim.push(priority: .pin) { second += 1 }

        registrar.fire()
        #expect(second == 1)
        #expect(first == 0)

        claim.pop(secondToken)
        registrar.fire()
        #expect(first == 1)
    }

    @Test("Popping the top reveals the claimant underneath")
    func poppingRestoresPrevious() {
        // The scenario: a pin is open, the user starts a recording, Escape cancels the recording,
        // and afterwards Escape must go back to closing the pin.
        let registrar = FakeRegistrar()
        let claim = makeClaim(registrar)

        var pinClosed = 0
        _ = claim.push(priority: .pin) { pinClosed += 1 }
        let recordingToken = claim.push(priority: .recording) { }

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

        let a = claim.push(priority: .pin) {}
        let b = claim.push(priority: .recording) {}
        let c = claim.push(priority: .pin) {}
        #expect(registrar.registrations == 1)

        claim.pop(a)
        claim.pop(b)
        #expect(registrar.releases == 0, "someone still holds it")

        claim.pop(c)
        #expect(registrar.releases == 1)
        #expect(!claim.isClaimed)
    }

    @Test("Releases arriving out of order release the right entry")
    func outOfOrderRelease() {
        let registrar = FakeRegistrar()
        let claim = makeClaim(registrar)

        var pin = 0
        var recording = 0
        let pinToken = claim.push(priority: .pin) { pin += 1 }
        _ = claim.push(priority: .recording) { recording += 1 }

        // The pin goes away first — closed while a recording runs.
        claim.pop(pinToken)
        registrar.fire()

        #expect(recording == 1, "the recording still owns Escape")
        #expect(pin == 0)
        #expect(claim.depth == 1)
        #expect(claim.activePriority == .recording)
    }

    @Test("Releasing a lower-priority claim never disturbs the active one")
    func releasingAnInactiveClaimIsInvisible() {
        let registrar = FakeRegistrar()
        let claim = makeClaim(registrar)

        var recording = 0
        _ = claim.push(priority: .recording) { recording += 1 }
        let pinA = claim.push(priority: .pin) {}
        let pinB = claim.push(priority: .pin) {}

        claim.pop(pinA)
        claim.pop(pinB)
        claim.pop(pinA)   // idempotent

        registrar.fire()
        #expect(recording == 1)
        #expect(claim.depth == 1)
        #expect(registrar.releases == 0)
    }

    @Test("Popping the same token twice is harmless")
    func doublePopIsIdempotent() {
        let registrar = FakeRegistrar()
        let claim = makeClaim(registrar)

        let token = claim.push(priority: .pin) {}
        claim.pop(token)
        claim.pop(token)
        claim.pop(nil)

        #expect(registrar.releases == 1)
        #expect(claim.depth == 0)
        #expect(claim.activePriority == nil)
    }

    @Test("A refused first registration yields no token and leaves nothing to release")
    func refusedClaim() {
        let registrar = FakeRegistrar()
        registrar.shouldSucceed = false
        let claim = makeClaim(registrar)

        #expect(claim.push(priority: .recording) {} == nil)
        #expect(claim.depth == 0)
        #expect(!claim.isClaimed)

        claim.reset()
        #expect(registrar.releases == 0)
    }

    @Test("reset() drops everything, for app teardown")
    func resetClearsStack() {
        let registrar = FakeRegistrar()
        let claim = makeClaim(registrar)

        _ = claim.push(priority: .pin) {}
        _ = claim.push(priority: .recording) {}
        claim.reset()

        #expect(claim.depth == 0)
        #expect(!claim.isClaimed)
        #expect(registrar.releases == 1)
    }

    @Test("Firing with no claimants does nothing")
    func fireWithNoClaimants() {
        let registrar = FakeRegistrar()
        let claim = makeClaim(registrar)
        claim.simulateFire()   // must not trap
        #expect(claim.depth == 0)
        #expect(claim.activePriority == nil)
    }

    @Test("Recording outranks pinning as a plain value comparison")
    func priorityOrdering() {
        #expect(Priority.recording > Priority.pin)
    }
}
