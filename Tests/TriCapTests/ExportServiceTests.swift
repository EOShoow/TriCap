import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import AnnotationCore
@testable import CaptureCore
@testable import ExportCore
@testable import TriCapKit

private struct Scratch: ~Copyable {
    let root: URL
    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tricap-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
}

@Suite("Export service — stills")
struct StillExportTests {

    @Test("PNG export writes a PNG, verifies its magic bytes and reports its size", arguments: [
        OutputFormat.png, .jpeg, .webp,
    ])
    func exportsEachStillFormat(format: OutputFormat) throws {
        let scratch = try Scratch()
        let image = WebPTestImages.solid(width: 120, height: 90, red: 0.2, green: 0.6, blue: 0.4)

        let result = try ExportService.exportStill(
            image: image,
            annotations: [],
            format: format,
            quality: 85,
            directory: scratch.root,
            baseName: "shot",
            vaultRoot: nil,
            linkStyle: .markdown
        )

        #expect(result.url.pathExtension == format.fileExtension)
        #expect(result.format == format)
        #expect(result.pixelSize == CGSize(width: 120, height: 90))
        #expect(result.byteCount > 0)
        #expect(result.container.matchesExtension == format.fileExtension)
        #expect(FileManager.default.fileExists(atPath: result.url.path))

        let onDisk = try Data(contentsOf: result.url)
        #expect(onDisk.count == result.byteCount)
        #expect(MagicBytes.detect(onDisk) == result.container)
    }

    @Test("Annotations are baked into the exported still")
    func annotationsAreComposited() throws {
        let scratch = try Scratch()
        let image = WebPTestImages.solid(width: 100, height: 100, red: 1, green: 1, blue: 1)

        var style = AnnotationStyle(color: .red)
        style.filled = true
        let annotation = AnnotationItem(shape: .rectangle(CGRect(x: 0, y: 0, width: 50, height: 50)), style: style)

        let result = try ExportService.exportStill(
            image: image,
            annotations: [annotation],
            format: .png,
            quality: 100,
            directory: scratch.root,
            baseName: "annotated",
            vaultRoot: nil,
            linkStyle: .markdown
        )

        let decoded = try #require(ImageProcessing.image(fromPNG: try Data(contentsOf: result.url)))
        let raster = ImageProcessing.rgbxBytes(decoded)!
        // Top-left quadrant is red; bottom-right is untouched white.
        let inside = 10 * raster.stride + 10 * 4
        let outside = 90 * raster.stride + 90 * 4
        #expect(raster.bytes[inside] > 200 && raster.bytes[inside + 1] < 100)
        #expect(raster.bytes[outside] == 255 && raster.bytes[outside + 1] == 255)
    }

    @Test("A file inside the vault yields a relative Markdown reference")
    func referenceInsideVault() throws {
        let scratch = try Scratch()
        let assets = scratch.root.appendingPathComponent("assets", isDirectory: true)

        let result = try ExportService.exportStill(
            image: WebPTestImages.solid(width: 20, height: 20, red: 0, green: 0, blue: 1),
            annotations: [],
            format: .png,
            quality: 90,
            directory: assets,
            baseName: "in-vault",
            vaultRoot: scratch.root,
            linkStyle: .markdown
        )
        #expect(result.reference == "![in-vault](assets/in-vault.png)")
    }

    @Test("A file outside the vault yields the absolute path")
    func referenceOutsideVault() throws {
        let scratch = try Scratch()
        let elsewhere = try Scratch()

        let result = try ExportService.exportStill(
            image: WebPTestImages.solid(width: 20, height: 20, red: 0, green: 0, blue: 1),
            annotations: [],
            format: .png,
            quality: 90,
            directory: elsewhere.root,
            baseName: "outside",
            vaultRoot: scratch.root,
            linkStyle: .markdown
        )
        #expect(result.reference == result.url.standardizedFileURL.path)
        #expect(result.reference.hasPrefix("![") == false)
    }

