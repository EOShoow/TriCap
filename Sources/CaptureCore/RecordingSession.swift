import Foundation
import TriCapKit

/// The recorder seen by ``RecordingSession``.
///
/// Exists so the session's lifecycle rules can be tested without ScreenCaptureKit, a window
/// server, or a real screen. ``RegionRecorder`` conforms as-is.
@MainActor
public protocol RecordingBackend: AnyObject {
    var onProgress: (@MainActor (RecordingProgress) -> Void)? { get set }
    var onAutoStop: (@MainActor (RecordingStopReason) -> Void)? { get set }
    func start() async throws
    func finish() async throws -> RecordedClip
    func cancel() async
}

extension RegionRecorder: RecordingBackend {}

/// The on-screen furniture a recording owns: the stop HUD, the region outline, and the temporary
/// global cancel key. Abstracted for the same reason as ``RecordingBackend``.
@MainActor
public protocol RecordingChrome: AnyObject {
    /// Show the stop control. Both callbacks may fire any number of times; the session dedupes.
    func present(
        region: CaptureRegion,
        onStop: @escaping @MainActor () -> Void,
        onCancel: @escaping @MainActor () -> Void
    )
    func update(progress: RecordingProgress, limits: RecordingLimits)
    /// Tear everything down. Must be safe to call more than once.
    func dismiss()
}

/// Owns one recording from `start()` to complete teardown.
///
/// The invariant this type exists to hold: **`run()` does not return until the backend has been
/// fully torn down and the chrome dismissed.** Callers gate on its completion, so a second hot-key
/// press cannot begin a new session that overwrites the live recorder, HUD or cancel key of the
/// first. Stop and cancel are latched — the first request wins and every later one is counted and
/// ignored, which is what makes a double-click on Stop, or Stop racing an automatic duration
/// stop, harmless.
@MainActor
public final class RecordingSession {

    public enum Outcome: Sendable {
        case finished(RecordedClip)
        case cancelled
        case failed(TriCapError)
    }

    public enum Phase: String, Sendable, Equatable {
        case idle
        case starting
        case running
        case stopping
        case done
    }

    private enum StopKind { case stop, cancel }

    public private(set) var phase: Phase = .idle
    /// Stop/cancel requests ignored because one had already been latched. Surfaced for tests and
    /// for the log, so a double-stop is visible rather than invisible.
    public private(set) var ignoredStopRequests = 0
    /// Why the recording ended, when it ended by itself.
    public private(set) var autoStopReason: RecordingStopReason?

    private let backend: any RecordingBackend
    private let chrome: any RecordingChrome
    private let region: CaptureRegion
    private let limits: RecordingLimits

    private var latchedStop: StopKind?
    private var waiter: CheckedContinuation<StopKind, Never>?

    public init(
        backend: any RecordingBackend,
        chrome: any RecordingChrome,
        region: CaptureRegion,
        limits: RecordingLimits
    ) {
        self.backend = backend
        self.chrome = chrome
        self.region = region
        self.limits = limits
    }

    /// `true` while the session still owns the screen and the recorder.
    public var isActive: Bool { phase != .idle && phase != .done }

    /// Run the recording to completion. Returns only after teardown.
    public func run() async -> Outcome {
        guard phase == .idle else {
            return .failed(.captureFailed("A recording session cannot be run twice."))
        }
        phase = .starting

        backend.onProgress = { [weak self] progress in
            guard let self else { return }
            self.chrome.update(progress: progress, limits: self.limits)
        }
        backend.onAutoStop = { [weak self] reason in
            guard let self else { return }
            if self.autoStopReason == nil { self.autoStopReason = reason }
            TriCapLog.capture.info("session auto-stop: \(reason.rawValue, privacy: .public)")
            // An automatic stop is a stop, not a cancel: the frames captured so far are kept.
            self.request(.stop)
        }

        do {
            try await backend.start()
        } catch {
            phase = .done
            detachBackend()
            chrome.dismiss()
            return .failed(asTriCapError(error))
        }

        phase = .running
        chrome.present(
            region: region,
            onStop: { [weak self] in self?.request(.stop) },
            onCancel: { [weak self] in self?.request(.cancel) }
        )

        let kind = await waitForStop()

        phase = .stopping
        detachBackend()
        chrome.dismiss()

        switch kind {
        case .cancel:
            await backend.cancel()
            phase = .done
            return .cancelled
        case .stop:
            do {
                let clip = try await backend.finish()
                phase = .done
                return .finished(clip)
            } catch {
                phase = .done
                return .failed(asTriCapError(error))
            }
        }
    }

    /// Ask the recording to stop and keep its frames. Idempotent.
    public func requestStop() { request(.stop) }

    /// Ask the recording to stop and discard its frames. Idempotent.
    public func requestCancel() { request(.cancel) }

    // MARK: - Internals

    private func request(_ kind: StopKind) {
        guard phase == .starting || phase == .running else {
            ignoredStopRequests += 1
            return
        }
        guard latchedStop == nil else {
            ignoredStopRequests += 1
            return
        }
        latchedStop = kind
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: kind)
        }
    }

    private func waitForStop() async -> StopKind {
        // A stop can be latched before `run()` gets here — an immediate duration ceiling, or a
        // user hammering Esc during `start()`. Honour it without suspending.
        if let latchedStop { return latchedStop }
        return await withCheckedContinuation { continuation in
            if let latchedStop {
                continuation.resume(returning: latchedStop)
            } else {
                self.waiter = continuation
            }
        }
    }

    private func detachBackend() {
        backend.onProgress = nil
        backend.onAutoStop = nil
    }

    private func asTriCapError(_ error: Error) -> TriCapError {
        (error as? TriCapError) ?? .captureFailed((error as NSError).localizedDescription)
    }
}

/// Single-slot gate for the whole capture pipeline.
///
/// One gate, one session: selection, countdown, recording, teardown and the editor hand-off all
/// live inside a single occupancy. Every entry point — the global hot key and both menu items —
/// goes through ``tryBegin()``, so there is exactly one place that decides whether a new capture
/// may start.
@MainActor
public final class CaptureSessionGate {

    public enum Phase: String, Sendable, Equatable {
        case idle
        case selecting
        case countdown
        case recording
        case finishing
        case capturingStill
    }

    public private(set) var phase: Phase = .idle
    /// Entry attempts refused because a capture was already in flight.
    public private(set) var refusedEntries = 0

    public init() {}

    public var isBusy: Bool { phase != .idle }

    /// Claim the gate. `false` means a capture is already running and the caller must do nothing.
    public func tryBegin() -> Bool {
        guard phase == .idle else {
            refusedEntries += 1
            TriCapLog.app.info("capture request refused: session already in \(self.phase.rawValue, privacy: .public)")
            return false
        }
        phase = .selecting
        return true
    }

    /// Move an occupied gate to a later phase. Ignored when the gate is idle, so a stale
    /// transition from a finished session cannot re-occupy it.
    public func transition(to next: Phase) {
        guard phase != .idle, next != .idle else { return }
        phase = next
    }

    /// Release the gate. Safe to call more than once.
    public func end() {
        phase = .idle
    }
}
