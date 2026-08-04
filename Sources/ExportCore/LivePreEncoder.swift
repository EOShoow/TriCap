import CoreGraphics
import Dispatch
import Foundation
import TriCapKit

/// Encodes animation frames *while the recording runs*, so the wait after Export is short.
///
/// # Why this exists
///
/// The ordinary path holds every frame as PNG and does all the WebP work after the user clicks
/// Export: decode PNG, composite annotations, encode, assemble, write, verify. On a static screen
/// that is cheap, because libwebp coalesces nearly everything. On genuinely high-motion content
/// almost nothing coalesces and the tail is proportional to the recording — the user waits through
/// the clip twice.
///
/// # The rules it lives by
///
/// - **Never block capture.** ``submit(image:timestampMs:)`` does no encoding. It hands the frame
///   to a private serial queue and returns. A ScreenCaptureKit sample callback that stalls drops
///   frames, and a dropped frame is a worse outcome than a slow export.
/// - **Bounded.** At most ``maxBacklog`` frames may be waiting. Past that the fast path is
///   abandoned rather than allowed to grow: the PNG buffer is already bounded and a second
///   unbounded queue of live bitmaps would defeat that.
/// - **Never load-bearing.** Every failure — backlog, encoder error, cancellation — abandons the
///   fast path silently. The PNG frames are still there, so the export simply takes the route it
///   always took. Nothing the user recorded can be lost by this type.
/// - **One serial context.** `WebPAnimEncoderSession` is not re-entrant, and it is touched only on
///   `queue`.
public final class LivePreEncoder: @unchecked Sendable {

    /// Why the fast path is not available. Recorded rather than thrown, because none of these is
    /// an error the user needs to see.
    public enum Abandonment: Equatable, Sendable {
        case backlog(pending: Int, limit: Int)
        case encoderFailed(String)
        case cancelled
        case setupFailed(String)

        public var reason: String {
            switch self {
            case .backlog(let pending, let limit):
                return "pre-encoding fell \(pending) frames behind (limit \(limit))"
            case .encoderFailed(let message): return "pre-encoder failed: \(message)"
            case .cancelled: return "recording was cancelled"
            case .setupFailed(let message): return "pre-encoder could not start: \(message)"
            }
        }
    }

    /// How many frames may be queued for encoding before the fast path is given up.
    ///
    /// Two seconds of capture at the maximum frame rate. Large enough to ride out a slow frame or
    /// a scheduling hiccup, small enough that the live bitmaps waiting here stay a bounded and
    /// small fraction of what the PNG buffer already costs.
    public static let defaultMaxBacklog = 60

    public let maxBacklog: Int
    private let queue: DispatchQueue
    private let canvasSize: CGSize
    private let options: AnimatedWebPOptions
    private let strategy: AnimationEncodeStrategy

    private let lock = NSLock()
    private var session: WebPAnimEncoderSession?
    private var pending = 0
    private var submitted = 0
    private var encoded = 0
    private var abandonment: Abandonment?
    private var peakPending = 0
    /// Wall-clock cost of every `WebPAnimEncoderAdd`, for the benchmark's p50/p95. Bounded by the
    /// recording's own frame ceiling (30 fps × 30 s max), so no cap is needed.
    private var encodeDurationsMs: [Double] = []
    /// The shared timeline rule, so the timestamps here are exactly the ones `ClipTiming` will
    /// compute for the same frames at export time — including grid smoothing, which both sides
    /// derive from the same nominal interval.
    private let nominalFrameInterval: TimeInterval
    private var timeline: IncrementalTimeline

    /// - Parameter frameRate: sizes the default backlog and anchors the smoothing grid — it must
    ///   be the recording's real frame rate, or the live timeline diverges from the export one.
    public init(
        canvasSize: CGSize,
        options: AnimatedWebPOptions,
        frameRate: Int,
        strategy: AnimationEncodeStrategy = .default,
        maxBacklog: Int? = nil
    ) {
        self.canvasSize = canvasSize
        self.options = options
        self.strategy = strategy
        self.nominalFrameInterval = 1.0 / Double(max(1, frameRate))
        self.timeline = IncrementalTimeline(nominalFrameInterval: 1.0 / Double(max(1, frameRate)))
        self.maxBacklog = maxBacklog ?? max(8, min(Self.defaultMaxBacklog, frameRate * 5))
        self.queue = DispatchQueue(
            label: "app.tricap.pre-encode",
            qos: .utility,          // below the capture queue on purpose
            autoreleaseFrequency: .workItem
        )

        do {
            session = try WebPAnimEncoderSession(canvasSize: canvasSize, options: options, strategy: strategy)
        } catch {
            abandonment = .setupFailed(error.localizedDescription)
            TriCapLog.export.info("live pre-encode unavailable: \(error.localizedDescription, privacy: .public)")
        }
    }

    deinit {
        // The encoder holds libwebp memory; releasing it must not depend on anyone remembering to
        // call `cancel()`.
        session?.release()
    }

    // MARK: - State

