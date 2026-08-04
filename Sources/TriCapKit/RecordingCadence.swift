import Foundation

/// Observed delivery cadence for a recording request.
///
/// `RecordedClip.droppedFrameCount` covers frames TriCap received but could not retain. It cannot
/// see capture intervals ScreenCaptureKit never delivered, so performance gates must also compare
/// the retained frame intervals with the wall-clock interval budget.
public struct RecordingCadence: Sendable, Equatable {
    public let deliveredFramesPerSecond: Double
    public let deliveryRatio: Double
    public let estimatedMissingIntervals: Int

    public init(frameCount: Int, wallDuration: TimeInterval, requestedFramesPerSecond: Int) {
        let duration = max(0, wallDuration)
        let requested = max(1, requestedFramesPerSecond)
        let deliveredIntervals = Double(max(0, frameCount - 1))
        let expectedIntervals = duration * Double(requested)

        deliveredFramesPerSecond = duration > 0 ? deliveredIntervals / duration : 0
        deliveryRatio = expectedIntervals > 0 ? min(1, deliveredIntervals / expectedIntervals) : 0
        estimatedMissingIntervals = Int(max(0, (expectedIntervals - deliveredIntervals).rounded()))
    }
}
