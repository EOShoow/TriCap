import Foundation
import TriCapKit

/// Head/tail trimming for a recorded clip.
///
/// Trimming is expressed as an inclusive frame-index range because that is what the editor's
/// two-handle slider produces, and because index arithmetic has no floating-point edge cases.
/// Timestamps are re-based to zero so the exported animation starts immediately.
public enum ClipTrimmer {

    /// Clamp an arbitrary (possibly inverted or out-of-range) index pair to a valid inclusive range.
    ///
    /// Returns `nil` only when there is nothing to trim, i.e. `count <= 0`.
    public static func normalizedRange(first: Int, last: Int, count: Int) -> ClosedRange<Int>? {
        guard count > 0 else { return nil }
        let lo = min(first, last).clamped(to: 0...(count - 1))
        let hi = max(first, last).clamped(to: 0...(count - 1))
        return lo...hi
    }

    /// Keep frames `range` and re-base their timestamps so the first kept frame is at t=0.
    public static func trim(frames: [RecordedFrame], to range: ClosedRange<Int>) -> [RecordedFrame] {
        guard !frames.isEmpty else { return [] }
        let lo = range.lowerBound.clamped(to: 0...(frames.count - 1))
        let hi = range.upperBound.clamped(to: 0...(frames.count - 1))
        guard lo <= hi else { return [] }
        let kept = Array(frames[lo...hi])
        guard let base = kept.first?.timestamp else { return [] }
        return kept.map { RecordedFrame(pngData: $0.pngData, timestamp: $0.timestamp - base) }
    }

    /// Convenience wrapper that normalises the indices first.
    public static func trim(clip: RecordedClip, first: Int, last: Int) -> RecordedClip {
        guard let range = normalizedRange(first: first, last: last, count: clip.frames.count) else {
            return clip
        }
        let kept = trim(frames: clip.frames, to: range)
        return RecordedClip(
            frames: kept,
            pixelSize: clip.pixelSize,
            region: clip.region,
            nominalFrameInterval: clip.nominalFrameInterval,
            stopReason: clip.stopReason,
            droppedFrameCount: clip.droppedFrameCount,
            colorSpace: clip.colorSpace,
            retainedBytes: kept.reduce(0) { $0 + $1.pngData.count }
        )
    }
}

/// Absolute frame timestamps in milliseconds, exactly as `WebPAnimEncoderAdd` wants them.
public struct FrameTimeline: Sendable, Equatable {
    /// Strictly increasing, `first == 0`, one entry per frame.
    public let timestampsMs: [Int]
    /// Timestamp handed to `WebPAnimEncoderAdd(enc, NULL, end, ...)`; strictly greater than the last frame.
    public let endTimestampMs: Int

    public var frameCount: Int { timestampsMs.count }
    public var totalDurationMs: Int { endTimestampMs }

    /// Per-frame display durations implied by the timeline.
    public var durationsMs: [Int] {
        guard !timestampsMs.isEmpty else { return [] }
        var out: [Int] = []
        out.reserveCapacity(timestampsMs.count)
        for i in 0..<timestampsMs.count {
            let next = (i + 1 < timestampsMs.count) ? timestampsMs[i + 1] : endTimestampMs
            out.append(next - timestampsMs[i])
        }
        return out
    }
}

public enum ClipTiming {
    /// Browsers and the WebP format both dislike zero-length frames; 10 ms is the smallest
    /// duration that every mainstream renderer honours without clamping.
    public static let minimumFrameDurationMs = 10

    /// Turn captured presentation timestamps into a valid, strictly increasing WebP timeline.
    ///
    /// ScreenCaptureKit timestamps are real presentation times, so two frames can land in the
    /// same millisecond (or, after a stall, be far apart). Both are handled: durations are
    /// floored at ``minimumFrameDurationMs`` and the sequence is forced strictly increasing, so
    /// the encoder can never be handed a non-monotonic timestamp.
    public static func timeline(
        for frames: [RecordedFrame],
        nominalFrameInterval: TimeInterval,
        minimumFrameDurationMs: Int = ClipTiming.minimumFrameDurationMs
    ) -> FrameTimeline? {
        guard !frames.isEmpty else { return nil }
        let minStep = max(1, minimumFrameDurationMs)
        let base = frames[0].timestamp

        var timestamps: [Int] = []
        timestamps.reserveCapacity(frames.count)
        for frame in frames {
            let raw = Int(((frame.timestamp - base) * 1000.0).rounded())
            if let previous = timestamps.last {
                timestamps.append(max(raw, previous + minStep))
            } else {
                timestamps.append(0)
            }
        }

        let nominalMs = max(minStep, Int((nominalFrameInterval * 1000.0).rounded()))
        let end = timestamps[timestamps.count - 1] + nominalMs
        return FrameTimeline(timestampsMs: timestamps, endTimestampMs: end)
    }
}