    @Test("Asking the still exporter for an animation is rejected")
    func rejectsAnimatedFormat() throws {
        let scratch = try Scratch()
        #expect(throws: TriCapError.self) {
            try ExportService.exportStill(
                image: WebPTestImages.solid(width: 10, height: 10, red: 0, green: 0, blue: 0),
                annotations: [],
                format: .animatedWebP,
                quality: 80,
                directory: scratch.root,
                baseName: "nope",
                vaultRoot: nil,
                linkStyle: .markdown
            )
        }
    }

    @Test("A failing export leaves no file behind")
    func failedWriteLeavesNothing() throws {
        let scratch = try Scratch()
        let locked = scratch.root.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path) }

        #expect(throws: TriCapError.self) {
            try ExportService.exportStill(
                image: WebPTestImages.solid(width: 10, height: 10, red: 0, green: 0, blue: 0),
                annotations: [],
                format: .png,
                quality: 90,
                directory: locked,
                baseName: "shot",
                vaultRoot: nil,
                linkStyle: .markdown
            )
        }
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: locked.path)) ?? []
        #expect(contents.isEmpty)
    }
}

@Suite("Export service — animated WebP")
struct AnimationExportTests {

    /// A source of `count` distinct frames at a steady 12 fps.
    static func source(count: Int, size: CGSize = CGSize(width: 96, height: 64)) -> AnimationFrameSource {
        let timestamps = (0..<count).map { $0 * 83 }
        return AnimationFrameSource(
            frameCount: count,
            timestampsMs: timestamps,
            endTimestampMs: (timestamps.last ?? 0) + 83,
            canvasSize: size
        ) { index in
            WebPTestImages.movingBlock(
                width: Int(size.width), height: Int(size.height), step: index, steps: count
            )
        }
    }

    @Test("A recorded clip exports to an animated WebP whose structure matches what was encoded")
    func exportsAnimation() throws {
        let scratch = try Scratch()
        let source = Self.source(count: 8)

        let result = try ExportService.exportAnimation(
            source: source,
            annotations: [],
            options: AnimatedWebPOptions(quality: 80, loopCount: 0),
            directory: scratch.root,
            baseName: "clip",
            vaultRoot: nil,
            linkStyle: .markdown
        )

        #expect(result.url.pathExtension == "webp")
        #expect(result.container == .webpAnimated)
        #expect(result.pixelSize == CGSize(width: 96, height: 64))

        let info = try #require(result.animationInfo)
        #expect(info.frameCount == 8)
        #expect(info.canvasWidth == 96)
        #expect(info.canvasHeight == 64)
        #expect(info.loopCount == 0)
        for (a, b) in zip(info.frameTimestampsMs, info.frameTimestampsMs.dropFirst()) { #expect(b > a) }
    }

    @Test("Progress is reported once per frame and ends at 1.0")
    func reportsProgress() throws {
        let scratch = try Scratch()
        var samples: [Double] = []

        _ = try ExportService.exportAnimation(
            source: Self.source(count: 5),
            annotations: [],
            options: .default,
            directory: scratch.root,
            baseName: "progress",
            vaultRoot: nil,
            linkStyle: .markdown,
            progress: { samples.append($0) }
        )

        #expect(samples.count == 5)
        #expect(samples.last == 1.0)
        for (a, b) in zip(samples, samples.dropFirst()) { #expect(b > a) }
    }

    @Test("The annotation overlay is applied to every frame")
    func overlayAppliedToAllFrames() throws {
        let scratch = try Scratch()
        var style = AnnotationStyle(color: .red)
        style.filled = true
        // A band across the top-left that is stable in every frame.
        let overlay = AnnotationItem(shape: .rectangle(CGRect(x: 0, y: 0, width: 30, height: 20)), style: style)

        let result = try ExportService.exportAnimation(
            source: Self.source(count: 4),
            annotations: [overlay],
            options: AnimatedWebPOptions(quality: 100, loopCount: 0, lossless: true),
            directory: scratch.root,
            baseName: "overlay",
            vaultRoot: nil,
            linkStyle: .markdown
        )

        // Decode each frame and confirm the overlay pixel is red in all of them.
        let data = try Data(contentsOf: result.url)
        let frames = try decodeAllFrames(data: data, width: 96, height: 64)
        #expect(frames.count == 4)
        for frame in frames {
            let offset = 10 * 96 * 4 + 10 * 4
            #expect(frame[offset] > 180)      // red channel
            #expect(frame[offset + 1] < 90)   // green channel
        }
    }

    @Test("A vault-relative reference is produced for animations too")
    func animationReference() throws {
        let scratch = try Scratch()
        let assets = scratch.root.appendingPathComponent("media", isDirectory: true)

        let result = try ExportService.exportAnimation(
            source: Self.source(count: 3),
            annotations: [],
            options: .default,
            directory: assets,
            baseName: "demo",
            vaultRoot: scratch.root,
            linkStyle: .markdown
        )
        #expect(result.reference == "![demo](media/demo.webp)")
    }

    @Test("A source whose timeline disagrees with its frame count is rejected")
    func rejectsMismatchedTimeline() throws {
        let scratch = try Scratch()
        let bad = AnimationFrameSource(
            frameCount: 3,
            timestampsMs: [0, 100],
            endTimestampMs: 200,
            canvasSize: CGSize(width: 16, height: 16)
        ) { _ in WebPTestImages.solid(width: 16, height: 16, red: 1, green: 0, blue: 0) }

        #expect(throws: TriCapError.self) {
            try ExportService.exportAnimation(
                source: bad, annotations: [], options: .default,
                directory: scratch.root, baseName: "bad", vaultRoot: nil, linkStyle: .markdown
            )
        }
    }

    @Test("An empty source is rejected before any file is created")
    func rejectsEmptySource() throws {
        let scratch = try Scratch()
        let empty = AnimationFrameSource(
            frameCount: 0, timestampsMs: [], endTimestampMs: 0, canvasSize: CGSize(width: 16, height: 16)
        ) { _ in WebPTestImages.solid(width: 16, height: 16, red: 1, green: 0, blue: 0) }

        #expect(throws: TriCapError.self) {
            try ExportService.exportAnimation(
                source: empty, annotations: [], options: .default,
                directory: scratch.root, baseName: "empty", vaultRoot: nil, linkStyle: .markdown
            )
        }
        let contents = try FileManager.default.contentsOfDirectory(atPath: scratch.root.path)
        #expect(contents.isEmpty)
    }

