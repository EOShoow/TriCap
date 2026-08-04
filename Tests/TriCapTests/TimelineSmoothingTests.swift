import CoreGraphics
import Foundation
import Testing
@testable import CaptureCore
@testable import ExportCore
@testable import TriCapKit

/// Causal grid smoothing: frame timestamps snap to the absolute nominal-interval grid when the
/// deviation is small, so ScreenCaptureKit's delivery jitter (66–100 ms between frames at a
/// 12 fps setting, measured on a real recording) stops turning into visible judder.
///
/// The rules these tests pin, in the order the release plan states them:
/// - **causal/online**: each timestamp is decided from already-arrived frames only, and what the
///   live pre-encoder has submitted is never rewritten — guaranteed structurally, because the
///   snap lives inside `IncrementalTimeline.append` and both the live and batch paths run it;
/// - absolute grid at multiples of the nominal interval, snap only within 25% of the interval;
/// - strict monotonicity and the 10 ms minimum step survive;
/// - a real hold (gap ≥ 2× nominal interval) is never shortened — the 3.85 s static tail of the
///   user's recording must come through untouched;
/// - endpoint, total duration and trim semantics unchanged.
@Suite("Timeline grid smoothing")
struct TimelineSmoothingTests {

    private let fps12 = 1.0 / 12.0
    private let fps24 = 1.0 / 24.0

    private func snapped(_ captureTimestamps: [TimeInterval], interval: TimeInterval) -> [Int] {
        IncrementalTimeline.timestamps(
            forCaptureTimestamps: captureTimestamps, nominalFrameInterval: interval
        )
    }

    // MARK: - The regression: measured jitter becomes a uniform grid

    @Test("The 66/100 ms jitter measured on the real recording becomes a uniform 12 fps grid")
    func realWorldJitterAt12fps() {
        // Gaps of 66/100/66/100 ms — the pattern read out of the user's file. The old rule kept
        // the raw values (66, 166, 232, 332); the grid pulls every one onto 83.33k.
        let out = snapped([0, 0.066, 0.166, 0.232, 0.332], interval: fps12)
        #expect(out == [0, 83, 167, 250, 333])
        let durations = zip(out.dropFirst(), out).map(-)
        #expect(durations.allSatisfy { abs($0 - 83) <= 1 }, "uniform to within rounding: \(durations)")
    }

    @Test("33/50 ms alternation at 24 fps lands on the 41.67 ms grid")
    func alternationAt24fps() {
        // Deliveries at 33, 83, 116, 166 ms: alternating short/long gaps around the nominal 41.67.
        let out = snapped([0, 0.033, 0.083, 0.116, 0.166], interval: fps24)
        #expect(out == [0, 42, 83, 125, 167])
    }

    @Test("A deviation beyond 25% of the interval is left alone")
    func beyondToleranceIsKeptRaw() {
        // 55 ms after the previous frame at 12 fps: 28 ms from the nearest tick (83), which is
        // more than the 20.8 ms tolerance. Snapping it would be invention, not smoothing.
        let out = snapped([0, 0.055], interval: fps12)
        #expect(out == [0, 55])
    }

    // MARK: - Holds

    @Test("A real hold is never shortened — the 3.85 s static tail survives exactly")
    func holdPreserved() {
        // Frame at 83 ms, then nothing for 3.85 s (static screen), then motion resumes.
        let out = snapped([0, 0.083, 3.933, 4.016], interval: fps12)
        #expect(out[1] == 83)
        #expect(out[2] == 3933, "the hold-ending frame keeps its raw time; the hold is not shortened")
        #expect(out[2] - out[1] == 3850)
        // The frame after the hold returns to the absolute grid (one transitional duration).
        #expect(out[3] == 4000)
    }

    @Test("A gap of exactly 2× the interval counts as a hold")
    func holdBoundary() {
        let out = snapped([0, 2.0 / 12.0], interval: fps12)   // 166.67 ms gap
        #expect(out == [0, 167], "kept raw (rounded), not pulled to a different tick")
    }

    @Test("A hold keeps its real duration after the preceding frame snapped forward")
    func holdAfterForwardSnapPreservesDuration() {
        // 66 ms snaps forward to 83 ms. The following raw gap is 174 ms, which is a real hold.
        // Measuring it from the emitted 83 ms value misclassifies it as 157 ms and shortens it.
        let out = snapped([0, 0.066, 0.240], interval: fps12)
        #expect(out == [0, 83, 257])
        #expect(out[2] - out[1] == 174, "the raw 174 ms hold duration must survive exactly")
    }

    // MARK: - Monotonicity and collisions

    @Test("Two frames snapping to the same tick stay strictly monotonic")
    func gridCollision() {
        // 75 ms and 90 ms are both within tolerance of tick 83.
        let out = snapped([0, 0.075, 0.090], interval: fps12)
        #expect(out[1] == 83)
        #expect(out[2] == 93, "collision resolves to prev + minimum step")
        #expect(zip(out, out.dropFirst()).allSatisfy { $1 > $0 })
    }

