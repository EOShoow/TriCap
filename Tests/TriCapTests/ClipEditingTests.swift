import CoreGraphics
import Foundation
import Testing
@testable import CaptureCore
@testable import TriCapKit

private func frame(at seconds: TimeInterval, size: Int = 4) -> RecordedFrame {
    RecordedFrame(pngData: Data(repeating: 0xAB, count: size), timestamp: seconds)
}

@Suite("Clip trimming")
struct ClipTrimmerTests {

    let frames = (0..<10).map { frame(at: Double($0) / 12.0) }
    /// A clip that stopped one frame interval after its last frame — the ordinary case.
    var clipDuration: TimeInterval { 10.0 / 12.0 }

    @Test("Trimming keeps the inclusive range and re-bases timestamps to zero")
    func trimsAndRebases() {
        let kept = ClipTrimmer.trim(frames: frames, to: 3...6)
        #expect(kept.count == 4)
        #expect(kept[0].timestamp == 0)
        #expect(abs(kept[1].timestamp - 1.0 / 12.0) < 1e-9)
        #expect(abs(kept[3].timestamp - 3.0 / 12.0) < 1e-9)
    }

    @Test("Trimming to the full range is a no-op apart from re-basing")
    func fullRange() {
        let kept = ClipTrimmer.trim(frames: frames, to: 0...9)
        #expect(kept.count == frames.count)
        #expect(kept[0].timestamp == 0)
    }

    @Test("A single-frame range yields exactly one frame at t=0")
    func singleFrame() {
        let kept = ClipTrimmer.trim(frames: frames, to: 5...5)
        #expect(kept.count == 1)
        #expect(kept[0].timestamp == 0)
    }

    @Test("Out-of-range indices are clamped instead of trapping")
    func clampsOutOfRange() {
        let kept = ClipTrimmer.trim(frames: frames, to: (-5)...50)
        #expect(kept.count == frames.count)
    }

    @Test("Inverted handles are normalised")
    func normalizesInvertedHandles() {
        let range = ClipTrimmer.normalizedRange(first: 8, last: 2, count: 10)
        #expect(range == 2...8)
    }

    @Test("normalizedRange clamps to the frame count")
    func normalizedRangeClamps() {
        #expect(ClipTrimmer.normalizedRange(first: -3, last: 99, count: 10) == 0...9)
        #expect(ClipTrimmer.normalizedRange(first: 0, last: 0, count: 0) == nil)
    }

    @Test("Trimming an empty clip yields an empty clip rather than crashing")
    func emptyInput() {
        #expect(ClipTrimmer.trim(frames: [], to: 0...0).isEmpty)
    }

    @Test("Trimming a clip recomputes its retained byte count")
    func trimClipRecomputesBytes() {
        let clip = TestFixtures.clip(frames: frames, wallClockDuration: clipDuration)
        let trimmed = ClipTrimmer.trim(clip: clip, first: 2, last: 5)
        #expect(trimmed.frames.count == 4)
        #expect(trimmed.retainedBytes == 16)
    }
}

@Suite("Trimmed duration semantics")
struct TrimmedDurationTests {

    /// One second of motion at 12 fps, then a completely static screen until the recording was
    /// stopped at 15 s. ScreenCaptureKit delivers no frames while nothing changes, so the frame
    /// list stops at ~0.92 s while the recording really ran for 15 s.
    let staticTailFrames = (0..<12).map { frame(at: Double($0) / 12.0) }
    let staticTailDuration: TimeInterval = 15.0

    @Test("Keeping the tail keeps the recording's real end time")
    func keepingTailKeepsRealEnd() {
        let duration = ClipTrimmer.trimmedDuration(
            frames: staticTailFrames,
            range: 0...(staticTailFrames.count - 1),
            clipDuration: staticTailDuration
        )
        // The last frame sat on screen for the remaining ~14 seconds; the clip must say 15 s.
        #expect(abs(duration - 15.0) < 1e-9)
    }

    @Test("Trimming the tail off ends at the first dropped frame, not at the recording end")
    func trimmingTailEndsAtNextFrame() {
        // Keep frames 0...4; frame 5 is at 5/12 s, so the clip runs exactly that long.
        let duration = ClipTrimmer.trimmedDuration(
            frames: staticTailFrames,
            range: 0...4,
            clipDuration: staticTailDuration
        )
        #expect(abs(duration - 5.0 / 12.0) < 1e-9)
    }

