import CoreGraphics
import Foundation
import Testing
@testable import CaptureCore
@testable import TriCapKit

// MARK: - Doubles

/// A `RecordingBackend` that records how it was driven, with no ScreenCaptureKit involved.
@MainActor
final class FakeRecordingBackend: RecordingBackend {
    var onProgress: (@MainActor (RecordingProgress) -> Void)?
    var onAutoStop: (@MainActor (RecordingStopReason) -> Void)?

    private(set) var startCount = 0
    private(set) var finishCount = 0
    private(set) var cancelCount = 0
    /// Ordered log, so tests can assert that teardown happened before `run()` returned.
    private(set) var events: [String] = []

    var startError: TriCapError?
    var finishError: TriCapError?
    /// Frames the fake clip should carry.
    var frameCount = 3

    func start() async throws {
        startCount += 1
        events.append("start")
        if let startError { throw startError }
    }

    func finish() async throws -> RecordedClip {
        finishCount += 1
        events.append("finish")
        if let finishError { throw finishError }
        return TestFixtures.clip(frameCount: frameCount)
    }

    func cancel() async {
        cancelCount += 1
        events.append("cancel")
    }

    /// Simulate a ceiling being hit inside the recorder.
    func fireAutoStop(_ reason: RecordingStopReason) {
        onAutoStop?(reason)
    }

    func emitProgress(frames: Int, elapsed: TimeInterval) {
        onProgress?(RecordingProgress(frameCount: frames, elapsed: elapsed, retainedBytes: frames * 1000))
    }

    var hasCallbacksAttached: Bool { onProgress != nil || onAutoStop != nil }
}

@MainActor
final class FakeRecordingChrome: RecordingChrome {
    private(set) var presentCount = 0
    private(set) var dismissCount = 0
    private(set) var progressUpdates: [RecordingProgress] = []
    private(set) var events: [String] = []

    private var onStop: (@MainActor () -> Void)?
    private var onCancel: (@MainActor () -> Void)?

    func present(
        region: CaptureRegion,
        onStop: @escaping @MainActor () -> Void,
        onCancel: @escaping @MainActor () -> Void
    ) {
        presentCount += 1
        events.append("present")
        self.onStop = onStop
        self.onCancel = onCancel
    }

    func update(progress: RecordingProgress, limits: RecordingLimits) {
        progressUpdates.append(progress)
    }

    func dismiss() {
        dismissCount += 1
        events.append("dismiss")
    }

    /// Simulate the user clicking Stop.
    func tapStop() { onStop?() }
    /// Simulate the global Escape hot key firing.
    func pressEscape() { onCancel?() }
}

// MARK: - Session lifecycle

@Suite("Recording session lifecycle")
@MainActor
struct RecordingSessionTests {

    private func makeSession(
        backend: FakeRecordingBackend,
        chrome: FakeRecordingChrome
    ) -> RecordingSession {
        RecordingSession(
            backend: backend,
            chrome: chrome,
            region: TestFixtures.region,
            limits: RecordingLimits(frameRate: 12, maxDuration: 15)
        )
    }

    @Test("A stop request completes the session and returns the clip")
    func stopProducesClip() async {
        let backend = FakeRecordingBackend()
        let chrome = FakeRecordingChrome()
        let session = makeSession(backend: backend, chrome: chrome)

        let task = Task { await session.run() }
        await Task.yield()
        while chrome.presentCount == 0 { await Task.yield() }

        chrome.tapStop()
        let outcome = await task.value

        guard case .finished(let clip) = outcome else {
            Issue.record("expected .finished, got \(outcome)")
            return
        }
        #expect(clip.frames.count == 3)
        #expect(backend.startCount == 1)
        #expect(backend.finishCount == 1)
        #expect(backend.cancelCount == 0)
        #expect(chrome.dismissCount == 1)
        #expect(session.phase == .done)
    }

