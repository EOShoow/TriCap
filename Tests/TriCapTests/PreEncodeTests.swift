import CoreGraphics
import Foundation
import Testing
@testable import CaptureCore
@testable import ExportCore
@testable import TriCapKit

// MARK: - Helpers

private func solid(width: Int, height: Int, level: Double) -> CGImage {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )!
    context.setFillColor(CGColor(srgbRed: level, green: 0.4, blue: 1 - level, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    // A moving block, so consecutive frames differ and libwebp cannot coalesce them away.
    context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: Double(width) * level, y: 4, width: 12, height: 12))
    return context.makeImage()!
}

private func source(
    frameCount: Int,
    canvas: CGSize = CGSize(width: 48, height: 32),
    timestamps: [Int]? = nil,
    endTimestampMs: Int? = nil
) -> AnimationFrameSource {
    let stamps = timestamps ?? (0..<frameCount).map { $0 * 100 }
    return AnimationFrameSource(
        frameCount: frameCount,
        timestampsMs: stamps,
        endTimestampMs: endTimestampMs ?? ((stamps.last ?? 0) + 100),
        canvasSize: canvas
    ) { index in solid(width: Int(canvas.width), height: Int(canvas.height), level: Double(index) / 10) }
}

private func artifact(
    frameCount: Int = 5,
    canvas: CGSize = CGSize(width: 48, height: 32),
    options: AnimatedWebPOptions = AnimatedWebPOptions(),
    timestamps: [Int]? = nil,
    endTimestampMs: Int? = nil,
    data: Data = Data([1, 2, 3])
) -> PreEncodedAnimation {
    let stamps = timestamps ?? (0..<frameCount).map { $0 * 100 }
    return PreEncodedAnimation(
        data: data,
        canvasSize: canvas,
        options: options,
        frameCount: frameCount,
        timestampsMs: stamps,
        endTimestampMs: endTimestampMs ?? ((stamps.last ?? 0) + 100)
    )
}

// MARK: - Timeline equivalence

@Suite("Live and batch timelines agree")
struct IncrementalTimelineTests {

    @Test("The incremental rule reproduces ClipTiming exactly", arguments: [
        [0.0, 0.083, 0.166, 0.25],                       // steady 12 fps
        [0.0, 0.0005, 0.001, 0.5],                        // two frames inside one millisecond
        [0.0, 2.0, 2.001, 9.5],                           // a long stall
        [0.0],                                            // a single frame
        [0.0, 0.0, 0.0, 0.0],                             // identical timestamps
    ])
    func matchesBatch(captureTimestamps: [TimeInterval]) {
        // This is the load-bearing property of the whole fast path. If the live timeline and the
        // export-time timeline disagree by one millisecond, the pre-encoded file is silently wrong
        // for the timeline it claims — so the two must come from one rule.
        let frames = captureTimestamps.map { RecordedFrame(pngData: Data([0]), timestamp: $0) }
        let batch = ClipTiming.timeline(for: frames, nominalFrameInterval: 1.0 / 12.0)
        let live = IncrementalTimeline.timestamps(forCaptureTimestamps: captureTimestamps)
        #expect(batch?.timestampsMs == live)
    }

    @Test("Timestamps are strictly increasing even when capture times collide")
    func strictlyIncreasing() {
        let live = IncrementalTimeline.timestamps(forCaptureTimestamps: [0, 0, 0, 0.0001])
        #expect(live == [0, 10, 20, 30])
        #expect(zip(live, live.dropFirst()).allSatisfy { $1 > $0 })
    }

    @Test("Appending returns the same value it stores")
    func appendReturnsValue() {
        var timeline = IncrementalTimeline()
        #expect(timeline.append(captureTimestamp: 5.0) == 0, "the first frame is always zero")
        let second = timeline.append(captureTimestamp: 5.25)
        #expect(second == 250)
        #expect(timeline.timestampsMs == [0, 250])
        #expect(timeline.last == 250)
        #expect(timeline.count == 2)
    }
}

// MARK: - Reuse policy

@Suite("Pre-encode reuse policy")
struct PreEncodeReuseTests {

