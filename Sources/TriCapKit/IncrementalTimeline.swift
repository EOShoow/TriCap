import Foundation

/// Turns capture timestamps into WebP frame timestamps, one frame at a time.
///
/// The animation timeline has always been computed in one pass at export time. Pre-encoding needs
/// the *same* numbers while frames are still arriving, and "the same" has to be exact: if the live
/// path and the export path disagree about a single millisecond, the pre-encoded file is silently
/// wrong. So the rule lives here once, and both paths run it.
///
/// # The base rule
///
/// The first frame is 0, and every later frame is its real offset from the first, forced to be at
/// least `minimumStepMs` past its predecessor. ScreenCaptureKit hands out true presentation
/// times, so two frames can share a millisecond after a fast redraw and be far apart after a
/// stall; the encoder rejects a non-increasing timestamp outright.
///
/// # Grid smoothing (when a nominal frame interval is provided)
///
/// A real 12 fps recording measured frame gaps wobbling between 66 and 100 ms — ScreenCaptureKit
/// delivers when content changes, not on a metronome — and that wobble plays back as judder on
/// top of the low frame rate. With `nominalFrameInterval` set, timestamps snap to the **absolute
/// grid** at multiples of the interval, but only when the deviation is small:
///
/// - snap only within 25% of the interval — a bigger deviation is information, not noise;
/// - **causal**: each frame is decided as it arrives, from already-arrived frames only, because
///   the live pre-encoder writes the value into the WebP immediately and nothing can be rewritten;
/// - a real hold — a gap of at least twice the interval, like the seconds a static screen sits
///   unchanged — is never snapped, so it can never be shortened;
/// - strict monotonicity and the minimum step always win over the grid (two frames pulled to the
///   same tick resolve to `previous + minimumStepMs`).
///
/// Without a nominal interval the behaviour is bit-identical to the original rule.
///
/// Only per-frame timestamps are derivable live. The clip's *end* timestamp depends on the
/// measured wall-clock duration, which is not known until recording stops — see
/// `ClipTiming.timeline(for:nominalFrameInterval:totalDuration:)`.
public struct IncrementalTimeline: Sendable {

    /// Browsers and the WebP format both dislike zero-length frames; 10 ms is the smallest
    /// duration every mainstream renderer honours without clamping.
    public static let defaultMinimumStepMs = 10

    /// Snap window, as a fraction of the nominal interval.
    public static let snapToleranceFraction = 0.25

    /// A gap at least this many nominal intervals long is a hold, and holds are untouchable.
    public static let holdThresholdIntervals = 2.0

    public private(set) var timestampsMs: [Int] = []

    private let minimumStepMs: Int
    /// Nominal frame interval in (fractional) milliseconds, or `nil` for the un-smoothed rule.
    private let gridMs: Double?
    private let toleranceMs: Double
    private var base: TimeInterval?
    /// Previous capture time on the raw, base-relative axis. Hold detection must use this rather
    /// than the previous emitted timestamp, which may already have moved onto the grid.
    private var previousRawMs: Double?

    public init(
        minimumStepMs: Int = IncrementalTimeline.defaultMinimumStepMs,
        nominalFrameInterval: TimeInterval? = nil
    ) {
        self.minimumStepMs = max(1, minimumStepMs)
        if let nominalFrameInterval, nominalFrameInterval > 0 {
            let grid = nominalFrameInterval * 1000.0
            self.gridMs = grid
            self.toleranceMs = grid * Self.snapToleranceFraction
        } else {
            self.gridMs = nil
            self.toleranceMs = 0
        }
    }

    public var count: Int { timestampsMs.count }
    public var last: Int? { timestampsMs.last }

    /// Append one capture timestamp and return the animation timestamp it maps to.
    @discardableResult
    public mutating func append(captureTimestamp: TimeInterval) -> Int {
        guard let base else {
            self.base = captureTimestamp
            previousRawMs = 0
            timestampsMs.append(0)
            return 0
        }
        let rawMs = (captureTimestamp - base) * 1000.0
        let raw = Int(rawMs.rounded())
        // Non-first frame, so the array is never empty here.
        let previous = timestampsMs.last ?? 0

        var value = raw
        if let gridMs {
            let rawGapMs = rawMs - (previousRawMs ?? rawMs)
            let isHold = rawGapMs >= Self.holdThresholdIntervals * gridMs
            if isHold {
                // Preserve the real duration relative to the already-emitted frame. Keeping only
                // the new raw absolute timestamp would still shorten or lengthen the hold when
                // the preceding frame had snapped in either direction.
                value = previous + Int(rawGapMs.rounded())
            } else {
                let tickMs = (rawMs / gridMs).rounded() * gridMs
                if abs(rawMs - tickMs) <= toleranceMs {
                    value = Int(tickMs.rounded())
                }
            }
        }

        value = max(value, previous + minimumStepMs)
        previousRawMs = rawMs
        timestampsMs.append(value)
        return value
    }

    /// Run the whole rule over a sequence at once. `ClipTiming` uses this, so the batch and live
    /// paths cannot drift apart.
    public static func timestamps(
        forCaptureTimestamps captureTimestamps: [TimeInterval],
        minimumStepMs: Int = IncrementalTimeline.defaultMinimumStepMs,
        nominalFrameInterval: TimeInterval? = nil
    ) -> [Int] {
        var timeline = IncrementalTimeline(
            minimumStepMs: minimumStepMs, nominalFrameInterval: nominalFrameInterval
        )
        for timestamp in captureTimestamps { timeline.append(captureTimestamp: timestamp) }
        return timeline.timestampsMs
    }
}
