import CoreGraphics
import Foundation
import Testing
@testable import AnnotationCore
@testable import CaptureCore
@testable import ExportCore
@testable import TriCapKit

enum WebPTestImages {
    /// A solid-colour image of the requested size.
    static func solid(width: Int, height: Int, red: Double, green: Double, blue: Double) -> CGImage {
        let ctx = ImageProcessing.makeContext(width: width, height: height)!
        ctx.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    /// A frame with a moving block, so successive frames genuinely differ.
    static func movingBlock(width: Int, height: Int, step: Int, steps: Int) -> CGImage {
        let ctx = ImageProcessing.makeContext(width: width, height: height)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(red: 0.1, green: 0.2, blue: 0.9, alpha: 1))
        let blockWidth = max(4, width / 6)
        let travel = max(1, width - blockWidth)
        let x = travel * step / max(1, steps - 1)
        ctx.fill(CGRect(x: x, y: height / 4, width: blockWidth, height: max(4, height / 2)))
        return ctx.makeImage()!
    }
}

@Suite("libwebp bridge")
struct WebPCodecTests {

    @Test("The linked-in libwebp is the vendored 1.6.0, not a system copy")
    func vendoredVersion() {
        #expect(WebPCodec.encoderVersion == (1, 6, 0))
        #expect(WebPCodec.muxVersion == (1, 6, 0))
        #expect(WebPCodec.demuxVersion == (1, 6, 0))
        #expect(WebPCodec.versionString == "1.6.0")
    }

    @Test("A still encodes to a RIFF/WEBP container that decodes back at the same size")
    func stillRoundTrip() throws {
        let image = WebPTestImages.solid(width: 64, height: 48, red: 0.9, green: 0.2, blue: 0.2)
        let data = try WebPCodec.encodeStill(image, quality: 90)

        #expect(data.count > 0)
        #expect(MagicBytes.detect(data) == .webpStill)

        let decoded = try WebPCodec.decodeStill(data: data)
        #expect(decoded.width == 64)
        #expect(decoded.height == 48)
    }

    @Test("An opaque still is not decoded as fully transparent")
    func stillIsOpaque() throws {
        // Regression guard: importing TriCap's RGBX buffer with WebPPictureImportRGBA would read
        // the unused X byte as alpha and produce a completely transparent file.
        let image = WebPTestImages.solid(width: 32, height: 32, red: 1.0, green: 0.0, blue: 0.0)
        let data = try WebPCodec.encodeStill(image, quality: 100)
        let decoded = try WebPCodec.decodeStill(data: data)

        let raster = ImageProcessing.rgbxBytes(decoded)!
        let centre = (raster.height / 2) * raster.stride + (raster.width / 2) * 4
        #expect(raster.bytes[centre] > 200)       // red
        #expect(raster.bytes[centre + 1] < 80)    // green
        #expect(raster.bytes[centre + 2] < 80)    // blue
    }

    @Test("Lossless stills round-trip pixel values exactly")
    func losslessRoundTrip() throws {
        let image = WebPTestImages.solid(width: 16, height: 16, red: 0.25, green: 0.5, blue: 0.75)
        let data = try WebPCodec.encodeStill(image, quality: 100, lossless: true)
        let decoded = try WebPCodec.decodeStill(data: data)

        let source = ImageProcessing.rgbxBytes(image)!
        let result = ImageProcessing.rgbxBytes(decoded)!
        for i in stride(from: 0, to: source.bytes.count, by: 4) {
            #expect(source.bytes[i] == result.bytes[i])
            #expect(source.bytes[i + 1] == result.bytes[i + 1])
            #expect(source.bytes[i + 2] == result.bytes[i + 2])
        }
    }