    public var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return session != nil && abandonment == nil
    }

    public var abandonedBecause: Abandonment? {
        lock.lock(); defer { lock.unlock() }
        return abandonment
    }

    public var pendingFrames: Int {
        lock.lock(); defer { lock.unlock() }
        return pending
    }

    public var encodedFrames: Int {
        lock.lock(); defer { lock.unlock() }
        return encoded
    }

    public var submittedFrames: Int {
        lock.lock(); defer { lock.unlock() }
        return submitted
    }

    /// Everything the benchmarks need to judge whether pre-encoding kept up.
    ///
    /// Read at any time; a consistent snapshot is taken under the same lock the counters use.
    public struct Diagnostics: Sendable {
        public let submitted: Int
        public let encoded: Int
        /// The largest number of frames that were ever waiting at once. Compared against
        /// `maxBacklog` this is the honest "how close did we come to giving up" number.
        public let peakBacklog: Int
        public let backlogLimit: Int
        public let abandonment: Abandonment?
        /// Wall-clock milliseconds spent inside `WebPAnimEncoderAdd`, one entry per frame.
        public let encodeDurationsMs: [Double]

        public var p50EncodeMs: Double? { Self.percentile(50, of: encodeDurationsMs) }
        public var p95EncodeMs: Double? { Self.percentile(95, of: encodeDurationsMs) }

        /// Nearest-rank percentile. Pure and pinned by tests: the gate thresholds in the release
        /// plan are expressed against exactly this definition.
        public static func percentile(_ p: Double, of values: [Double]) -> Double? {
            guard !values.isEmpty else { return nil }
            let sorted = values.sorted()
            let clamped = min(max(p, 0), 100)
            let rank = Int((clamped / 100 * Double(sorted.count)).rounded(.up))
            return sorted[max(0, min(sorted.count - 1, rank - 1))]
        }
    }

    public var diagnostics: Diagnostics {
        lock.lock(); defer { lock.unlock() }
        return Diagnostics(
            submitted: submitted,
            encoded: encoded,
            peakBacklog: peakPending,
            backlogLimit: maxBacklog,
            abandonment: abandonment,
            encodeDurationsMs: encodeDurationsMs
        )
    }

    // MARK: - Feeding

    /// Hand one frame to the pre-encoder. Returns immediately; never encodes on the caller's
    /// thread.
    ///
    /// Called from the capture path with the same normalised image that becomes the PNG frame, so
    /// the fast path and the fallback are encoding identical pixels.
    public func submit(image: CGImage, captureTimestamp: TimeInterval) {
        lock.lock()
        guard session != nil, abandonment == nil else {
            lock.unlock()
            return
        }
        if pending >= maxBacklog {
            // Give up rather than queue without limit. The recording is unaffected.
            let reason = Abandonment.backlog(pending: pending, limit: maxBacklog)
            abandonment = reason
            lock.unlock()
            TriCapLog.export.info("live pre-encode abandoned: \(reason.reason, privacy: .public)")
            releaseSessionAsync()
            return
        }
        pending += 1
        submitted += 1
        if pending > peakPending { peakPending = pending }
        let timestampMs = timeline.append(captureTimestamp: captureTimestamp)
        lock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            self.encodeOne(image: image, timestampMs: timestampMs)
        }
    }

    private func encodeOne(image: CGImage, timestampMs: Int) {
        lock.lock()
        let active = session != nil && abandonment == nil
        let session = self.session
        lock.unlock()

        guard active, let session else {
            lock.lock(); pending -= 1; lock.unlock()
            return
        }

        let encodeStart = ContinuousClock.now
        let ok = session.add(image: image, timestampMs: timestampMs)
        let elapsed = ContinuousClock.now - encodeStart
        let elapsedMs = Double(elapsed.components.seconds) * 1000
            + Double(elapsed.components.attoseconds) / 1e15

        lock.lock()
        pending -= 1
        encodeDurationsMs.append(elapsedMs)
        if ok {
            encoded += 1
        } else if abandonment == nil {
            abandonment = .encoderFailed(session.failure ?? "unknown")
            let message = abandonment!.reason
            lock.unlock()
            TriCapLog.export.info("live pre-encode abandoned: \(message, privacy: .public)")
            releaseSessionAsync()
            return
        }
        lock.unlock()
    }

    // MARK: - Finishing

    /// Wait for the queue to drain and assemble the animation.
    ///
    /// Blocks the caller — it is called once, after capture has stopped, from the export path.
    /// Returns `nil` whenever the fast path is not available for any reason, which the caller
    /// treats as "encode normally".
    public func finish(endTimestampMs: Int) -> PreEncodedAnimation? {
        // Drain: a barrier runs after every queued frame.
        queue.sync(flags: .barrier) {}

        lock.lock()
        guard let session, abandonment == nil, encoded > 0, encoded == submitted else {
            let why = abandonment?.reason
                ?? (encoded == 0 ? "nothing was pre-encoded" : "only \(encoded) of \(submitted) frames encoded")
            self.session?.release()
            self.session = nil
            lock.unlock()
            TriCapLog.export.info("live pre-encode not used: \(why, privacy: .public)")
            return nil
        }
        let timestamps = timeline.timestampsMs
        let frameCount = encoded
        self.session = nil
        lock.unlock()

        guard let data = session.finish(endTimestampMs: endTimestampMs) else {
            TriCapLog.export.info(
                "live pre-encode assemble failed: \(session.failure ?? "unknown", privacy: .public)"
            )
            return nil
        }

        TriCapLog.export.info(
            "live pre-encode produced \(data.count, privacy: .public) bytes from \(frameCount, privacy: .public) frames"
        )
        return PreEncodedAnimation(
            data: data,
            canvasSize: canvasSize,
            options: options,
            frameCount: frameCount,
            timestampsMs: timestamps,
            endTimestampMs: endTimestampMs
        )
    }

    /// Abandon and free everything — a cancelled recording, or the app quitting.
    public func cancel() {
        lock.lock()
        if abandonment == nil { abandonment = .cancelled }
        let session = self.session
        self.session = nil
        timeline = IncrementalTimeline(nominalFrameInterval: nominalFrameInterval)
        lock.unlock()

        queue.async { session?.release() }
    }

    private func releaseSessionAsync() {
        lock.lock()
        let session = self.session
        self.session = nil
        lock.unlock()
        queue.async { session?.release() }
    }
}
