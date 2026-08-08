import Foundation
import Testing
@testable import CaptureCore

/// The quick screenshot's background save must live *outside* the capture session.
///
/// The review finding these tests pin: `copyAndSaveStill` used to `await` the disk write inside
/// the capture pipeline, so the `CaptureSessionGate` stayed occupied for the whole save — a
/// second hot-key press during the save was silently refused, and the clipboard toast waited
/// for the disk. The tests drive the *real* gate through the exact sequence `AppDelegate` now
/// runs (claim → capture → schedule save → end), with the save deliberately blocked, and prove
/// the session is over while the save is still running.
@MainActor
@Suite("Quick-save orchestration")
struct QuickSaveOrchestrationTests {

    @Test("The gate frees and the next capture is accepted while the save is still running")
    func gateFreesBeforeSaveCompletes() async {
        let gate = CaptureSessionGate()
        let queue = BackgroundSaveQueue()
        let blocker = DispatchSemaphore(value: 0)
        let (deliveries, continuation) = AsyncStream.makeStream(of: Int.self)

        // First capture: hot key → gate → still capture → clipboard served.
        #expect(gate.tryBegin())
        gate.transition(to: .capturingStill)

        // AppDelegate's order after the clipboard write: schedule the save (not awaited), then
        // the capture Task's defer releases the gate.
        queue.submit(
            work: { blocker.wait(); return 7 },
            deliver: { continuation.yield($0); continuation.finish() }
        )
        gate.end()

        // THE regression: the save is provably still running (blocked), yet the next hot-key
        // press must be accepted rather than silently refused.
        #expect(queue.inFlightCount == 1, "the save has not finished")
        #expect(gate.tryBegin(), "the next capture must start while the save is still writing")
        #expect(gate.refusedEntries == 0, "no hot-key press may be silently swallowed")
        gate.end()

        // Only now let the save finish, and confirm its outcome still arrives.
        blocker.signal()
        var received: Int?
        for await value in deliveries { received = value }
        #expect(received == 7, "the deferred save outcome is delivered after the session ended")
        #expect(queue.inFlightCount == 0)
    }

    @Test("Overlapping saves finish in any order and deliver their own outcomes")
    func overlappingSavesDoNotCrossWires() async {
        let queue = BackgroundSaveQueue()
        let blockers = [DispatchSemaphore(value: 0), DispatchSemaphore(value: 0), DispatchSemaphore(value: 0)]
        let (deliveries, continuation) = AsyncStream.makeStream(of: (submitted: Int, delivered: Int).self)

        // Three quick screenshots back to back — each save captured its own immutable snapshot
        // (here: its index) at submit time.
        for index in 0..<3 {
            let blocker = blockers[index]
            queue.submit(
                work: { blocker.wait(); return index * 10 },
                deliver: { continuation.yield((submitted: index, delivered: $0)) }
            )
        }
        #expect(queue.inFlightCount == 3, "all three saves are running at once")

        // Finish them out of submission order.
        for index in [2, 0, 1] { blockers[index].signal() }

        var seen = 0
        for await pair in deliveries {
            #expect(pair.delivered == pair.submitted * 10,
                    "save \(pair.submitted) must receive its own outcome, got \(pair.delivered)")
            seen += 1
            if seen == 3 { continuation.finish() }
        }
        #expect(seen == 3)
        #expect(queue.inFlightCount == 0)
    }

    @Test("Submit returns before the work runs its course, even when nothing ever waits on it")
    func submitNeverBlocksTheMainActor() {
        let queue = BackgroundSaveQueue()
        let blocker = DispatchSemaphore(value: 0)
        // If submit awaited the work, this synchronous main-actor test would deadlock here —
        // passing at all is the assertion.
        queue.submit(work: { blocker.wait() }, deliver: { _ in })
        #expect(queue.inFlightCount == 1)
        blocker.signal()
    }
}