    @Test("An animation reports the encoded canvas, frame count and infinite loop")
    func animationStructure() throws {
        let frames = (0..<6).map {
            WebPCodec.AnimationFrame(
                image: WebPTestImages.movingBlock(width: 80, height: 60, step: $0, steps: 6),
                timestampMs: $0 * 83
            )
        }
        let data = try WebPCodec.encodeAnimation(
            frames: frames,
            canvasSize: CGSize(width: 80, height: 60),
            endTimestampMs: 6 * 83,
            options: AnimatedWebPOptions(quality: 80, loopCount: 0)
        )

        #expect(MagicBytes.detect(data) == .webpAnimated)

        let info = try WebPCodec.inspectAnimation(data: data)
        #expect(info.canvasWidth == 80)
        #expect(info.canvasHeight == 60)
        #expect(info.frameCount == 6)
        #expect(info.loopCount == 0)  // 0 == loop forever
        #expect(info.isAnimated)
    }

    @Test("Frame timestamps read back out of the file are strictly increasing")
    func timestampsAreMonotonic() throws {
        let timestamps = [0, 83, 167, 250, 333, 417, 500]
        let frames = timestamps.enumerated().map { index, ts in
            WebPCodec.AnimationFrame(
                image: WebPTestImages.movingBlock(width: 64, height: 64, step: index, steps: timestamps.count),
                timestampMs: ts
            )
        }
        let data = try WebPCodec.encodeAnimation(
            frames: frames,
            canvasSize: CGSize(width: 64, height: 64),
            endTimestampMs: 583,
            options: .default
        )

        let info = try WebPCodec.inspectAnimation(data: data)
        #expect(info.frameTimestampsMs.count == timestamps.count)
        for (a, b) in zip(info.frameTimestampsMs, info.frameTimestampsMs.dropFirst()) {
            #expect(b > a)
        }
        // The demuxer reports end-of-frame timestamps, so the last one is the total duration.
        #expect(info.totalDurationMs == 583)
        #expect(info.durationsMs.allSatisfy { $0 > 0 })
    }

    @Test("A finite loop count survives the round trip")
    func finiteLoopCount() throws {
        let frames = (0..<3).map {
            WebPCodec.AnimationFrame(
                image: WebPTestImages.movingBlock(width: 32, height: 32, step: $0, steps: 3),
                timestampMs: $0 * 100
            )
        }
        let data = try WebPCodec.encodeAnimation(
            frames: frames,
            canvasSize: CGSize(width: 32, height: 32),
            endTimestampMs: 300,
            options: AnimatedWebPOptions(quality: 75, loopCount: 3)
        )
        #expect(try WebPCodec.inspectAnimation(data: data).loopCount == 3)
    }