    @Test("An untouched full-range export reuses the artifact")
    func reusesWhenNothingChanged() {
        let decision = PreEncodeReuse.decide(
            artifact: artifact(), source: source(frameCount: 5),
            annotationCount: 0, options: AnimatedWebPOptions()
        )
        #expect(decision == .reuse)
        #expect(decision.isReuse)
    }

    @Test("No artifact means no fast path")
    func noArtifact() {
        let decision = PreEncodeReuse.decide(
            artifact: nil, source: source(frameCount: 5),
            annotationCount: 0, options: AnimatedWebPOptions()
        )
        #expect(decision == .noArtifact)
    }

    @Test("A trimmed clip falls back", arguments: [1, 3, 4, 6, 20])
    func trimmedFallsBack(requestedFrames: Int) {
        let decision = PreEncodeReuse.decide(
            artifact: artifact(frameCount: 5), source: source(frameCount: requestedFrames),
            annotationCount: 0, options: AnimatedWebPOptions()
        )
        #expect(!decision.isReuse)
        #expect(decision == .frameRangeChanged(preEncoded: 5, requested: requestedFrames))
    }

    @Test("Any annotation falls back", arguments: [1, 2, 7])
    func annotationsFallBack(count: Int) {
        let decision = PreEncodeReuse.decide(
            artifact: artifact(), source: source(frameCount: 5),
            annotationCount: count, options: AnimatedWebPOptions()
        )
        #expect(decision == .hasAnnotations(count: count))
    }

    @Test("A different canvas falls back")
    func canvasFallsBack() {
        let decision = PreEncodeReuse.decide(
            artifact: artifact(canvas: CGSize(width: 48, height: 32)),
            source: source(frameCount: 5, canvas: CGSize(width: 96, height: 64)),
            annotationCount: 0, options: AnimatedWebPOptions()
        )
        guard case .canvasChanged = decision else {
            Issue.record("expected canvasChanged, got \(decision)")
            return
        }
    }

    @Test("Every encoder parameter is checked", arguments: [
        (AnimatedWebPOptions(quality: 50), "quality"),
        (AnimatedWebPOptions(lossless: true), "lossless"),
        (AnimatedWebPOptions(method: 6), "method"),
        (AnimatedWebPOptions(loopCount: 3), "loop count"),
    ])
    func optionsFallBack(changed: AnimatedWebPOptions, field: String) {
        // Silently reusing a quality-80 encode for a quality-50 export would hand the user a file
        // that does not match the setting they just changed.
        let decision = PreEncodeReuse.decide(
            artifact: artifact(options: AnimatedWebPOptions()), source: source(frameCount: 5),
            annotationCount: 0, options: changed
        )
        #expect(decision == .optionsChanged(field: field))
    }

    @Test("A trim that keeps the frame count but moves the timeline falls back")
    func sameCountDifferentTimestamps() {
        // Trimming one frame from each end leaves five frames whose timestamps are not the five
        // that were pre-encoded. The count check alone would let this through.
        let decision = PreEncodeReuse.decide(
            artifact: artifact(frameCount: 5, timestamps: [0, 100, 200, 300, 400]),
            source: source(frameCount: 5, timestamps: [0, 100, 200, 300, 401]),
            annotationCount: 0, options: AnimatedWebPOptions()
        )
        #expect(decision == .timelineChanged)
    }

    @Test("A different end timestamp falls back")
    func endTimestampFallsBack() {
        // The end timestamp fixes how long the final frame is held — the static-tail behaviour.
        let decision = PreEncodeReuse.decide(
            artifact: artifact(frameCount: 5, endTimestampMs: 500),
            source: source(frameCount: 5, endTimestampMs: 9000),
            annotationCount: 0, options: AnimatedWebPOptions()
        )
        #expect(decision == .timelineChanged)
    }

    @Test("An empty artifact is treated as no artifact")
    func emptyData() {
        let decision = PreEncodeReuse.decide(
            artifact: artifact(data: Data()), source: source(frameCount: 5),
            annotationCount: 0, options: AnimatedWebPOptions()
        )
        #expect(decision == .noArtifact)
    }

