import Foundation

/// Turns capture timestamps into WebP frame timestamps, one frame at a time.
///
/// The animation timeline has always been computed in one pass at export time. Pre-encoding needs
/// the *same* numbers while frames are still arriving, and "the same" has to be exact: if the live
/// path and the export path disagree about a single millisecond, the pre-encoded file is silently
/// wrong. So the rule lives here once, and both paths run it.
///
/// The rule: the first frame is 0, and every later frame is its real offset from the first, forced
/// to be at least `minimumStepMs` past its predecessor. ScreenCaptureKit hands out true
/// presentation times, so two frames can share a millisecond after a fast redraw and be far apart
/// after a stall; the encoder rejects a non-increasing timestamp outright.
///
/// Only per-frame timestamps are derivable live. The clip's *end* timestamp depends on the
/// measured wall-clock duration, which is not known until recording stops — see
/// `ClipTiming.timeline(for:nominalFrameInterval:totalDuration:)`.
public struct IncrementalTimeline: Sendable {

    /// Browsers and the WebP format both dislike zero-length frames; 10 ms is the smallest
    /// duration every mainstream renderer honours without clamping.
    public static let defaultMinimumStepMs = 10

    public private(set) var timestampsMs: [Int] = []

    private let minimumStepMs: Int
    private var base: TimeInterval?

    public init(minimumStepMs: Int = IncrementalTimeline.defaultMinimumStepMs) {
        self.minimumStepMs = max(1, minimumStepMs)
    }

    public var count: Int { timestampsMs.count }
    public var last: Int? { timestampsMs.last }

    /// Append one capture timestamp and return the animation timestamp it maps to.
    @discardableResult
    public mutating func append(captureTimestamp: TimeInterval) -> Int {
        guard let base else {
            self.base = captureTimestamp
            timestampsMs.append(0)
            return 0
        }
        let raw = Int(((captureTimestamp - base) * 1000.0).rounded())
        let value = timestampsMs.last.map { max(raw, $0 + minimumStepMs) } ?? 0
        timestampsMs.append(value)
        return value
    }

    /// Run the whole rule over a sequence at once. `ClipTiming` uses this, so the batch and live
    /// paths cannot drift apart.
    public static func timestamps(
        forCaptureTimestamps captureTimestamps: [TimeInterval],
        minimumStepMs: Int = IncrementalTimeline.defaultMinimumStepMs
    ) -> [Int] {
        var timeline = IncrementalTimeline(minimumStepMs: minimumStepMs)
        for timestamp in captureTimestamps { timeline.append(captureTimestamp: timestamp) }
        return timeline.timestampsMs
    }
}