    @Test("Non-monotonic timestamps are rejected before libwebp sees them")
    func rejectsNonMonotonicTimestamps() {
        let frames = [
            WebPCodec.AnimationFrame(image: WebPTestImages.solid(width: 16, height: 16, red: 1, green: 0, blue: 0), timestampMs: 0),
            WebPCodec.AnimationFrame(image: WebPTestImages.solid(width: 16, height: 16, red: 0, green: 1, blue: 0), timestampMs: 100),
            WebPCodec.AnimationFrame(image: WebPTestImages.solid(width: 16, height: 16, red: 0, green: 0, blue: 1), timestampMs: 100),
        ]
        #expect(throws: TriCapError.self) {
            try WebPCodec.encodeAnimation(
                frames: frames,
                canvasSize: CGSize(width: 16, height: 16),
                endTimestampMs: 200,
                options: .default
            )
        }
    }

    @Test("An end timestamp that is not after the last frame is rejected")
    func rejectsBadEndTimestamp() {
        let frames = [
            WebPCodec.AnimationFrame(image: WebPTestImages.solid(width: 16, height: 16, red: 1, green: 0, blue: 0), timestampMs: 0),
            WebPCodec.AnimationFrame(image: WebPTestImages.solid(width: 16, height: 16, red: 0, green: 1, blue: 0), timestampMs: 100),
        ]
        #expect(throws: TriCapError.self) {
            try WebPCodec.encodeAnimation(
                frames: frames,
                canvasSize: CGSize(width: 16, height: 16),
                endTimestampMs: 100,
                options: .default
            )
        }
    }

    @Test("A frame whose size disagrees with the canvas is rejected")
    func rejectsMismatchedFrameSize() {
        let frames = [
            WebPCodec.AnimationFrame(image: WebPTestImages.solid(width: 16, height: 16, red: 1, green: 0, blue: 0), timestampMs: 0),
            WebPCodec.AnimationFrame(image: WebPTestImages.solid(width: 32, height: 16, red: 0, green: 1, blue: 0), timestampMs: 100),
        ]
        #expect(throws: TriCapError.self) {
            try WebPCodec.encodeAnimation(
                frames: frames,
                canvasSize: CGSize(width: 16, height: 16),
                endTimestampMs: 200,
                options: .default
            )
        }
    }

    @Test("An animation with no frames is rejected")
    func rejectsEmptyAnimation() {
        #expect(throws: TriCapError.self) {
            try WebPCodec.encodeAnimation(
                frames: [],
                canvasSize: CGSize(width: 16, height: 16),
                endTimestampMs: 100,
                options: .default
            )
        }
    }

    @Test("Inspecting non-WebP bytes fails instead of returning nonsense")
    func rejectsGarbage() {
        #expect(throws: TriCapError.self) {
            try WebPCodec.inspectAnimation(data: Data(repeating: 0x00, count: 128))
        }
    }

    @Test("The streaming encoder pulls each frame exactly once, in order")
    func streamingPullsFramesInOrder() throws {
        var pulled: [Int] = []
        let data = try WebPCodec.encodeAnimationStreaming(
            frameCount: 5,
            canvasSize: CGSize(width: 48, height: 32),
            endTimestampMs: 500,
            options: .default
        ) { index in
            pulled.append(index)
            return (WebPTestImages.movingBlock(width: 48, height: 32, step: index, steps: 5), index * 100)
        }

        #expect(pulled == [0, 1, 2, 3, 4])
        #expect(try WebPCodec.inspectAnimation(data: data).frameCount == 5)
    }
}

@Suite("Magic byte detection")
struct MagicBytesTests {

    @Test("PNG bytes are detected")
    func png() throws {
        let image = WebPTestImages.solid(width: 8, height: 8, red: 0, green: 0, blue: 0)
        let data = try StillImageCodec.encodePNG(image)
        #expect(MagicBytes.detect(data) == .png)
        #expect(MagicBytes.detect(data).matchesExtension == "png")
    }

    @Test("JPEG bytes are detected")
    func jpeg() throws {
        let image = WebPTestImages.solid(width: 8, height: 8, red: 0, green: 0, blue: 0)
        let data = try StillImageCodec.encodeJPEG(image, quality: 80)
        #expect(MagicBytes.detect(data) == .jpeg)
        #expect(MagicBytes.detect(data).matchesExtension == "jpg")
    }

    @Test("Still and animated WebP are told apart")
    func webpVariants() throws {
        let still = try WebPCodec.encodeStill(
            WebPTestImages.solid(width: 16, height: 16, red: 0.5, green: 0.5, blue: 0.5), quality: 80
        )
        #expect(MagicBytes.detect(still) == .webpStill)

        let animated = try WebPCodec.encodeAnimation(
            frames: (0..<3).map {
                WebPCodec.AnimationFrame(
                    image: WebPTestImages.movingBlock(width: 16, height: 16, step: $0, steps: 3),
                    timestampMs: $0 * 100
                )
            },
            canvasSize: CGSize(width: 16, height: 16),
            endTimestampMs: 300,
            options: .default
        )
        #expect(MagicBytes.detect(animated) == .webpAnimated)
    }

