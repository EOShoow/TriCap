import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit
import TriCapKit

/// Live progress pushed to the recording HUD.
public struct RecordingProgress: Sendable, Equatable {
    public let frameCount: Int
    public let elapsed: TimeInterval
    public let retainedBytes: Int

    public init(frameCount: Int, elapsed: TimeInterval, retainedBytes: Int) {
        self.frameCount = frameCount
        self.elapsed = elapsed
        self.retainedBytes = retainedBytes
    }
}

/// Records a screen region into a bounded in-memory frame buffer.
///
/// Lifecycle: `start()` → (frames accumulate) → `finish()` / `cancel()`. The recorder stops
/// itself when any ceiling in ``RecordingLimits`` is reached, reporting the reason through
/// `onAutoStop` so the UI can explain the truncation instead of silently producing a short clip.
@MainActor
public final class RegionRecorder {

    public enum State: Sendable, Equatable { case idle, running, finished }

    public private(set) var state: State = .idle

    public var onProgress: (@MainActor (RecordingProgress) -> Void)?
    public var onAutoStop: (@MainActor (RecordingStopReason) -> Void)?

    /// Called for every frame the recorder actually retains, with the normalised image and its
    /// offset in seconds from the first frame.
    ///
    /// Exists so a live pre-encoder can see the same frames the PNG buffer holds without the
    /// recorder knowing anything about WebP. **It runs on the ScreenCaptureKit delivery queue and
    /// must return immediately** — anything slow here drops captures. Set before `start()`.
    public var onFrameAccepted: (@Sendable (CGImage, TimeInterval) -> Void)?

    private let region: CaptureRegion
    private let limits: RecordingLimits
    private let showsCursor: Bool
    private let includedOwnWindowIDs: Set<CGWindowID>
    private let outputPixelSize: CGSize

    private let buffer: FrameBuffer
    private var stream: SCStream?
    private var output: StreamOutput?
    private var delegate: StreamDelegate?
    private var tickTimer: Timer?
    private var stopReason: RecordingStopReason = .userStopped

    /// Monotonic instants. `ContinuousClock` rather than `Date` so an NTP correction or a
    /// timezone change mid-recording cannot move the duration limit.
    private var startInstant: ContinuousClock.Instant?
    private var stopInstant: ContinuousClock.Instant?

    /// Captured after the sample queue is drained but before teardown releases the output, because
    /// `finish()` needs both after the stream is gone.
    private var observedColorSpace: ImageProcessing.ColorSpaceOutcome?
    private var firstFrameInstant: ContinuousClock.Instant?

    /// Cached so a repeated `finish()` returns the identical clip instead of re-deriving one from
    /// a buffer that may since have been reset.
    private var producedClip: RecordedClip?

    /// Latched by the first automatic stop. Without it the 10 Hz tick would re-report the duration
    /// ceiling on every tick until someone got round to calling `finish()`.
    private var hasAutoStopped = false

    private let sampleQueue = DispatchQueue(label: "app.tricap.capture.samples", qos: .userInitiated)

    public init(
        region: CaptureRegion,
        limits: RecordingLimits,
        showsCursor: Bool = false,
        includingOwnWindowIDs: Set<CGWindowID> = []
    ) {
        self.region = region
        self.limits = limits
        self.showsCursor = showsCursor
        self.includedOwnWindowIDs = includingOwnWindowIDs
        self.outputPixelSize = CaptureConfiguration.outputPixelSize(
            for: region,
            maxLongEdge: limits.maxLongEdgePixels
        )
        self.buffer = FrameBuffer(limits: limits)
    }

    /// Pixel size every recorded frame will have.
    public var pixelSize: CGSize { outputPixelSize }

    public func start() async throws {
        guard state == .idle else { return }

        let content = try await ScreenRecordingPermission.shareableContent()
        let filter = try CaptureConfiguration.filter(
            for: region,
            content: content,
            includingOwnWindowIDs: includedOwnWindowIDs
        )
        let config = CaptureConfiguration.recordingConfiguration(
            region: region,
            outputPixelSize: outputPixelSize,
            limits: limits,
            showsCursor: showsCursor
        )

        let buffer = self.buffer
        let expected = outputPixelSize

        let output = StreamOutput(
            buffer: buffer,
            expectedPixelSize: expected,
            fallbackSourceColorSpace: region.display.displayColorSpace,
            sourceDisplayIsWideGamutOrHDR: region.display.needsColorConversionNotice
        )
        output.onFrameAccepted = onFrameAccepted
        output.onAutoStop = { [weak self] reason in
            Task { @MainActor in self?.handleAutoStop(reason) }
        }
        let delegate = StreamDelegate { [weak self] _ in
            Task { @MainActor in self?.handleAutoStop(.streamError) }
        }

        let stream = SCStream(filter: filter, configuration: config, delegate: delegate)
        do {
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: sampleQueue)
            try await stream.startCapture()
        } catch {
            throw TriCapError.captureFailed((error as NSError).localizedDescription)
        }

