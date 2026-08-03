import CoreGraphics
import Foundation
import TriCapKit

/// A single still capture, already normalised to opaque sRGB.
public struct CapturedStill: @unchecked Sendable {
    public let image: CGImage
    public let region: CaptureRegion
    public let colorSpace: ImageProcessing.ColorSpaceOutcome

    public init(image: CGImage, region: CaptureRegion, colorSpace: ImageProcessing.ColorSpaceOutcome) {
        self.image = image
        self.region = region
        self.colorSpace = colorSpace
    }

    public var pixelSize: CGSize { CGSize(width: image.width, height: image.height) }
}

/// One recorded frame. Held as PNG bytes rather than a live `CGImage` so that a 15-second
/// recording costs tens of megabytes instead of a gigabyte of IOSurface-backed bitmaps.
public struct RecordedFrame: Sendable, Equatable {
    /// PNG-encoded, opaque sRGB, already downscaled to the clip's output size.
    public let pngData: Data
    /// Seconds since the first accepted frame. Monotonically increasing, starts at 0.
    public let timestamp: TimeInterval

    public init(pngData: Data, timestamp: TimeInterval) {
        self.pngData = pngData
        self.timestamp = timestamp
    }

    public func decodedImage() -> CGImage? { ImageProcessing.image(fromPNG: pngData) }
}

/// Why a recording stopped. Surfaced in the editor so a truncated clip is never a surprise.
public enum RecordingStopReason: String, Sendable, Equatable {
    case userStopped
    case durationLimit
    case frameCountLimit
    case memoryLimit
    case streamError
    case cancelled
}

/// A finished recording: frames plus everything needed to reason about its timing.
public struct RecordedClip: Sendable {
    public let frames: [RecordedFrame]
    /// Output pixel size of every frame (all frames share it).
    public let pixelSize: CGSize
    public let region: CaptureRegion
    public let nominalFrameInterval: TimeInterval
    public let stopReason: RecordingStopReason
    /// Frames ScreenCaptureKit delivered that TriCap could not keep up with.
    public let droppedFrameCount: Int
    public let colorSpace: ImageProcessing.ColorSpaceOutcome?
    public let retainedBytes: Int

    public init(
        frames: [RecordedFrame],
        pixelSize: CGSize,
        region: CaptureRegion,
        nominalFrameInterval: TimeInterval,
        stopReason: RecordingStopReason,
        droppedFrameCount: Int,
        colorSpace: ImageProcessing.ColorSpaceOutcome?,
        retainedBytes: Int
    ) {
        self.frames = frames
        self.pixelSize = pixelSize
        self.region = region
        self.nominalFrameInterval = nominalFrameInterval
        self.stopReason = stopReason
        self.droppedFrameCount = droppedFrameCount
        self.colorSpace = colorSpace
        self.retainedBytes = retainedBytes
    }

    /// Wall-clock span covered by the retained frames, including the last frame's nominal hold.
    public var duration: TimeInterval {
        guard let first = frames.first, let last = frames.last else { return 0 }
        return (last.timestamp - first.timestamp) + nominalFrameInterval
    }
}
