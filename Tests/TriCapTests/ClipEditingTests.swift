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
        let clip = RecordedClip(
            frames: frames,
            pixelSize: CGSize(width: 100, height: 100),
            region: TestFixtures.region,
            nominalFrameInterval: 1.0 / 12.0,
            stopReason: .userStopped,
            droppedFrameCount: 0,
            colorSpace: nil,
            retainedBytes: 40
        )
        let trimmed = ClipTrimmer.trim(clip: clip, first: 2, last: 5)
        #expect(trimmed.frames.count == 4)
        #expect(trimmed.retainedBytes == 16)
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

    @Test("Timestamps are always strictly increasing, even for frames in the same millisecond")
    func forcesStrictlyIncreasing() throws {
        // Three frames delivered within the same millisecond, then a normal one.
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
}
