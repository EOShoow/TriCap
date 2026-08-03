import Foundation
import TriCapKit

/// Bounded, thread-safe accumulator for recorded frames.
///
/// ScreenCaptureKit delivers frames on its own queue while the UI decides when to stop, so this
/// has to be safe from both. It is also the component that makes "avoid unbounded memory growth"
/// true rather than aspirational: every append is checked against a frame-count ceiling *and* a
/// byte ceiling, and the first one that trips latches a stop reason which the recorder observes.
public final class FrameBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [RecordedFrame] = []
    private var bytes = 0
    private var dropped = 0
    private var limitReason: RecordingStopReason?

    public let maxFrameCount: Int
    public let maxBytes: Int

    public init(maxFrameCount: Int, maxBytes: Int) {
        self.maxFrameCount = max(1, maxFrameCount)
        self.maxBytes = max(1, maxBytes)
        frames.reserveCapacity(min(self.maxFrameCount, 1024))
    }

    public convenience init(limits: RecordingLimits) {
        self.init(maxFrameCount: limits.maxFrameCount, maxBytes: limits.maxFrameBufferBytes)
    }

    /// Append a frame unless a ceiling has been reached.
    ///
    /// - Returns: `true` if the frame was retained. `false` means a limit latched; the caller
    ///   should stop the stream. Once latched, later appends are rejected without growing memory.
    @discardableResult
    public func append(_ frame: RecordedFrame) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if limitReason != nil { return false }
        if frames.count >= maxFrameCount {
            limitReason = .frameCountLimit
            return false
        }
        if bytes + frame.pngData.count > maxBytes {
            limitReason = .memoryLimit
            return false
        }
        frames.append(frame)
        bytes += frame.pngData.count
        return true
    }

    /// Record that a delivered frame could not be processed in time.
    public func noteDropped() {
        lock.lock()
        dropped += 1
        lock.unlock()
    }

    public var snapshot: (frames: [RecordedFrame], bytes: Int, dropped: Int, limitReason: RecordingStopReason?) {
        lock.lock()
        defer { lock.unlock() }
        return (frames, bytes, dropped, limitReason)
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return frames.count
    }

    public var retainedBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return bytes
    }

    public var latchedLimit: RecordingStopReason? {
        lock.lock()
        defer { lock.unlock() }
        return limitReason
    }

    public func reset() {
        lock.lock()
        frames.removeAll(keepingCapacity: true)
        bytes = 0
        dropped = 0
        limitReason = nil
        lock.unlock()
    }
}