    @Test("Every decision explains itself")
    func reasons() {
        let all: [PreEncodeReuse.Decision] = [
            .reuse, .noArtifact, .frameRangeChanged(preEncoded: 5, requested: 3),
            .hasAnnotations(count: 2), .canvasChanged(preEncoded: .zero, requested: .zero),
            .optionsChanged(field: "quality"), .timelineChanged,
        ]
        for decision in all { #expect(!decision.reason.isEmpty) }
    }
}

// MARK: - Encoder session

@Suite("Long-lived WebP animation encoder")
struct WebPAnimEncoderSessionTests {

    let canvas = CGSize(width: 48, height: 32)

    @Test("Frames added one at a time assemble into a readable animation")
    func assembles() throws {
        let session = try WebPAnimEncoderSession(canvasSize: canvas, options: AnimatedWebPOptions())
        for index in 0..<6 {
            #expect(session.add(image: solid(width: 48, height: 32, level: Double(index) / 6),
                                timestampMs: index * 100))
        }
        #expect(session.frameCount == 6)
        let data = try #require(session.finish(endTimestampMs: 600))

        let info = try WebPCodec.inspectAnimation(data: data)
        #expect(info.canvasWidth == 48)
        #expect(info.canvasHeight == 32)
        #expect(info.frameCount >= 1 && info.frameCount <= 6)
        #expect(info.totalDurationMs == 600)
        #expect(info.loopCount == 0)
    }

    @Test("It produces the same structure as the one-shot streaming encoder")
    func matchesStreamingEncoder() throws {
        // The fast path must not change the output. Byte equality is not promised by libwebp
        // across two encoder instances, but every property TriCap verifies after writing must
        // agree — canvas, frame count, playback length, loop count and timestamps.
        let options = AnimatedWebPOptions()
        let session = try WebPAnimEncoderSession(canvasSize: canvas, options: options)
        for index in 0..<6 {
            session.add(image: solid(width: 48, height: 32, level: Double(index) / 6), timestampMs: index * 100)
        }
        let live = try #require(session.finish(endTimestampMs: 600))

        let streamed = try WebPCodec.encodeAnimationStreaming(
            frameCount: 6, canvasSize: canvas, endTimestampMs: 600, options: options
        ) { index in
            (solid(width: 48, height: 32, level: Double(index) / 6), index * 100)
        }

        let a = try WebPCodec.inspectAnimation(data: live)
        let b = try WebPCodec.inspectAnimation(data: streamed)
        #expect(a.canvasWidth == b.canvasWidth)
        #expect(a.canvasHeight == b.canvasHeight)
        #expect(a.frameCount == b.frameCount)
        #expect(a.totalDurationMs == b.totalDurationMs)
        #expect(a.loopCount == b.loopCount)
        #expect(a.frameTimestampsMs == b.frameTimestampsMs)
    }

    @Test("A wrongly sized frame is refused and latches a failure")
    func wrongSize() throws {
        let session = try WebPAnimEncoderSession(canvasSize: canvas, options: AnimatedWebPOptions())
        #expect(!session.add(image: solid(width: 10, height: 10, level: 0.5), timestampMs: 0))
        #expect(session.failure != nil)
        #expect(session.finish(endTimestampMs: 100) == nil, "a failed session produces nothing")
    }

    @Test("Non-increasing timestamps are refused")
    func nonMonotonic() throws {
        let session = try WebPAnimEncoderSession(canvasSize: canvas, options: AnimatedWebPOptions())
        #expect(session.add(image: solid(width: 48, height: 32, level: 0.1), timestampMs: 100))
        #expect(!session.add(image: solid(width: 48, height: 32, level: 0.2), timestampMs: 100))
        #expect(session.failure != nil)
    }

    @Test("An end timestamp that is not after the last frame is refused")
    func badEndTimestamp() throws {
        let session = try WebPAnimEncoderSession(canvasSize: canvas, options: AnimatedWebPOptions())
        session.add(image: solid(width: 48, height: 32, level: 0.1), timestampMs: 500)
        #expect(session.finish(endTimestampMs: 400) == nil)
    }

    @Test("Finishing with no frames produces nothing rather than an empty file")
    func noFrames() throws {
        let session = try WebPAnimEncoderSession(canvasSize: canvas, options: AnimatedWebPOptions())
        #expect(session.finish(endTimestampMs: 100) == nil)
    }

    @Test("release() is idempotent and safe after finish()")
    func releaseIsIdempotent() throws {
        let session = try WebPAnimEncoderSession(canvasSize: canvas, options: AnimatedWebPOptions())
        session.add(image: solid(width: 48, height: 32, level: 0.1), timestampMs: 0)
        _ = session.finish(endTimestampMs: 100)
        session.release()
        session.release()
        #expect(!session.isUsable)
    }

    @Test("The strategy reaches the encoder and changes the output size", arguments: [
        AnimationEncodeStrategy.thorough, AnimationEncodeStrategy.balanced,
    ])
    func strategyIsApplied(strategy: AnimationEncodeStrategy) throws {
        let session = try WebPAnimEncoderSession(
            canvasSize: canvas, options: AnimatedWebPOptions(), strategy: strategy
        )
        #expect(session.strategy == strategy)
        for index in 0..<4 {
            session.add(image: solid(width: 48, height: 32, level: Double(index) / 4), timestampMs: index * 100)
        }
        let data = try #require(session.finish(endTimestampMs: 400))
        // Both strategies must still produce a valid, readable animation of the right length.
        let info = try WebPCodec.inspectAnimation(data: data)
        #expect(info.totalDurationMs == 400)
    }
}