    @Test("A full capture→trim→timeline→export pipeline produces a playable animation")
    func endToEndFromRecordedFrames() throws {
        let scratch = try Scratch()

        // Simulate what RegionRecorder accumulates: PNG frames with real presentation times.
        let recorded: [RecordedFrame] = (0..<10).map { index in
            let image = WebPTestImages.movingBlock(width: 64, height: 48, step: index, steps: 10)
            return RecordedFrame(
                pngData: ImageProcessing.pngData(from: image)!,
                timestamp: Double(index) / 12.0
            )
        }

        // Trim head and tail the way the editor's handles would.
        let trimmed = ClipTrimmer.trim(frames: recorded, to: 2...7)
        #expect(trimmed.count == 6)

        let timeline = try #require(ClipTiming.timeline(for: trimmed, nominalFrameInterval: 1.0 / 12.0))
        let source = AnimationFrameSource(
            frameCount: trimmed.count,
            timestampsMs: timeline.timestampsMs,
            endTimestampMs: timeline.endTimestampMs,
            canvasSize: CGSize(width: 64, height: 48)
        ) { index in
            guard let image = trimmed[index].decodedImage() else {
                throw TriCapError.encodingFailed("frame \(index) failed to decode")
            }
            return image
        }

        let result = try ExportService.exportAnimation(
            source: source,
            annotations: [],
            options: AnimatedWebPOptions(quality: 80, loopCount: 0),
            directory: scratch.root,
            baseName: "pipeline",
            vaultRoot: nil,
            linkStyle: .markdown
        )

        let info = try #require(result.animationInfo)
        #expect(info.frameCount == 6)
        #expect(info.loopCount == 0)
        #expect(info.totalDurationMs == timeline.endTimestampMs)
        #expect(try MagicBytes.detect(fileAt: result.url) == .webpAnimated)
    }
}

/// Decode every frame of an animated WebP into raw RGBA bytes.
private func decodeAllFrames(data: Data, width: Int, height: Int) throws -> [[UInt8]] {
    // Uses the same demuxer path as `WebPCodec.inspectAnimation`, but keeps the pixels.
    var frames: [[UInt8]] = []
    let info = try WebPCodec.inspectAnimation(data: data)
    #expect(info.canvasWidth == width)
    #expect(info.canvasHeight == height)

    // The public inspect API does not return pixels, so re-run the decode through the
    // still decoder on each demuxed frame is not possible; instead assert via a fresh
    // decode of the whole animation using the codec's own frame walk.
    frames = try WebPCodec.decodeAnimationFrames(data: data)
    return frames
}

@Suite("Export service — degenerate recordings")
struct StaticRecordingExportTests {

