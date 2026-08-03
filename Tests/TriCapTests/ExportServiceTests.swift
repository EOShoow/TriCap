import CoreGraphics
import Foundation
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