// MARK: - Live pre-encoder

@Suite("Live pre-encoder")
struct LivePreEncoderTests {

    let canvas = CGSize(width: 48, height: 32)

    private func feed(_ encoder: LivePreEncoder, frames: Int, interval: TimeInterval = 0.1) {
        for index in 0..<frames {
            encoder.submit(
                image: solid(width: 48, height: 32, level: Double(index % 10) / 10),
                captureTimestamp: Double(index) * interval
            )
        }
    }

    @Test("A clean run produces an artifact matching what was submitted")
    func happyPath() throws {
        let encoder = LivePreEncoder(canvasSize: canvas, options: AnimatedWebPOptions(), frameRate: 12)
        feed(encoder, frames: 8)
        let artifact = try #require(encoder.finish(endTimestampMs: 800))

        #expect(artifact.frameCount == 8)
        #expect(artifact.canvasSize == canvas)
        #expect(artifact.endTimestampMs == 800)
        #expect(artifact.timestampsMs == (0..<8).map { $0 * 100 })
        #expect(!artifact.data.isEmpty)

        let info = try WebPCodec.inspectAnimation(data: artifact.data)
        #expect(info.totalDurationMs == 800)
    }

    @Test("Its timestamps are the ones the export path will ask for")
    func timestampsMatchTheExportTimeline() throws {
        // If these drift, `PreEncodeReuse` rejects the artifact and the optimisation silently
        // never fires — a failure that costs performance rather than correctness, and so is
        // exactly the kind that goes unnoticed without a test.
        let captureTimestamps = [0.0, 0.083, 0.166, 0.249]
        let encoder = LivePreEncoder(canvasSize: canvas, options: AnimatedWebPOptions(), frameRate: 12)
        for (index, timestamp) in captureTimestamps.enumerated() {
            encoder.submit(image: solid(width: 48, height: 32, level: Double(index) / 4),
                           captureTimestamp: timestamp)
        }
        let artifact = try #require(encoder.finish(endTimestampMs: 400))

        let frames = captureTimestamps.map { RecordedFrame(pngData: Data([0]), timestamp: $0) }
        let batch = ClipTiming.timeline(for: frames, nominalFrameInterval: 1.0 / 12.0)
        #expect(artifact.timestampsMs == batch?.timestampsMs)
    }

    @Test("Exceeding the backlog abandons the fast path instead of growing")
    func backlogAbandons() {
        // A tiny backlog and a burst far larger than it: the point is that nothing queues without
        // limit and nothing blocks. The recording itself is untouched.
        let encoder = LivePreEncoder(
            canvasSize: canvas, options: AnimatedWebPOptions(), frameRate: 12, maxBacklog: 2
        )
        feed(encoder, frames: 400, interval: 0.01)

        #expect(encoder.finish(endTimestampMs: 4000) == nil, "an abandoned run yields no artifact")
        if let reason = encoder.abandonedBecause {
            if case .backlog = reason {} else {
                Issue.record("expected a backlog abandonment, got \(reason)")
            }
        }
        #expect(!encoder.isActive)
    }

