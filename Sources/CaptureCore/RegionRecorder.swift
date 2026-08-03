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
    private var progressTimer: Timer?
    private var startDate: Date?
    private var stopReason: RecordingStopReason = .userStopped

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
        let maxDuration = limits.maxDuration

        let output = StreamOutput(buffer: buffer, expectedPixelSize: expected, maxDuration: maxDuration)
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
        self.startDate = Date()
        self.state = .running

        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.emitProgress() }
        }
        RunLoop.main.add(timer, forMode: .common)
        progressTimer = timer

        TriCapLog.capture.info(
            "recording started \(Int(expected.width), privacy: .public)x\(Int(expected.height), privacy: .public) @\(self.limits.frameRate, privacy: .public)fps max=\(self.limits.maxDuration, privacy: .public)s"
        )
    }

    /// Stop and return everything captured so far.
    public func finish() async throws -> RecordedClip {
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
            colorSpace: output?.observedColorSpace,
            retainedBytes: snapshot.bytes
        )
        TriCapLog.capture.info(
            "recording finished frames=\(clip.frames.count, privacy: .public) bytes=\(clip.retainedBytes, privacy: .public) reason=\(clip.stopReason.rawValue, privacy: .public) dropped=\(clip.droppedFrameCount, privacy: .public)"
        )
        return clip
    }

    /// Abandon the recording and release every retained frame.
    public func cancel() async {
        stopReason = .cancelled
        try? await teardown()
        buffer.reset()
        TriCapLog.capture.info("recording cancelled")
    }

    // MARK: - Internals

    private func handleAutoStop(_ reason: RecordingStopReason) {
        guard state == .running else { return }
        stopReason = reason
        onAutoStop?(reason)
    }

    private func emitProgress() {
        guard state == .running, let startDate else { return }
        onProgress?(
            RecordingProgress(
                frameCount: buffer.count,
                elapsed: Date().timeIntervalSince(startDate),
                retainedBytes: buffer.retainedBytes
            )
        )
    }

    private func teardown() async throws {
        progressTimer?.invalidate()
        progressTimer = nil
        guard state == .running, let stream else {
            state = .finished
            return
        }
        state = .finished
        if let output {
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
    private let maxDuration: TimeInterval

    private let lock = NSLock()
    private var baseTimestamp: TimeInterval?
    private var stopped = false
    private var _observedColorSpace: ImageProcessing.ColorSpaceOutcome?

    var onAutoStop: (@Sendable (RecordingStopReason) -> Void)?

    var observedColorSpace: ImageProcessing.ColorSpaceOutcome? {
        lock.lock()
        defer { lock.unlock() }
        return _observedColorSpace
    }

    init(buffer: FrameBuffer, expectedPixelSize: CGSize, maxDuration: TimeInterval) {
        self.buffer = buffer
        self.expectedPixelSize = expectedPixelSize
        self.maxDuration = maxDuration
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

        lock.lock()
        if _observedColorSpace == nil { _observedColorSpace = frame.colorSpace }
        if baseTimestamp == nil { baseTimestamp = frame.presentationSeconds }
        let base = baseTimestamp ?? frame.presentationSeconds
        lock.unlock()

        let elapsed = max(0, frame.presentationSeconds - base)
        if elapsed > maxDuration {
            latchStop(.durationLimit)
            return
        }

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