    @Test("Identical capture timestamps still advance by the minimum step")
    func identicalTimestamps() {
        let out = snapped([0, 0, 0, 0], interval: fps12)
        #expect(out == [0, 10, 20, 30])
    }

    @Test("Without a nominal interval the legacy behaviour is bit-identical")
    func legacyPathUnchanged() {
        let jitter: [TimeInterval] = [0, 0.066, 0.166, 0.232, 0.332]
        let legacy = IncrementalTimeline.timestamps(forCaptureTimestamps: jitter)
        #expect(legacy == [0, 66, 166, 232, 332])
    }

    // MARK: - Endpoint, total duration, trim

    @Test("The clip endpoint still comes from the measured wall clock")
    func endpointUnchanged() throws {
        let frames = [0.0, 0.066, 0.166].map { RecordedFrame(pngData: Data([0]), timestamp: $0) }
        let timeline = try #require(ClipTiming.timeline(
            for: frames, nominalFrameInterval: fps12, totalDuration: 5.0
        ))
        #expect(timeline.endTimestampMs == 5000, "the measured recording length wins, exactly as before")
        #expect(timeline.timestampsMs == [0, 83, 167], "…while the frames themselves are smoothed")
    }

    @Test("A smoothed last frame cannot drag the endpoint below last + one interval")
    func endpointFloorSurvives() throws {
        let frames = [0.0, 0.066].map { RecordedFrame(pngData: Data([0]), timestamp: $0) }
        let timeline = try #require(ClipTiming.timeline(
            for: frames, nominalFrameInterval: fps12, totalDuration: nil
        ))
        #expect(timeline.timestampsMs == [0, 83])
        #expect(timeline.endTimestampMs == 83 + 83, "last frame + nominal interval, same floor as before")
    }

    @Test("Trim re-anchors the grid at the first kept frame")
    func trimReanchors() throws {
        // The same jittered clip, trimmed to drop the first frame: the new base is frame 1, and
        // the grid starts from zero there — trim semantics unchanged, still smoothed.
        let all: [TimeInterval] = [0, 0.066, 0.166, 0.232, 0.332]
        let trimmed = Array(all.dropFirst()).map { RecordedFrame(pngData: Data([0]), timestamp: $0) }
        let timeline = try #require(ClipTiming.timeline(for: trimmed, nominalFrameInterval: fps12))
        #expect(timeline.timestampsMs.first == 0)
        #expect(timeline.timestampsMs == [0, 83, 167, 250])
        #expect(zip(timeline.timestampsMs, timeline.timestampsMs.dropFirst()).allSatisfy { $1 > $0 })
    }

    // MARK: - Live/batch equivalence with smoothing on

    @Test("Live and batch produce identical smoothed timelines", arguments: [
        [0.0, 0.066, 0.166, 0.232, 0.332],       // measured jitter
        [0.0, 0.033, 0.083, 0.116, 0.166],       // fast alternation
        [0.0, 0.083, 3.933, 4.016],              // static hold
        [0.0],                                   // single frame
        [0.0, 0.0, 0.0],                         // collisions
        [0.0, 0.055, 0.5, 0.583],                // out-of-tolerance then hold then resume
    ])
    func liveBatchEquivalence(captureTimestamps: [TimeInterval]) {
        // The reuse policy compares these arrays literally; one millisecond of divergence and the
        // pre-encoded artifact is silently rejected on every export.
        let frames = captureTimestamps.map { RecordedFrame(pngData: Data([0]), timestamp: $0) }
        let batch = ClipTiming.timeline(for: frames, nominalFrameInterval: fps12)

        var live = IncrementalTimeline(nominalFrameInterval: fps12)
        let liveOut = captureTimestamps.map { live.append(captureTimestamp: $0) }

        #expect(batch?.timestampsMs == liveOut)
    }

    @Test("The pre-encoder's artifact timestamps equal the export timeline under jitter")
    func preEncoderMatchesExportUnderJitter() throws {
        let captureTimestamps: [TimeInterval] = [0, 0.066, 0.166, 0.232, 0.332]
        let canvas = CGSize(width: 48, height: 32)
        let encoder = LivePreEncoder(canvasSize: canvas, options: AnimatedWebPOptions(), frameRate: 12)
        for (index, timestamp) in captureTimestamps.enumerated() {
            encoder.submit(
                image: smoothingTestImage(width: 48, height: 32, level: Double(index) / 5),
                captureTimestamp: timestamp
            )
        }
        let frames = captureTimestamps.map { RecordedFrame(pngData: Data([0]), timestamp: $0) }
        let batch = try #require(ClipTiming.timeline(for: frames, nominalFrameInterval: 1.0 / 12.0))
        let artifact = try #require(encoder.finish(endTimestampMs: batch.endTimestampMs))
        #expect(artifact.timestampsMs == batch.timestampsMs)
        #expect(artifact.timestampsMs == [0, 83, 167, 250, 333], "and they are the smoothed grid")
    }
}

private func smoothingTestImage(width: Int, height: Int, level: Double) -> CGImage {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )!
    context.setFillColor(CGColor(srgbRed: level, green: 0.4, blue: 1 - level, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}