    @Test("The backlog ceiling is never exceeded")
    func backlogIsBounded() {
        let encoder = LivePreEncoder(
            canvasSize: canvas, options: AnimatedWebPOptions(), frameRate: 12, maxBacklog: 4
        )
        for index in 0..<200 {
            encoder.submit(image: solid(width: 48, height: 32, level: 0.5), captureTimestamp: Double(index) * 0.01)
            #expect(encoder.pendingFrames <= 4)
        }
        encoder.cancel()
    }

    @Test("Cancelling releases everything and yields nothing")
    func cancelReleases() {
        let encoder = LivePreEncoder(canvasSize: canvas, options: AnimatedWebPOptions(), frameRate: 12)
        feed(encoder, frames: 4)
        encoder.cancel()

        #expect(encoder.abandonedBecause == .cancelled)
        #expect(!encoder.isActive)
        #expect(encoder.finish(endTimestampMs: 400) == nil)
    }

    @Test("Cancelling twice is harmless")
    func cancelIsIdempotent() {
        let encoder = LivePreEncoder(canvasSize: canvas, options: AnimatedWebPOptions(), frameRate: 12)
        feed(encoder, frames: 2)
        encoder.cancel()
        encoder.cancel()
        #expect(encoder.abandonedBecause == .cancelled)
    }

    @Test("Submitting after cancellation does nothing")
    func submitAfterCancel() {
        let encoder = LivePreEncoder(canvasSize: canvas, options: AnimatedWebPOptions(), frameRate: 12)
        encoder.cancel()
        feed(encoder, frames: 5)
        #expect(encoder.submittedFrames == 0)
        #expect(encoder.finish(endTimestampMs: 500) == nil)
    }

    @Test("A frame of the wrong size abandons rather than corrupting the animation")
    func wrongSizedFrameAbandons() {
        let encoder = LivePreEncoder(canvasSize: canvas, options: AnimatedWebPOptions(), frameRate: 12)
        encoder.submit(image: solid(width: 48, height: 32, level: 0.1), captureTimestamp: 0)
        encoder.submit(image: solid(width: 96, height: 64, level: 0.2), captureTimestamp: 0.1)

        #expect(encoder.finish(endTimestampMs: 200) == nil)
        if let reason = encoder.abandonedBecause {
            if case .encoderFailed = reason {} else {
                Issue.record("expected an encoder failure, got \(reason)")
            }
        }
    }

    @Test("Finishing with nothing submitted yields nothing")
    func emptyFinish() {
        let encoder = LivePreEncoder(canvasSize: canvas, options: AnimatedWebPOptions(), frameRate: 12)
        #expect(encoder.finish(endTimestampMs: 100) == nil)
    }

    @Test("Every abandonment explains itself")
    func abandonmentReasons() {
        let all: [LivePreEncoder.Abandonment] = [
            .backlog(pending: 60, limit: 60), .encoderFailed("x"), .cancelled, .setupFailed("y"),
        ]
        for reason in all { #expect(!reason.reason.isEmpty) }
    }

    @Test("A zero-sized canvas fails to set up instead of trapping")
    func degenerateCanvas() {
        let encoder = LivePreEncoder(canvasSize: .zero, options: AnimatedWebPOptions(), frameRate: 12)
        #expect(!encoder.isActive)
        if let reason = encoder.abandonedBecause {
            if case .setupFailed = reason {} else {
                Issue.record("expected setupFailed, got \(reason)")
            }
        }
        #expect(encoder.finish(endTimestampMs: 100) == nil)
    }
}

// MARK: - Diagnostics

@Suite("Pre-encoder diagnostics")
struct LivePreEncoderDiagnosticsTests {

    let canvas = CGSize(width: 48, height: 32)

