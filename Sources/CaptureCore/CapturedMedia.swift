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

    /// Monotonic wall-clock span from the first retained frame to the moment capture stopped.
    ///
    /// This is the load-bearing number for a screen that stops changing. ScreenCaptureKit sends
    /// no new *complete* frame while the picture is static, so anything derived from frame
    /// timestamps would report a recording of "one second" when the user actually recorded one
    /// second of motion followed by fourteen seconds of a still screen. Measuring the elapsed
    /// time independently is what lets the exported animation hold that last frame for its real
    /// duration.
    public let wallClockDuration: TimeInterval

    public init(
        frames: [RecordedFrame],
        pixelSize: CGSize,
        region: CaptureRegion,
        nominalFrameInterval: TimeInterval,
        stopReason: RecordingStopReason,
        droppedFrameCount: Int,
        colorSpace: ImageProcessing.ColorSpaceOutcome?,
        retainedBytes: Int,
        wallClockDuration: TimeInterval
    ) {
        self.frames = frames
        self.pixelSize = pixelSize
        self.region = region
        self.nominalFrameInterval = nominalFrameInterval
        self.stopReason = stopReason
        self.droppedFrameCount = droppedFrameCount
        self.colorSpace = colorSpace
        self.retainedBytes = retainedBytes
        self.wallClockDuration = max(0, wallClockDuration)
    }

    /// The notice the editor shows when the capture's colour space could not be represented
    /// losslessly in sRGB.
    ///
    /// Lives here rather than in the editor so that "a wide-gamut recording tells the user" is a
    /// property of the recorded clip and can be tested without a window.
    public var colorSpaceNotice: String? { colorSpace?.userFacingNotice }

    /// Playback length of the clip.
    ///
    /// The measured wall clock wins, floored so that the final frame always gets at least one
    /// nominal frame interval on screen (a recording stopped microseconds after a frame arrived
    /// must not end on a one-millisecond flash).
    public var duration: TimeInterval {
        guard let first = frames.first, let last = frames.last else { return 0 }
        let lastFrameOffset = last.timestamp - first.timestamp
        return max(wallClockDuration, lastFrameOffset + nominalFrameInterval)
    }
}
