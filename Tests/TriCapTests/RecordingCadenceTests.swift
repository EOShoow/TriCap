import Testing
@testable import TriCapKit

@Suite("Recording cadence diagnostics")
struct RecordingCadenceTests {

    @Test("Missing SCK delivery intervals are visible even when the app dropped no frames")
    func detectsDeliveryShortfall() {
        let cadence = RecordingCadence(
            frameCount: 216,
            wallDuration: 14.96,
            requestedFramesPerSecond: 20
        )
        #expect(abs(cadence.deliveredFramesPerSecond - 14.37) < 0.02)
        #expect(abs(cadence.deliveryRatio - 0.7186) < 0.001)
        #expect(cadence.estimatedMissingIntervals == 84)
    }

    @Test("A full-rate recording has no estimated missing intervals")
    func fullRate() {
        let cadence = RecordingCadence(
            frameCount: 181,
            wallDuration: 15,
            requestedFramesPerSecond: 12
        )
        #expect(cadence.deliveredFramesPerSecond == 12)
        #expect(cadence.deliveryRatio == 1)
        #expect(cadence.estimatedMissingIntervals == 0)
    }
}