        self.stream = stream
        self.output = output
        self.delegate = delegate
        self.startInstant = ContinuousClock.now
        self.state = .running

        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer

        TriCapLog.capture.info(
            "recording started \(Int(expected.width), privacy: .public)x\(Int(expected.height), privacy: .public) @\(self.limits.frameRate, privacy: .public)fps max=\(self.limits.maxDuration, privacy: .public)s"
        )
    }

    /// Stop and return everything captured so far.
    public func finish() async throws -> RecordedClip {
        if let producedClip { return producedClip }

        try await teardown()

        let snapshot = buffer.snapshot
        guard !snapshot.frames.isEmpty else { throw TriCapError.noFramesCaptured }

        let clip = RecordedClip(
            frames: snapshot.frames,
            pixelSize: outputPixelSize,
            region: region,
            nominalFrameInterval: limits.frameInterval,
            stopReason: snapshot.limitReason ?? stopReason,
            droppedFrameCount: snapshot.dropped,
            colorSpace: observedColorSpace,
            retainedBytes: snapshot.bytes,
            wallClockDuration: measuredWallClockDuration()
        )
        producedClip = clip
        TriCapLog.capture.info(
            """
            recording finished frames=\(clip.frames.count, privacy: .public) \
            bytes=\(clip.retainedBytes, privacy: .public) \
            reason=\(clip.stopReason.rawValue, privacy: .public) \
            dropped=\(clip.droppedFrameCount, privacy: .public) \
            wall=\(clip.wallClockDuration, privacy: .public)s
            """
        )
        return clip
    }

    /// Abandon the recording and release every retained frame.
    public func cancel() async {
        stopReason = .cancelled
        try? await teardown()
        buffer.reset()
        producedClip = nil
        TriCapLog.capture.info("recording cancelled")
    }

    // MARK: - Internals

    /// Elapsed time from the first retained frame to the moment capture stopped.
    private func measuredWallClockDuration() -> TimeInterval {
        guard let firstFrameInstant else { return 0 }
        let end = stopInstant ?? ContinuousClock.now
        return max(0, (end - firstFrameInstant).timeIntervalValue)
    }

    /// Report an automatic stop exactly once. The first reason wins.
    private func handleAutoStop(_ reason: RecordingStopReason) {
        guard state == .running, !hasAutoStopped else { return }
        hasAutoStopped = true
        stopReason = reason
        // Stop retaining frames immediately. Even if nobody is listening to `onAutoStop`, memory
        // stops growing and the recording stops advancing the moment a ceiling is hit.
        output?.stopAccepting()
        if stopInstant == nil { stopInstant = ContinuousClock.now }
        // Progress ticks are meaningless once the recording is over, and leaving the timer running
        // would re-trip the ceiling on every tick.
        tickTimer?.invalidate()
        tickTimer = nil
        onAutoStop?(reason)
    }

    /// Runs at 10 Hz on the main run loop: reports progress *and* enforces the duration ceiling.
    ///
    /// The ceiling has to be checked here rather than when a frame arrives. ScreenCaptureKit only
    /// delivers a `.complete` frame when the picture actually changed, so a static screen produces
    /// no frames at all — a frame-driven check would let a "15 second maximum" recording run for
    /// as long as the user left it, silently.
    private func tick() {
        guard state == .running, let startInstant else { return }
        let elapsed = (ContinuousClock.now - startInstant).timeIntervalValue

        onProgress?(
            RecordingProgress(
                frameCount: buffer.count,
                elapsed: elapsed,
                retainedBytes: buffer.retainedBytes
            )
        )

        if elapsed >= limits.maxDuration {
            TriCapLog.capture.info("duration ceiling reached at \(elapsed, privacy: .public)s")
            handleAutoStop(.durationLimit)
        }
    }

    private func teardown() async throws {
        tickTimer?.invalidate()
        tickTimer = nil
        guard state == .running, let stream else {
            state = .finished
            return
        }
        state = .finished
        if let output {
            // `stopAccepting` is a commit barrier: after it returns no callback can append another
            // frame. Capture the stop instant after that barrier so it is never earlier than the
            // final retained frame.
            output.stopAccepting()
            if stopInstant == nil { stopInstant = ContinuousClock.now }
            try? stream.removeStreamOutput(output, type: .screen)
        }
        do {
            try await stream.stopCapture()
        } catch {
            // A stream that already stopped (limit hit, display disconnected) throws here; the
            // frames we have are still valid, so this is logged rather than propagated.
            TriCapLog.capture.error("stopCapture: \(error.localizedDescription, privacy: .public)")
        }
        // ScreenCaptureKit invokes callbacks on this serial queue. Removing the output and stopping
        // capture prevents new callbacks; enqueuing a barrier afterwards waits for every callback
        // that was already in flight to finish before we snapshot or reset shared state.
        await drainSampleQueue()
        if let output {
            let snapshot = output.stateSnapshot
            observedColorSpace = snapshot.observedColorSpace
            firstFrameInstant = snapshot.firstFrameInstant
        }
        self.stream = nil
        self.output = nil
        self.delegate = nil
    }

    private func drainSampleQueue() async {
        await withCheckedContinuation { continuation in
            sampleQueue.async { continuation.resume() }
        }
    }
}