    @Test("run() returns only after the backend has been torn down")
    func runAwaitsTeardown() async {
        // The regression this pins: the old flow released its "a capture is running" flag as soon
        // as the HUD appeared, so a second trigger could overwrite a live recording.
        let backend = FakeRecordingBackend()
        let chrome = FakeRecordingChrome()
        let session = makeSession(backend: backend, chrome: chrome)

        let task = Task { await session.run() }
        while chrome.presentCount == 0 { await Task.yield() }
        #expect(session.isActive)

        chrome.tapStop()
        _ = await task.value

        // By the time run() returns, chrome is dismissed and the backend has produced its clip.
        #expect(chrome.events == ["present", "dismiss"])
        #expect(backend.events == ["start", "finish"])
        #expect(!session.isActive)
        #expect(!backend.hasCallbacksAttached)
    }

    @Test("A second stop request is ignored and counted")
    func doubleStopIsIdempotent() async {
        let backend = FakeRecordingBackend()
        let chrome = FakeRecordingChrome()
        let session = makeSession(backend: backend, chrome: chrome)

        let task = Task { await session.run() }
        while chrome.presentCount == 0 { await Task.yield() }

        chrome.tapStop()
        chrome.tapStop()
        chrome.tapStop()
        _ = await task.value

        #expect(backend.finishCount == 1)
        #expect(backend.cancelCount == 0)
        #expect(chrome.dismissCount == 1)
        #expect(session.ignoredStopRequests == 2)
    }

    @Test("Cancel after stop does not also cancel the recorder")
    func cancelAfterStopIsIgnored() async {
        let backend = FakeRecordingBackend()
        let chrome = FakeRecordingChrome()
        let session = makeSession(backend: backend, chrome: chrome)

        let task = Task { await session.run() }
        while chrome.presentCount == 0 { await Task.yield() }

        chrome.tapStop()
        chrome.pressEscape()
        let outcome = await task.value

        if case .finished = outcome {} else { Issue.record("expected .finished, got \(outcome)") }
        #expect(backend.cancelCount == 0)
        #expect(session.ignoredStopRequests == 1)
    }

    @Test("Stop after cancel does not also finish the recorder")
    func stopAfterCancelIsIgnored() async {
        let backend = FakeRecordingBackend()
        let chrome = FakeRecordingChrome()
        let session = makeSession(backend: backend, chrome: chrome)

        let task = Task { await session.run() }
        while chrome.presentCount == 0 { await Task.yield() }

        chrome.pressEscape()
        chrome.tapStop()
        let outcome = await task.value

        if case .cancelled = outcome {} else { Issue.record("expected .cancelled, got \(outcome)") }
        #expect(backend.cancelCount == 1)
        #expect(backend.finishCount == 0)
        #expect(chrome.dismissCount == 1)
    }

    @Test("An automatic stop is treated as a stop, and a later user stop is ignored")
    func autoStopWinsOnce() async {
        let backend = FakeRecordingBackend()
        let chrome = FakeRecordingChrome()
        let session = makeSession(backend: backend, chrome: chrome)

        let task = Task { await session.run() }
        while chrome.presentCount == 0 { await Task.yield() }

        backend.fireAutoStop(.durationLimit)
        backend.fireAutoStop(.durationLimit)
        chrome.tapStop()
        let outcome = await task.value

        if case .finished = outcome {} else { Issue.record("expected .finished, got \(outcome)") }
        #expect(backend.finishCount == 1)
        #expect(session.autoStopReason == .durationLimit)
        #expect(session.ignoredStopRequests == 2)
    }

    @Test("A stop that arrives before the session starts waiting is honoured, not lost")
    func stopBeforeWaitIsHonoured() async {
        let backend = FakeRecordingBackend()
        let chrome = FakeRecordingChrome()
        let session = makeSession(backend: backend, chrome: chrome)

        // Latch a stop while `run()` is still inside `backend.start()`.
        let task = Task { await session.run() }
        await Task.yield()
        session.requestStop()

        let outcome = await task.value
        if case .finished = outcome {} else { Issue.record("expected .finished, got \(outcome)") }
        #expect(backend.finishCount == 1)
    }

