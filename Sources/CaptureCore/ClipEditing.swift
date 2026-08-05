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

    /// How long the trimmed clip should play for.
    ///
    /// Two cases, and getting them right is what makes a trimmed static tail behave:
    ///
    /// - **The tail is kept** (`range.upperBound` is the last frame): the clip runs until the
    ///   recording actually stopped, so a final frame that sat unchanged for fourteen seconds
    ///   holds for fourteen seconds rather than for one frame interval.
    /// - **The tail is trimmed off**: the last kept frame is displayed until the moment the first
    ///   dropped frame would have replaced it — i.e. `frames[upperBound + 1].timestamp`. Anything
    ///   else would either truncate or invent time.
    ///
    /// The result is relative to the first kept frame and never negative.
    public static func trimmedDuration(
        frames: [RecordedFrame],
        range: ClosedRange<Int>,
        clipDuration: TimeInterval
    ) -> TimeInterval {
        guard !frames.isEmpty else { return 0 }
        let lo = range.lowerBound.clamped(to: 0...(frames.count - 1))
        let hi = range.upperBound.clamped(to: 0...(frames.count - 1))
        guard lo <= hi else { return 0 }

        let start = frames[lo].timestamp
        let end: TimeInterval = (hi == frames.count - 1)
            ? clipDuration
            : frames[hi + 1].timestamp
        return max(0, end - start)
    }

    /// Convenience wrapper that normalises the indices first.
    public static func trim(clip: RecordedClip, first: Int, last: Int) -> RecordedClip {
        guard let range = normalizedRange(first: first, last: last, count: clip.frames.count) else {
            return clip
        }
        let kept = trim(frames: clip.frames, to: range)
        let duration = trimmedDuration(frames: clip.frames, range: range, clipDuration: clip.duration)
        return RecordedClip(
            frames: kept,
            pixelSize: clip.pixelSize,
            region: clip.region,
            nominalFrameInterval: clip.nominalFrameInterval,
            stopReason: clip.stopReason,
            droppedFrameCount: clip.droppedFrameCount,
            colorSpace: clip.colorSpace,
            retainedBytes: kept.reduce(0) { $0 + $1.pngData.count },
            wallClockDuration: duration
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
    ///
    /// - Parameter totalDuration: how long the clip should play for, measured from the first
    ///   frame. Pass ``RecordedClip/duration`` (or ``ClipTrimmer/trimmedDuration(frames:range:clipDuration:)``
    ///   for a trimmed clip) so that a final frame which sat unchanged holds for its real time.
    ///   `nil` falls back to giving the last frame one nominal interval, which is only correct
    ///   when the recording stopped immediately after that frame arrived.
    public static func timeline(
        for frames: [RecordedFrame],
        nominalFrameInterval: TimeInterval,
        totalDuration: TimeInterval? = nil,
        minimumFrameDurationMs: Int = ClipTiming.minimumFrameDurationMs
    ) -> FrameTimeline? {
        guard !frames.isEmpty else { return nil }
        let minStep = max(1, minimumFrameDurationMs)

        // Shared with the live pre-encoder, which has to produce identical timestamps while the
        // recording is still running — see `IncrementalTimeline`. The nominal interval switches
        // on grid smoothing in both places at once; they can never disagree.
        let timestamps = IncrementalTimeline.timestamps(
            forCaptureTimestamps: frames.map(\.timestamp),
            minimumStepMs: minStep,
            nominalFrameInterval: nominalFrameInterval
        )

        let lastTimestamp = timestamps[timestamps.count - 1]
        let nominalMs = max(minStep, Int((nominalFrameInterval * 1000.0).rounded()))
        // The measured clip length wins when it is longer than "last frame + one interval"; the
        // floor keeps the final frame from becoming an imperceptible flash.
        let measuredEnd = totalDuration.map { Int(($0 * 1000.0).rounded()) } ?? 0
        let end = max(measuredEnd, lastTimestamp + nominalMs)
        return FrameTimeline(timestampsMs: timestamps, endTimestampMs: end)
    }
}

/// Preview playback for the editor: the player plays **exactly what the export would produce**
/// for the current trim — same frame durations, same holds, same loop-forever behaviour as the
/// animated WebP itself. Anything else would be a lie the user only discovers after exporting.
public enum ClipPlayback {

    /// The timeline the player steps through, identical to the one `EditorModel.export()` builds:
    /// trimmed frames re-based to zero, grid-smoothed, with the real trimmed duration deciding the
    /// final frame's hold.
    public static func timeline(clip: RecordedClip, trimStart: Int, trimEnd: Int) -> FrameTimeline? {
        guard let range = ClipTrimmer.normalizedRange(
            first: trimStart, last: trimEnd, count: clip.frames.count
        ) else { return nil }
        let frames = ClipTrimmer.trim(frames: clip.frames, to: range)
        let duration = ClipTrimmer.trimmedDuration(
            frames: clip.frames, range: range, clipDuration: clip.duration
        )
        return ClipTiming.timeline(
            for: frames,
            nominalFrameInterval: clip.nominalFrameInterval,
            totalDuration: duration
        )
    }

    /// `m:ss.t` — enough resolution to see a hold ticking by, compact enough for a toolbar.
    public static func timeString(ms: Int) -> String {
        let clamped = max(0, ms)
        let tenths = (clamped % 1000) / 100
        let seconds = (clamped / 1000) % 60
        let minutes = clamped / 60_000
        return String(format: "%d:%02d.%d", minutes, seconds, tenths)
    }
}

/// Slider ranges for the editor's trim handles and preview scrubber.
///
/// Pure so the one-frame case is pinned by a test rather than by eyeballing the window. A clip
/// with a single frame has nothing to trim and nothing to scrub: padding the range to `0...1`
/// to keep `Slider` happy would let the user select frame index 1, which does not exist.
public enum ClipTrimUI {

    public static func isTrimmable(frameCount: Int) -> Bool { frameCount > 1 }

    /// Range for the Start/End handles, or `nil` when the clip cannot be trimmed.
    public static func handleRange(frameCount: Int) -> ClosedRange<Double>? {
        guard isTrimmable(frameCount: frameCount) else { return nil }
        return 0...Double(frameCount - 1)
    }

    /// Range for the preview scrubber, or `nil` when there is only one position to be in.
    public static func scrubRange(trimStart: Int, trimEnd: Int) -> ClosedRange<Double>? {
        guard trimEnd > trimStart else { return nil }
        return Double(trimStart)...Double(trimEnd)
    }
}