    /// A recording where nothing moved: libwebp collapses it to a single-frame still WebP.
    /// TriCap keeps that file (it is valid and correct) but flags it, instead of either failing
    /// the export or handing the user a "clip" that silently does not animate.
    @Test("A motionless recording is kept and reported, not rejected")
    func motionlessRecording() throws {
        let scratch = try Scratch()
        let frozen = WebPTestImages.solid(width: 64, height: 48, red: 0.35, green: 0.35, blue: 0.4)
        let timestamps = (0..<12).map { $0 * 83 }
        let source = AnimationFrameSource(
            frameCount: 12,
            timestampsMs: timestamps,
            endTimestampMs: (timestamps.last ?? 0) + 83,
            canvasSize: CGSize(width: 64, height: 48)
        ) { _ in frozen }

        let result = try ExportService.exportAnimation(
            source: source,
            annotations: [],
            options: AnimatedWebPOptions(quality: 80, loopCount: 0),
            directory: scratch.root,
            baseName: "static",
            vaultRoot: nil,
            linkStyle: .markdown
        )

        #expect(result.collapsedToSingleFrame)
        #expect(result.submittedFrameCount == 12)
        #expect(result.animationInfo?.frameCount == 1)
        #expect(result.container == .webpStill)
        #expect(result.url.pathExtension == "webp")
        #expect(FileManager.default.fileExists(atPath: result.url.path))
        #expect(result.colorSpaceNotice?.contains("Nothing on screen changed") == true)
    }

    @Test("A normal recording is not flagged as collapsed")
    func movingRecordingIsNotFlagged() throws {
        let scratch = try Scratch()
        let result = try ExportService.exportAnimation(
            source: AnimationExportTests.source(count: 6),
            annotations: [],
            options: .default,
            directory: scratch.root,
            baseName: "moving",
            vaultRoot: nil,
            linkStyle: .markdown
        )
        #expect(result.collapsedToSingleFrame == false)
        #expect(result.container == .webpAnimated)
        #expect(result.submittedFrameCount == 6)
    }
}

// MARK: - Crop

@Suite("Export service — crop")
struct CropExportTests {