    @Test("Trimming the head rebases the duration")
    func trimmingHeadRebases() {
        let duration = ClipTrimmer.trimmedDuration(
            frames: staticTailFrames,
            range: 4...(staticTailFrames.count - 1),
            clipDuration: staticTailDuration
        )
        #expect(abs(duration - (15.0 - 4.0 / 12.0)) < 1e-9)
    }

    @Test("A single-frame trim in the middle lasts exactly until the next frame")
    func singleFrameInMiddle() {
        let duration = ClipTrimmer.trimmedDuration(
            frames: staticTailFrames, range: 3...3, clipDuration: staticTailDuration
        )
        #expect(abs(duration - 1.0 / 12.0) < 1e-9)
    }

    @Test("A single-frame trim on the last frame lasts until the recording stopped")
    func singleFrameAtTail() {
        let last = staticTailFrames.count - 1
        let duration = ClipTrimmer.trimmedDuration(
            frames: staticTailFrames, range: last...last, clipDuration: staticTailDuration
        )
        #expect(abs(duration - (15.0 - Double(last) / 12.0)) < 1e-9)
    }

    @Test("A completely static recording is one frame lasting the whole recording")
    func fullyStaticRecording() {
        // The screen never changed, so exactly one frame was ever delivered.
        let frames = [frame(at: 0)]
        let duration = ClipTrimmer.trimmedDuration(frames: frames, range: 0...0, clipDuration: 15.0)
        #expect(duration == 15.0)
    }

    @Test("Trimming a clip carries the recomputed duration into the result")
    func trimClipCarriesDuration() {
        let clip = TestFixtures.clip(frames: staticTailFrames, wallClockDuration: staticTailDuration)
        #expect(abs(clip.duration - 15.0) < 1e-9)

        let keptTail = ClipTrimmer.trim(clip: clip, first: 2, last: staticTailFrames.count - 1)
        #expect(abs(keptTail.duration - (15.0 - 2.0 / 12.0)) < 1e-9)

        let droppedTail = ClipTrimmer.trim(clip: clip, first: 0, last: 4)
        #expect(abs(droppedTail.duration - 5.0 / 12.0) < 1e-9)
    }

    @Test("Duration never goes negative for a degenerate clip duration")
    func neverNegative() {
        let duration = ClipTrimmer.trimmedDuration(
            frames: staticTailFrames, range: 5...(staticTailFrames.count - 1), clipDuration: 0
        )
        #expect(duration == 0)
    }
}

@Suite("Recorded clip duration")
struct RecordedClipDurationTests {

    @Test("The measured wall clock wins over the frame span")
    func wallClockWins() {
        // 1 s of motion, then 14 s of a static screen.
        let frames = (0..<12).map { frame(at: Double($0) / 12.0) }
        let clip = TestFixtures.clip(frames: frames, wallClockDuration: 15.0)
        #expect(abs(clip.duration - 15.0) < 1e-9)
    }

    @Test("The last frame always gets at least one nominal interval")
    func flooredByNominalInterval() {
        // A recording stopped microseconds after the final frame arrived.
        let frames = (0..<3).map { frame(at: Double($0) / 12.0) }
        let clip = TestFixtures.clip(frames: frames, wallClockDuration: 2.0 / 12.0 + 0.0001)
        #expect(abs(clip.duration - 3.0 / 12.0) < 1e-6)
    }

    @Test("An empty clip has no duration")
    func emptyClip() {
        #expect(TestFixtures.clip(frames: [], wallClockDuration: 5).duration == 0)
    }

    @Test("A negative measured duration is clamped away")
    func negativeClamped() {
        let clip = TestFixtures.clip(frames: [frame(at: 0)], wallClockDuration: -3)
        #expect(clip.wallClockDuration == 0)
        #expect(clip.duration > 0)
    }
}

@Suite("Animated WebP timeline")
struct ClipTimingTests {