    @Test("Unrecognised and truncated data are reported as unknown")
    func unknown() {
        #expect(MagicBytes.detect(Data()) == .unknown)
        #expect(MagicBytes.detect(Data([0x89, 0x50])) == .unknown)
        #expect(MagicBytes.detect(Data(repeating: 0x41, count: 64)) == .unknown)
    }

    @Test("Detection works on a Data slice, not just a fresh buffer")
    func handlesSlices() throws {
        let image = WebPTestImages.solid(width: 8, height: 8, red: 1, green: 1, blue: 1)
        let data = try StillImageCodec.encodePNG(image)
        let padded = Data([0xFF, 0xFF]) + data
        #expect(MagicBytes.detect(padded.dropFirst(2)) == .png)
    }
}

@Suite("Animated WebP frame coalescing")
struct WebPCoalescingTests {

    /// libwebp's animation encoder merges a frame that is identical to its predecessor into that
    /// predecessor's display duration. That is correct and desirable — it shrinks the file without
    /// changing playback — but it means "frames in == frames out" is *not* a valid post-condition.
    /// This test pins the behaviour so the export verifier is never tightened back to equality.
    @Test("Frames identical to their predecessor are merged into it")
    func identicalFramesMerge() throws {
        // Frames 1 and 2 duplicate frame 0; frames 4 and 5 duplicate frame 3.
        let a = WebPTestImages.solid(width: 40, height: 40, red: 0.2, green: 0.5, blue: 0.8)
        let b = WebPTestImages.solid(width: 40, height: 40, red: 0.9, green: 0.3, blue: 0.1)
        let images = [a, a, a, b, b, b]
        let frames = images.enumerated().map {
            WebPCodec.AnimationFrame(image: $0.element, timestampMs: $0.offset * 100)
        }

        let data = try WebPCodec.encodeAnimation(
            frames: frames,
            canvasSize: CGSize(width: 40, height: 40),
            endTimestampMs: 600,
            options: .default
        )
        let info = try WebPCodec.inspectAnimation(data: data)

        #expect(info.frameCount == 2)             // six submitted, two distinct
        #expect(info.totalDurationMs == 600)      // playback still runs the full 600 ms
        #expect(info.durationsMs == [300, 300])   // each merged run keeps its combined duration
        #expect(info.loopCount == 0)
        #expect(info.canvasWidth == 40)
    }

    @Test("An entirely static recording collapses to a single-frame still WebP")
    func allIdenticalCollapsesToStill() throws {
        // Worth pinning: this is what a recording of a completely motionless screen produces.
        // libwebp drops the ANIM chunk entirely, so the file is a *still* WebP with loop count 1
        // and no duration — which `ExportService` detects and reports rather than rejecting.
        let solid = WebPTestImages.solid(width: 32, height: 32, red: 0.2, green: 0.5, blue: 0.8)
        let frames = (0..<10).map { WebPCodec.AnimationFrame(image: solid, timestampMs: $0 * 100) }

        let data = try WebPCodec.encodeAnimation(
            frames: frames,
            canvasSize: CGSize(width: 32, height: 32),
            endTimestampMs: 1000,
            options: .default
        )

        #expect(MagicBytes.detect(data) == .webpStill)
        let info = try WebPCodec.inspectAnimation(data: data)
        #expect(info.frameCount == 1)
        #expect(info.isAnimated == false)
    }

    @Test("Distinct frames are never merged")
    func distinctFramesSurvive() throws {
        let frames = (0..<10).map {
            WebPCodec.AnimationFrame(
                image: WebPTestImages.movingBlock(width: 48, height: 32, step: $0, steps: 10),
                timestampMs: $0 * 100
            )
        }
        let data = try WebPCodec.encodeAnimation(
            frames: frames,
            canvasSize: CGSize(width: 48, height: 32),
            endTimestampMs: 1000,
            options: .default
        )
        let info = try WebPCodec.inspectAnimation(data: data)
        #expect(info.frameCount == 10)
        #expect(info.totalDurationMs == 1000)
    }
}
