import CoreGraphics
import Foundation

/// Hard ceilings on everything that could otherwise grow without bound.
///
/// TriCap records raw frames into memory, so *every* one of these numbers is load-bearing:
/// duration × frame rate bounds the frame count, the long-edge cap bounds each frame's
/// pixel count, and `maxFrameBufferBytes` is the backstop that stops a recording even if
/// the first two were configured absurdly.
public struct RecordingLimits: Sendable, Equatable, Codable {
    /// Frames per second requested from ScreenCaptureKit and written into the WebP.
    public var frameRate: Int
    /// Wall-clock ceiling for a single recording.
    public var maxDuration: TimeInterval
    /// Longest output edge in pixels; frames are downscaled to fit.
    public var maxLongEdgePixels: Int
    /// Backstop on the retained (PNG-compressed) frame buffer.
    public var maxFrameBufferBytes: Int

    public static let frameRateRange = 1...30
    public static let durationRange: ClosedRange<TimeInterval> = 1...30
    public static let longEdgeRange = 320...3840

    public init(
        frameRate: Int = 12,
        maxDuration: TimeInterval = 15,
        maxLongEdgePixels: Int = 1440,
        maxFrameBufferBytes: Int = 512 * 1024 * 1024
    ) {
        self.frameRate = frameRate.clamped(to: Self.frameRateRange)
        self.maxDuration = maxDuration.clamped(to: Self.durationRange)
        self.maxLongEdgePixels = maxLongEdgePixels.clamped(to: Self.longEdgeRange)
        self.maxFrameBufferBytes = max(16 * 1024 * 1024, maxFrameBufferBytes)
    }

    /// Absolute ceiling on retained frames. `+1` because a recording that runs the full
    /// duration legitimately produces a frame at t=0 *and* one at t=maxDuration.
    public var maxFrameCount: Int {
        max(1, Int((maxDuration * Double(frameRate)).rounded(.down)) + 1)
    }

    /// Nominal spacing between frames.
    public var frameInterval: TimeInterval { 1.0 / Double(max(1, frameRate)) }

    public static let `default` = RecordingLimits()
}

/// Options for the animated-WebP encoder.
public struct AnimatedWebPOptions: Sendable, Equatable, Codable {
    /// 0...100; libwebp's lossy quality factor.
    public var quality: Int
    /// 0 = loop forever, which is the TriCap default.
    public var loopCount: Int
    /// Lossless frames trade a large size increase for exactness; off by default.
    public var lossless: Bool
    /// libwebp encoding effort, 0 (fast) ... 6 (slow/smaller).
    public var method: Int

    public static let qualityRange = 0...100

    public init(quality: Int = 80, loopCount: Int = 0, lossless: Bool = false, method: Int = 4) {
        self.quality = quality.clamped(to: Self.qualityRange)
        self.loopCount = max(0, loopCount)
        self.lossless = lossless
        self.method = method.clamped(to: 0...6)
    }

    public static let `default` = AnimatedWebPOptions()
}

extension Comparable {
    public func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

extension Duration {
    /// `Duration` expressed as a `TimeInterval`.
    ///
    /// `ContinuousClock` arithmetic yields a `Duration`, while the capture pipeline works in
    /// seconds. Deliberately not named `seconds` — that would collide with the
    /// `Duration.seconds(_:)` static factory and resolve to it at the call site.
    public var timeIntervalValue: TimeInterval {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