    @Test("A steady 12 fps clip produces multiples of ~83 ms starting at zero")
    func steadyTimeline() throws {
        let frames = (0..<5).map { frame(at: Double($0) / 12.0) }
        let timeline = try #require(ClipTiming.timeline(for: frames, nominalFrameInterval: 1.0 / 12.0))

        #expect(timeline.timestampsMs == [0, 83, 167, 250, 333])
        #expect(timeline.endTimestampMs == 416)
        #expect(timeline.durationsMs == [83, 84, 83, 83, 83])
    }

    @Test("A measured duration extends the final frame instead of cutting it short")
    func measuredDurationExtendsLastFrame() throws {
        // One second of motion then fourteen static seconds: the last frame must hold.
        let frames = (0..<12).map { frame(at: Double($0) / 12.0) }
        let timeline = try #require(
            ClipTiming.timeline(for: frames, nominalFrameInterval: 1.0 / 12.0, totalDuration: 15.0)
        )
        #expect(timeline.endTimestampMs == 15_000)
        #expect(timeline.durationsMs.last == 15_000 - timeline.timestampsMs.last!)
        #expect(timeline.durationsMs.last! > 13_000)
    }

    @Test("A measured duration shorter than the frames is ignored in favour of the floor")
    func shortMeasuredDurationIsFloored() throws {
        let frames = (0..<4).map { frame(at: Double($0) / 12.0) }
        let timeline = try #require(
            ClipTiming.timeline(for: frames, nominalFrameInterval: 1.0 / 12.0, totalDuration: 0.05)
        )
        #expect(timeline.endTimestampMs == timeline.timestampsMs.last! + 83)
    }

    @Test("A single static frame becomes one long frame")
    func singleStaticFrame() throws {
        let timeline = try #require(
            ClipTiming.timeline(for: [frame(at: 0)], nominalFrameInterval: 1.0 / 12.0, totalDuration: 15.0)
        )
        #expect(timeline.timestampsMs == [0])
        #expect(timeline.endTimestampMs == 15_000)
        #expect(timeline.durationsMs == [15_000])
    }

    @Test("Timestamps are always strictly increasing, even for frames in the same millisecond")
    func forcesStrictlyIncreasing() throws {
        let frames = [frame(at: 0), frame(at: 0.0001), frame(at: 0.0002), frame(at: 0.5)]
        let timeline = try #require(ClipTiming.timeline(for: frames, nominalFrameInterval: 1.0 / 12.0))

        for (a, b) in zip(timeline.timestampsMs, timeline.timestampsMs.dropFirst()) {
            #expect(b > a)
        }
        #expect(timeline.timestampsMs == [0, 10, 20, 500])
        #expect(timeline.endTimestampMs > timeline.timestampsMs.last!)
    }

    @Test("Every frame duration is at least the minimum a browser will honour")
    func minimumDuration() throws {
        let frames = (0..<20).map { frame(at: Double($0) * 0.0005) }
        let timeline = try #require(ClipTiming.timeline(for: frames, nominalFrameInterval: 1.0 / 30.0))
        for duration in timeline.durationsMs {
            #expect(duration >= ClipTiming.minimumFrameDurationMs)
        }
    }

    @Test("A stall in the middle of a recording becomes a long single frame, not a gap")
    func handlesStall() throws {
        let frames = [frame(at: 0), frame(at: 0.083), frame(at: 3.5), frame(at: 3.583)]
        let timeline = try #require(ClipTiming.timeline(for: frames, nominalFrameInterval: 1.0 / 12.0))
        #expect(timeline.durationsMs[1] == 3500 - 83)
    }

    @Test("The end timestamp always exceeds the last frame")
    func endTimestampIsAfterLastFrame() throws {
        let timeline = try #require(ClipTiming.timeline(for: [frame(at: 0)], nominalFrameInterval: 1.0 / 12.0))
        #expect(timeline.timestampsMs == [0])
        #expect(timeline.endTimestampMs == 83)
        #expect(timeline.totalDurationMs == 83)
    }

    @Test("An empty clip has no timeline")
    func emptyClip() {
        #expect(ClipTiming.timeline(for: [], nominalFrameInterval: 1.0 / 12.0) == nil)
    }
}

@Suite("Frame buffer limits")
struct FrameBufferTests {

