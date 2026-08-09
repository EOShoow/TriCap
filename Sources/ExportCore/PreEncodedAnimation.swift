import CoreGraphics
import Foundation
import TriCapKit

/// An animated WebP that was assembled *while the recording was still running*.
///
/// It carries the exact conditions it was produced under, because reusing it is only correct when
/// the export being asked for is byte-for-byte the same job. Anything the user changed afterwards
/// — a trim, an annotation, a different quality — must go back through the ordinary per-frame
/// render-and-encode path.
public struct PreEncodedAnimation: Sendable {
    public let data: Data
    /// Canvas of the source frames before a possible export crop is applied.
    public let canvasSize: CGSize
    /// Crop already baked into `data`. `nil` means full-canvas, as produced while recording.
    public let cropRect: CGRect?
    public let options: AnimatedWebPOptions
    /// How many frames went into it.
    public let frameCount: Int
    /// The absolute timestamps that were submitted, in order.
    public let timestampsMs: [Int]
    /// The end timestamp the encoder was flushed with, which fixes the last frame's duration.
    public let endTimestampMs: Int

    public init(
        data: Data,
        canvasSize: CGSize,
        options: AnimatedWebPOptions,
        frameCount: Int,
        timestampsMs: [Int],
        endTimestampMs: Int,
        cropRect: CGRect? = nil
    ) {
        self.data = data
        self.canvasSize = canvasSize
        self.cropRect = cropRect
        self.options = options
        self.frameCount = frameCount
        self.timestampsMs = timestampsMs
        self.endTimestampMs = endTimestampMs
    }
}

/// Decides whether a pre-encoded animation may be used for a given export.
///
/// A pure function with an explicit reason, so every rejection is testable and every acceptance is
/// justified. The default answer is *no*: the fast path is an optimisation, and the only thing it
/// is allowed to change is how long the user waits.
public enum PreEncodeReuse {

    public enum Decision: Equatable, Sendable {
        case reuse
        /// Nothing was pre-encoded — pre-encoding was off, abandoned, or failed.
        case noArtifact
        /// The user trimmed the clip, so the frame range no longer matches.
        case frameRangeChanged(preEncoded: Int, requested: Int)
        /// Annotations have to be composited onto each frame.
        case hasAnnotations(count: Int)
        /// The requested crop differs from the one already baked into the artifact.
        case cropChanged(preEncoded: CGRect?, requested: CGRect?)
        case canvasChanged(preEncoded: CGSize, requested: CGSize)
        case optionsChanged(field: String)
        /// Trimming can leave the frame count intact while moving the timeline.
        case timelineChanged

        public var isReuse: Bool { self == .reuse }

        /// One line for the diagnostics log and the self-test. Never shown to the user: choosing
        /// the slow path is not something they need to know about.
        public var reason: String {
            switch self {
            case .reuse: return "reused the pre-encoded animation"
            case .noArtifact: return "no pre-encoded animation available"
            case .frameRangeChanged(let pre, let requested):
                return "frame range changed (\(pre) pre-encoded, \(requested) requested)"
            case .hasAnnotations(let count): return "\(count) annotation(s) must be composited"
            case .cropChanged(let preEncoded, let requested):
                let describe: (CGRect?) -> String = { rect in
                    guard let rect else { return "full canvas" }
                    return "\(Int(rect.width))×\(Int(rect.height)) at (\(Int(rect.minX)), \(Int(rect.minY)))"
                }
                return "crop changed (\(describe(preEncoded)) → \(describe(requested)))"
            case .canvasChanged(let pre, let requested):
                return "canvas changed (\(Int(pre.width))×\(Int(pre.height)) → \(Int(requested.width))×\(Int(requested.height)))"
            case .optionsChanged(let field): return "\(field) changed"
            case .timelineChanged: return "timeline changed"
            }
        }
    }

    /// Whether `artifact` can stand in for encoding `source` with `annotations` and `options`.
    ///
    /// Checked in the order a reader would ask the questions, and every condition is a hard
    /// requirement rather than a heuristic:
    ///
    /// - the whole recording, untrimmed (same frame count *and* same timestamps)
    /// - no annotations, since those are composited per frame
    /// - the same crop, since the artifact may already have one baked in
    /// - the same canvas
    /// - the same encoder parameters, all four of them
    /// - the same end timestamp, which fixes the final frame's duration
    public static func decide(
        artifact: PreEncodedAnimation?,
        source: AnimationFrameSource,
        annotationCount: Int,
        options: AnimatedWebPOptions,
        cropRect: CGRect? = nil
    ) -> Decision {
        guard let artifact else { return .noArtifact }
        guard artifact.frameCount == source.frameCount else {
            return .frameRangeChanged(preEncoded: artifact.frameCount, requested: source.frameCount)
        }
        guard annotationCount == 0 else { return .hasAnnotations(count: annotationCount) }
        guard artifact.canvasSize == source.canvasSize else {
            return .canvasChanged(preEncoded: artifact.canvasSize, requested: source.canvasSize)
        }
        guard artifact.cropRect == cropRect else {
            return .cropChanged(preEncoded: artifact.cropRect, requested: cropRect)
        }
        if artifact.options.quality != options.quality { return .optionsChanged(field: "quality") }
        if artifact.options.lossless != options.lossless { return .optionsChanged(field: "lossless") }
        if artifact.options.method != options.method { return .optionsChanged(field: "method") }
        if artifact.options.loopCount != options.loopCount { return .optionsChanged(field: "loop count") }
        guard artifact.endTimestampMs == source.endTimestampMs else { return .timelineChanged }
        // The frame count can match while the *contents* of the range differ — trimming an equal
        // number of frames off each end, for instance.
        guard artifact.timestampsMs == source.timestampsMs else { return .timelineChanged }
        guard !artifact.data.isEmpty else { return .noArtifact }
        return .reuse
    }
}