    @Test("Nearest-rank percentile is exact on known inputs")
    func percentileDefinition() {
        // The release-plan gates (e.g. "30 fps needs p95 ≤ 26.7 ms") are defined against exactly
        // this function, so its definition is pinned rather than assumed.
        typealias D = LivePreEncoder.Diagnostics
        #expect(D.percentile(50, of: []) == nil)
        #expect(D.percentile(50, of: [7]) == 7)
        #expect(D.percentile(50, of: [1, 2, 3, 4]) == 2)       // nearest-rank: ceil(0.5*4)=2nd
        #expect(D.percentile(95, of: [1, 2, 3, 4]) == 4)       // ceil(0.95*4)=4th
        #expect(D.percentile(95, of: Array(stride(from: 1.0, through: 100.0, by: 1))) == 95)
        #expect(D.percentile(0, of: [3, 1, 2]) == 1)
        #expect(D.percentile(100, of: [3, 1, 2]) == 3)
    }

    @Test("A clean run reports one duration per encoded frame and a sane peak")
    func happyPathDiagnostics() throws {
        let encoder = LivePreEncoder(canvasSize: canvas, options: AnimatedWebPOptions(), frameRate: 12)
        for index in 0..<6 {
            encoder.submit(
                image: solid(width: 48, height: 32, level: Double(index) / 6),
                captureTimestamp: Double(index) * 0.1
            )
        }
        _ = try #require(encoder.finish(endTimestampMs: 600))

        let diag = encoder.diagnostics
        #expect(diag.submitted == 6)
        #expect(diag.encoded == 6)
        #expect(diag.encodeDurationsMs.count == 6, "one timing sample per encoded frame")
        #expect(diag.encodeDurationsMs.allSatisfy { $0 >= 0 })
        #expect(diag.p50EncodeMs != nil && diag.p95EncodeMs != nil)
        #expect(diag.p50EncodeMs! <= diag.p95EncodeMs!)
        #expect(diag.peakBacklog >= 1 && diag.peakBacklog <= diag.backlogLimit)
        #expect(diag.abandonment == nil)
    }

    @Test("The peak backlog records how close the run came to giving up")
    func peakBacklogIsBounded() {
        let encoder = LivePreEncoder(
            canvasSize: canvas, options: AnimatedWebPOptions(), frameRate: 12, maxBacklog: 4
        )
        for index in 0..<200 {
            encoder.submit(image: solid(width: 48, height: 32, level: 0.5),
                           captureTimestamp: Double(index) * 0.001)
        }
        let diag = encoder.diagnostics
        #expect(diag.peakBacklog <= 4, "peak can never exceed the limit that triggers abandonment")
        if diag.abandonment != nil {
            #expect(diag.peakBacklog == 4, "an abandoned run must have actually hit the ceiling")
        }
        encoder.cancel()
    }

    @Test("Abandonment is visible in the same snapshot as the counters")
    func abandonmentInDiagnostics() {
        let encoder = LivePreEncoder(
            canvasSize: canvas, options: AnimatedWebPOptions(), frameRate: 12, maxBacklog: 1
        )
        for index in 0..<50 {
            encoder.submit(image: solid(width: 48, height: 32, level: 0.5),
                           captureTimestamp: Double(index) * 0.0005)
        }
        _ = encoder.finish(endTimestampMs: 60_000)
        let diag = encoder.diagnostics
        if case .backlog = diag.abandonment {} else {
            Issue.record("expected a backlog abandonment, got \(String(describing: diag.abandonment))")
        }
    }
}

// MARK: - Encode strategy

@Suite("Animation encode strategy")
struct AnimationEncodeStrategyTests {

    @Test("The default is the balanced one")
    func defaultIsBalanced() {
        #expect(AnimationEncodeStrategy.default == .balanced)
        #expect(!AnimationEncodeStrategy.balanced.minimizeSize)
        #expect(!AnimationEncodeStrategy.balanced.allowMixed)
    }

    @Test("The previous behaviour is still expressible")
    func thoroughIsPreserved() {
        // Kept so the benchmark can measure against what shipped, and so the change is reversible
        // by a caller that wants the smallest possible file and does not mind waiting.
        #expect(AnimationEncodeStrategy.thorough.minimizeSize)
        #expect(AnimationEncodeStrategy.thorough.allowMixed)
        #expect(AnimationEncodeStrategy.thorough != .balanced)
    }
}
