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

    private let region: CaptureRegion
    private let limits: RecordingLimits
    private let showsCursor: Bool
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

    /// Captured before teardown tears the output down, because `finish()` needs both after the
    /// stream is gone.
    private var observedColorSpace: ImageProcessing.ColorSpaceOutcome?
    private var firstFrameInstant: ContinuousClock.Instant?

    /// Cached so a repeated `finish()` returns the identical clip instead of re-deriving one from
    /// a buffer that may since have been reset.
    private var producedClip: RecordedClip?

    /// Latched by the first automatic stop. Without it the 10 Hz tick would re-report the duration
    /// ceiling on every tick until someone got round to calling `finish()`.
    private var hasAutoStopped = false

    private let sampleQueue = DispatchQueue(label: "app.tricap.capture.samples", qos: .userInitiated)

    public init(region: CaptureRegion, limits: RecordingLimits, showsCursor: Bool = false) {
        self.region = region
        self.limits = limits
        self.showsCursor = showsCursor
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
        let filter = try CaptureConfiguration.filter(for: region, content: content)
        let config = CaptureConfiguration.recordingConfiguration(
            region: region,
            outputPixelSize: outputPixelSize,
            limits: limits,
            showsCursor: showsCursor
        )

        let buffer = self.buffer
        let expected = outputPixelSize

        let output = StreamOutput(buffer: buffer, expectedPixelSize: expected)
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

        // Snapshot everything the output owns *before* teardown releases it.
        captureOutputState()
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
        captureOutputState()
        try? await teardown()
        buffer.reset()
        producedClip = nil
        TriCapLog.capture.info("recording cancelled")
    }

    // MARK: - Internals

    /// Copy the values that live on the stream output before `teardown()` drops it.
    private func captureOutputState() {
        if let output {
            observedColorSpace = output.observedColorSpace
            firstFrameInstant = output.firstFrameInstant
        }
        if stopInstant == nil { stopInstant = ContinuousClock.now }
    }

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
            output.stopAccepting()
            try? stream.removeStreamOutput(output, type: .screen)
        }
        do {
            try await stream.stopCapture()
        } catch {
            // A stream that already stopped (limit hit, display disconnected) throws here; the
            // frames we have are still valid, so this is logged rather than propagated.
            TriCapLog.capture.error("stopCapture: \(error.localizedDescription, privacy: .public)")
        }
        self.stream = nil
        self.output = nil
        self.delegate = nil
    }
}

// MARK: - SCK plumbing

/// Receives sample buffers on `sampleQueue`. Everything here runs off the main actor.
private final class StreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    private let buffer: FrameBuffer
    private let expectedPixelSize: CGSize

    private let lock = NSLock()
    private var baseTimestamp: TimeInterval?
    private var stopped = false
    private var _observedColorSpace: ImageProcessing.ColorSpaceOutcome?
    private var _firstFrameInstant: ContinuousClock.Instant?

    var onAutoStop: (@Sendable (RecordingStopReason) -> Void)?

    var observedColorSpace: ImageProcessing.ColorSpaceOutcome? {
        lock.lock()
        defer { lock.unlock() }
        return _observedColorSpace
    }

    /// Monotonic instant at which the first frame was retained.
    var firstFrameInstant: ContinuousClock.Instant? {
        lock.lock()
        defer { lock.unlock() }
        return _firstFrameInstant
    }

    init(buffer: FrameBuffer, expectedPixelSize: CGSize) {
        self.buffer = buffer
        self.expectedPixelSize = expectedPixelSize
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

        lock.lock()
        let alreadyStopped = stopped
        lock.unlock()
        if alreadyStopped { return }

        guard let frame = FrameConverter.frame(from: sampleBuffer, expectedPixelSize: expectedPixelSize) else {
            return
        }

        let now = ContinuousClock.now
        lock.lock()
        if _observedColorSpace == nil { _observedColorSpace = frame.colorSpace }
        if baseTimestamp == nil { baseTimestamp = frame.presentationSeconds }
        if _firstFrameInstant == nil { _firstFrameInstant = now }
        let base = baseTimestamp ?? frame.presentationSeconds
        lock.unlock()

        let elapsed = max(0, frame.presentationSeconds - base)

        guard let png = ImageProcessing.pngData(from: frame.image) else {
            buffer.noteDropped()
            return
        }

        if !buffer.append(RecordedFrame(pngData: png, timestamp: elapsed)) {
            latchStop(buffer.latchedLimit ?? .frameCountLimit)
        }
    }

    private func latchStop(_ reason: RecordingStopReason) {
        lock.lock()
        let first = !stopped
        stopped = true
        lock.unlock()
        if first { onAutoStop?(reason) }
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