// MARK: - SCK plumbing

/// Receives sample buffers on `sampleQueue`. Everything here runs off the main actor.
final class StreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    struct StateSnapshot: Sendable {
        let observedColorSpace: ImageProcessing.ColorSpaceOutcome?
        let firstFrameInstant: ContinuousClock.Instant?
    }

    enum CommitResult: Sendable, Equatable {
        case accepted
        case rejectedAfterStop
        case autoStop(RecordingStopReason)
    }

    private let buffer: FrameBuffer
    private let expectedPixelSize: CGSize
    private let fallbackSourceColorSpace: CGColorSpace
    private let sourceDisplayIsWideGamutOrHDR: Bool

    private let lock = NSLock()
    private var baseTimestamp: TimeInterval?
    private var stopped = false
    private var _observedColorSpace: ImageProcessing.ColorSpaceOutcome?
    private var _firstFrameInstant: ContinuousClock.Instant?

    var onAutoStop: (@Sendable (RecordingStopReason) -> Void)?

    /// Called for every frame that is actually retained, with the normalised image and its
    /// offset from the first frame. Used to feed the live pre-encoder.
    ///
    /// Must return immediately: it runs on the ScreenCaptureKit delivery path.
    var onFrameAccepted: (@Sendable (CGImage, TimeInterval) -> Void)?

    var stateSnapshot: StateSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return StateSnapshot(
            observedColorSpace: _observedColorSpace,
            firstFrameInstant: _firstFrameInstant
        )
    }

    init(
        buffer: FrameBuffer,
        expectedPixelSize: CGSize,
        fallbackSourceColorSpace: CGColorSpace = ImageProcessing.outputColorSpace,
        sourceDisplayIsWideGamutOrHDR: Bool = false
    ) {
        self.buffer = buffer
        self.expectedPixelSize = expectedPixelSize
        self.fallbackSourceColorSpace = fallbackSourceColorSpace
        self.sourceDisplayIsWideGamutOrHDR = sourceDisplayIsWideGamutOrHDR
    }

    /// Latch the output closed without firing `onAutoStop`. Used by the recorder's own teardown
    /// and by the duration ceiling, both of which report the reason themselves.
    func stopAccepting() {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }

        guard isAccepting else { return }

        guard let frame = FrameConverter.frame(
            from: sampleBuffer,
            expectedPixelSize: expectedPixelSize,
            fallbackSourceColorSpace: fallbackSourceColorSpace,
            sourceDisplayIsWideGamutOrHDR: sourceDisplayIsWideGamutOrHDR
        ) else {
            return
        }

        guard let png = ImageProcessing.pngData(from: frame.image) else {
            noteDroppedIfAccepting()
            return
        }

        switch commit(frame: frame, pngData: png, receivedAt: ContinuousClock.now) {
        case .accepted, .rejectedAfterStop:
            break
        case .autoStop(let reason):
            onAutoStop?(reason)
        }
    }

    /// The single commit point for decoded frames. Encoding happens outside the lock, but this
    /// method re-checks `stopped` while holding the same lock as `stopAccepting()`. Consequently,
    /// once `stopAccepting()` returns, an earlier callback can no longer append after cancellation
    /// or after finish has taken its snapshot.
    func commit(
        frame: FrameConverter.Frame,
        pngData: Data,
        receivedAt: ContinuousClock.Instant = .now
    ) -> CommitResult {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return .rejectedAfterStop
        }

        let base = baseTimestamp ?? frame.presentationSeconds
        let elapsed = max(0, frame.presentationSeconds - base)
        guard buffer.append(RecordedFrame(pngData: pngData, timestamp: elapsed)) else {
            stopped = true
            lock.unlock()
            return .autoStop(buffer.latchedLimit ?? .frameCountLimit)
        }

        if baseTimestamp == nil { baseTimestamp = frame.presentationSeconds }
        if _observedColorSpace == nil { _observedColorSpace = frame.colorSpace }
        if _firstFrameInstant == nil { _firstFrameInstant = receivedAt }
        let observer = onFrameAccepted
        lock.unlock()

        // Fired *outside* the lock and only for frames that were actually retained, so the live
        // pre-encoder sees exactly the frames the fallback path holds — no more, no fewer. The
        // contract is that this returns immediately; anything expensive here would stall the
        // ScreenCaptureKit callback and drop captures.
        observer?(frame.image, elapsed)
        return .accepted
    }

    private var isAccepting: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !stopped
    }

    private func noteDroppedIfAccepting() {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return }
        buffer.noteDropped()
    }
}

private final class StreamDelegate: NSObject, SCStreamDelegate, @unchecked Sendable {
    private let onStop: @Sendable (Error) -> Void

    init(onStop: @escaping @Sendable (Error) -> Void) {
        self.onStop = onStop
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        TriCapLog.capture.error("stream stopped: \(error.localizedDescription, privacy: .public)")
        onStop(error)
    }
}