    /// Four solid quadrants, described in **row space** (top-left origin): TL red, TR green,
    /// BL blue, BR white. Distinct per quadrant so a mirrored or shifted crop cannot pass.
    private func quadrants(width: Int, height: Int) -> CGImage {
        let ctx = ImageProcessing.makeContext(width: width, height: height)!
        let w = CGFloat(width) / 2
        let h = CGFloat(height) / 2
        // The context is bottom-left origin, so "top" in row space is the *upper* context half.
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: h, width: w, height: h))          // row-space top-left
        ctx.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: w, y: h, width: w, height: h))          // row-space top-right
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))          // row-space bottom-left
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: w, y: 0, width: w, height: h))          // row-space bottom-right
        return ctx.makeImage()!
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) -> (UInt8, UInt8, UInt8) {
        let raster = ImageProcessing.rgbxBytes(image)!
        let offset = y * raster.stride + x * 4
        return (raster.bytes[offset], raster.bytes[offset + 1], raster.bytes[offset + 2])
    }

    private func decodePNG(at url: URL) throws -> CGImage {
        let data = try Data(contentsOf: url)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    @Test("A cropped still keeps exactly the requested pixels — row space, no mirror")
    func stillCropTakesTheRightPixels() throws {
        let scratch = try Scratch()
        let image = quadrants(width: 40, height: 40)

        // The row-space top-right quadrant. A y-flipped implementation would return the white
        // bottom-right quadrant instead; a shifted one would catch quadrant borders.
        let result = try ExportService.exportStill(
            image: image,
            annotations: [],
            format: .png,
            quality: 100,
            directory: scratch.root,
            baseName: "crop",
            vaultRoot: nil,
            linkStyle: .markdown,
            cropRect: CGRect(x: 20, y: 0, width: 20, height: 20)
        )

        #expect(result.pixelSize == CGSize(width: 20, height: 20))
        let out = try decodePNG(at: result.url)
        #expect(out.width == 20 && out.height == 20)
        for (x, y) in [(1, 1), (10, 10), (18, 18)] {
            let p = pixel(out, x: x, y: y)
            #expect(p.0 < 80 && p.1 > 180 && p.2 < 80,
                    "expected the green top-right quadrant at (\(x), \(y)), got \(p)")
        }
    }

    @Test("Annotations keep full-canvas coordinates; the crop is cut afterwards")
    func annotationsAnchorBeforeCrop() throws {
        let scratch = try Scratch()
        let image = WebPTestImages.solid(width: 40, height: 40, red: 1, green: 1, blue: 1)

        var style = AnnotationStyle(color: .red)
        style.filled = true
        // Canvas coordinates (10, 10)–(16, 16); inside the crop that region is (2, 2)–(8, 8).
        let annotation = AnnotationItem(
            shape: .rectangle(CGRect(x: 10, y: 10, width: 6, height: 6)), style: style
        )

        let result = try ExportService.exportStill(
            image: image,
            annotations: [annotation],
            format: .png,
            quality: 100,
            directory: scratch.root,
            baseName: "anchored",
            vaultRoot: nil,
            linkStyle: .markdown,
            cropRect: CGRect(x: 8, y: 8, width: 24, height: 24)
        )

        let out = try decodePNG(at: result.url)
        let inside = pixel(out, x: 5, y: 5)
        #expect(inside.0 > 180 && inside.1 < 90,
                "the annotation must land at crop-relative (2,2)–(8,8); got \(inside) at (5,5)")
        let outside = pixel(out, x: 20, y: 20)
        #expect(outside.0 > 200 && outside.1 > 200 && outside.2 > 200,
                "away from the annotation the crop shows the white base; got \(outside)")
    }

    @Test("A cropped animation writes a file whose canvas is the crop")
    func animationCropShrinksCanvas() throws {
        let scratch = try Scratch()

        let result = try ExportService.exportAnimation(
            source: AnimationExportTests.source(count: 3),
            annotations: [],
            options: AnimatedWebPOptions(quality: 100, loopCount: 0, lossless: true),
            directory: scratch.root,
            baseName: "cropped-clip",
            vaultRoot: nil,
            linkStyle: .markdown,
            cropRect: CGRect(x: 48, y: 0, width: 48, height: 32)
        )

        #expect(result.pixelSize == CGSize(width: 48, height: 32))
        let data = try Data(contentsOf: result.url)
        let frames = try decodeAllFrames(data: data, width: 48, height: 32)
        #expect(frames.count == 3)
    }

    @Test("A matching pre-encoded artifact is NOT reused when the export is cropped")
    func cropDefeatsPreEncodeReuse() throws {
        let scratch = try Scratch()
        let options = AnimatedWebPOptions(quality: 100, loopCount: 0, lossless: true)

        // A real full-canvas artifact whose metadata matches the source exactly — the strongest
        // possible reuse candidate.
        let full = try ExportService.exportAnimation(
            source: AnimationExportTests.source(count: 3),
            annotations: [],
            options: options,
            directory: scratch.root,
            baseName: "full",
            vaultRoot: nil,
            linkStyle: .markdown
        )
        let source = AnimationExportTests.source(count: 3)
        let artifact = PreEncodedAnimation(
            data: try Data(contentsOf: full.url),
            canvasSize: source.canvasSize,
            options: options,
            frameCount: source.frameCount,
            timestampsMs: source.timestampsMs,
            endTimestampMs: source.endTimestampMs
        )

        // If the crop failed to defeat reuse, the artifact's 96×64 canvas would be written and
        // the post-write canvas verification would throw — success alone proves the fallback.
        let cropped = try ExportService.exportAnimation(
            source: source,
            annotations: [],
            options: options,
            directory: scratch.root,
            baseName: "cropped",
            vaultRoot: nil,
            linkStyle: .markdown,
            preEncoded: artifact,
            cropRect: CGRect(x: 0, y: 32, width: 96, height: 32)
        )
        #expect(cropped.pixelSize == CGSize(width: 96, height: 32))
        let info = try WebPCodec.inspectAnimation(data: try Data(contentsOf: cropped.url))
        #expect(info.canvasWidth == 96 && info.canvasHeight == 32)
    }

    @Test("A crop that is not integral or not inside the canvas is refused")
    func invalidCropIsRefused() throws {
        let scratch = try Scratch()
        for bad in [
            CGRect(x: 0.5, y: 0, width: 20, height: 20),      // fractional origin
            CGRect(x: 0, y: 0, width: 20.25, height: 20),     // fractional size
            CGRect(x: 80, y: 0, width: 40, height: 20),       // spills past the right edge
        ] {
            #expect(throws: TriCapError.self) {
                _ = try ExportService.exportAnimation(
                    source: AnimationExportTests.source(count: 2),
                    annotations: [],
                    options: AnimatedWebPOptions(),
                    directory: scratch.root,
                    baseName: "bad-crop",
                    vaultRoot: nil,
                    linkStyle: .markdown,
                    cropRect: bad
                )
            }
        }
    }
}