    @Test("Appending stops at the frame-count ceiling and latches the reason")
    func frameCountCeiling() {
        let buffer = FrameBuffer(maxFrameCount: 3, maxBytes: 10_000_000)
        for i in 0..<3 { #expect(buffer.append(frame(at: Double(i)))) }
        #expect(buffer.append(frame(at: 3)) == false)
        #expect(buffer.latchedLimit == .frameCountLimit)
        #expect(buffer.count == 3)
    }

    @Test("Appending stops at the byte ceiling")
    func byteCeiling() {
        let buffer = FrameBuffer(maxFrameCount: 1000, maxBytes: 10)
        #expect(buffer.append(frame(at: 0, size: 6)))
        #expect(buffer.append(frame(at: 1, size: 6)) == false)
        #expect(buffer.latchedLimit == .memoryLimit)
        #expect(buffer.retainedBytes == 6)
    }

    @Test("Once a limit latches, later appends never grow memory again")
    func latchIsSticky() {
        let buffer = FrameBuffer(maxFrameCount: 1, maxBytes: 10_000)
        #expect(buffer.append(frame(at: 0, size: 100)))
        #expect(buffer.append(frame(at: 1, size: 1)) == false)
        #expect(buffer.append(frame(at: 2, size: 1)) == false)
        #expect(buffer.retainedBytes == 100)
    }

    @Test("Reset clears frames, bytes and the latched limit")
    func reset() {
        let buffer = FrameBuffer(maxFrameCount: 1, maxBytes: 10_000)
        _ = buffer.append(frame(at: 0))
        _ = buffer.append(frame(at: 1))
        buffer.reset()
        #expect(buffer.count == 0)
        #expect(buffer.retainedBytes == 0)
        #expect(buffer.latchedLimit == nil)
    }

    @Test("Concurrent appends never exceed the ceiling")
    func concurrentAppendsRespectCeiling() async {
        let buffer = FrameBuffer(maxFrameCount: 50, maxBytes: 10_000_000)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<200 {
                group.addTask { _ = buffer.append(frame(at: Double(i))) }
            }
        }
        #expect(buffer.count == 50)
    }

    @Test("RecordingLimits derives a frame ceiling from duration and rate")
    func limitsFrameCount() {
        #expect(RecordingLimits(frameRate: 12, maxDuration: 15).maxFrameCount == 181)
        #expect(RecordingLimits(frameRate: 30, maxDuration: 10).maxFrameCount == 301)
    }

    @Test("RecordingLimits clamps out-of-range configuration")
    func limitsClamp() {
        let limits = RecordingLimits(frameRate: 500, maxDuration: 3600, maxLongEdgePixels: 99999)
        #expect(limits.frameRate == 30)
        #expect(limits.maxDuration == 30)
        #expect(limits.maxLongEdgePixels == 3840)
    }
}

enum TestFixtures {
    static let display = DisplayGeometry(
        displayID: 1,
        appKitBounds: CGRect(x: 0, y: 0, width: 1512, height: 982),
        quartzBounds: CGRect(x: 0, y: 0, width: 1512, height: 982),
        pointPixelScale: 2.0,
        primaryHeightInPoints: 982
    )

    static let region = CaptureRegion(
        display: display,
        appKitGlobalRect: CGRect(x: 0, y: 0, width: 100, height: 100),
        displayPixelRect: CGRect(x: 0, y: 0, width: 200, height: 200),
        sourceRectInDisplayPoints: CGRect(x: 0, y: 882, width: 100, height: 100)
    )

    static func clip(
        frames: [RecordedFrame],
        wallClockDuration: TimeInterval,
        colorSpace: ImageProcessing.ColorSpaceOutcome? = nil,
        stopReason: RecordingStopReason = .userStopped
    ) -> RecordedClip {
        RecordedClip(
            frames: frames,
            pixelSize: CGSize(width: 100, height: 100),
            region: region,
            nominalFrameInterval: 1.0 / 12.0,
            stopReason: stopReason,
            droppedFrameCount: 0,
            colorSpace: colorSpace,
            retainedBytes: frames.reduce(0) { $0 + $1.pngData.count },
            wallClockDuration: wallClockDuration
        )
    }

    static func clip(frameCount: Int) -> RecordedClip {
        clip(
            frames: (0..<frameCount).map { frame(at: Double($0) / 12.0) },
            wallClockDuration: Double(frameCount) / 12.0
        )
    }
}