    @Test("A session cannot be run twice")
    func doubleRunRejected() async {
        let backend = FakeRecordingBackend()
        let chrome = FakeRecordingChrome()
        let session = makeSession(backend: backend, chrome: chrome)

        let task = Task { await session.run() }
        while chrome.presentCount == 0 { await Task.yield() }
        chrome.tapStop()
        _ = await task.value

        let second = await session.run()
        if case .failed = second {} else { Issue.record("expected .failed, got \(second)") }
        #expect(backend.startCount == 1)
    }

    @Test("A backend that fails to start dismisses the chrome and reports the error")
    func startFailureIsClean() async {
        let backend = FakeRecordingBackend()
        backend.startError = .captureFailed("no stream")
        let chrome = FakeRecordingChrome()
        let session = makeSession(backend: backend, chrome: chrome)

        let outcome = await session.run()
        if case .failed = outcome {} else { Issue.record("expected .failed, got \(outcome)") }
        #expect(chrome.presentCount == 0)
        #expect(chrome.dismissCount == 1)
        #expect(!backend.hasCallbacksAttached)
    }

    @Test("Progress is forwarded to the chrome while running and stops afterwards")
    func progressForwarding() async {
        let backend = FakeRecordingBackend()
        let chrome = FakeRecordingChrome()
        let session = makeSession(backend: backend, chrome: chrome)

        let task = Task { await session.run() }
        while chrome.presentCount == 0 { await Task.yield() }

        backend.emitProgress(frames: 5, elapsed: 0.4)
        backend.emitProgress(frames: 9, elapsed: 0.8)
        chrome.tapStop()
        _ = await task.value

        #expect(chrome.progressUpdates.count == 2)
        #expect(chrome.progressUpdates.last?.frameCount == 9)

        // Detached: a late progress callback from a straggling timer must not reach the chrome.
        backend.emitProgress(frames: 99, elapsed: 9)
        #expect(chrome.progressUpdates.count == 2)
    }
}

// MARK: - Gate

@Suite("Capture session gate")
@MainActor
struct CaptureSessionGateTests {

    @Test("Only one capture may hold the gate at a time")
    func singleOccupancy() {
        let gate = CaptureSessionGate()
        #expect(gate.tryBegin())
        #expect(!gate.tryBegin())
        #expect(!gate.tryBegin())
        #expect(gate.refusedEntries == 2)
        #expect(gate.isBusy)
    }

    @Test("The gate is reusable once released")
    func releaseAllowsReentry() {
        let gate = CaptureSessionGate()
        #expect(gate.tryBegin())
        gate.end()
        #expect(!gate.isBusy)
        #expect(gate.tryBegin())
    }

    @Test("Every phase of one capture stays inside a single occupancy")
    func phasesStayOccupied() {
        let gate = CaptureSessionGate()
        #expect(gate.tryBegin())
        for phase in [CaptureSessionGate.Phase.countdown, .recording, .finishing] {
            gate.transition(to: phase)
            #expect(gate.phase == phase)
            // The whole point: a second trigger during any of these is refused.
            #expect(!gate.tryBegin())
        }
        gate.end()
        #expect(gate.phase == .idle)
    }

    @Test("A stale transition cannot re-occupy a released gate")
    func staleTransitionIgnored() {
        let gate = CaptureSessionGate()
        #expect(gate.tryBegin())
        gate.end()
        gate.transition(to: .recording)
        #expect(gate.phase == .idle)
        #expect(!gate.isBusy)
    }

    @Test("Transitioning to idle is not a way to release the gate")
    func cannotTransitionToIdle() {
        let gate = CaptureSessionGate()
        #expect(gate.tryBegin())
        gate.transition(to: .idle)
        #expect(gate.phase == .selecting)
    }
}
