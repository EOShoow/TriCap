import AnnotationCore
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import ExportCore
@testable import TriCapKit

@Suite("Animation clipboard")
struct AnimationClipboardTests {
    private func source(count: Int = 4, durationMs: Int = 1000) -> AnimationFrameSource {
        AnimationFrameSource(
            frameCount: count,
            timestampsMs: (0..<count).map { Int((Double($0) * 1000 / 12).rounded()) },
            endTimestampMs: durationMs,
            canvasSize: CGSize(width: 64, height: 48)
        ) { index in
            WebPTestImages.movingBlock(width: 64, height: 48, step: index, steps: count)
        }
    }

    private func gifDuration(_ data: Data) throws -> Double {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        return try (0..<CGImageSourceGetCount(source)).reduce(0) { total, index in
            let props = try #require(CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any])
            let gif = try #require(props[kCGImagePropertyGIFDictionary as String] as? [String: Any])
            let delay = try #require(gif[kCGImagePropertyGIFUnclampedDelayTime as String] as? Double)
            return total + delay
        }
    }

    @Test("GIF and WebP preserve motion, looping and a held final frame")
    func fullAnimationPayload() throws {
        let payload = try PasteboardAnimation.prepare(source: source(), annotations: [], options: .default)
        let gif = try #require(CGImageSourceCreateWithData(payload.gifData as CFData, nil))
        #expect(CGImageSourceGetCount(gif) == 4)
        #expect(payload.webP.animationInfo.frameCount == 4)
        #expect(payload.webP.animationInfo.totalDurationMs == 1000)
        #expect(abs(try gifDuration(payload.gifData) - 1) < 0.001)
        let props = try #require(CGImageSourceCopyProperties(gif, nil) as? [String: Any])
        let gifProps = try #require(props[kCGImagePropertyGIFDictionary as String] as? [String: Any])
        #expect(gifProps[kCGImagePropertyGIFLoopCount as String] as? Int == 0)
        let first = try #require(CGImageSourceCreateImageAtIndex(gif, 0, nil))
        let last = try #require(CGImageSourceCreateImageAtIndex(gif, 3, nil))
        #expect(ImageProcessing.rgbxBytes(first)?.bytes != ImageProcessing.rgbxBytes(last)?.bytes)
    }

    @Test("GIF centisecond rounding does not drift across a 15 second recording")
    func gifTimingDoesNotAccumulateRoundingError() throws {
        let payload = try PasteboardAnimation.prepare(
            source: source(count: 180, durationMs: 15_000), annotations: [], options: .default
        )
        #expect(abs(try gifDuration(payload.gifData) - 15) < 0.001)
    }

    @Test("Finite GIF playback matches WebP's total play count", arguments: [1, 3])
    func finiteLoopCount(plays: Int) throws {
        var options = AnimatedWebPOptions.default
        options.loopCount = plays
        let payload = try PasteboardAnimation.prepare(source: source(), annotations: [], options: options)
        #expect(payload.webP.animationInfo.loopCount == plays)
        let gif = try #require(CGImageSourceCreateWithData(payload.gifData as CFData, nil))
        let properties = CGImageSourceCopyProperties(gif, nil) as? [String: Any]
        let loop = (properties?[kCGImagePropertyGIFDictionary as String] as? [String: Any])?[kCGImagePropertyGIFLoopCount as String] as? Int
        #expect(loop == plays)
        let marker = payload.gifData.range(of: Data("NETSCAPE2.0".utf8))
        if plays == 1 {
            #expect(marker == nil)
        } else {
            let offset = try #require(marker).upperBound
            let repeats = Int(payload.gifData[offset + 2]) | (Int(payload.gifData[offset + 3]) << 8)
            #expect(repeats == plays - 1)
        }
    }

    @Test("Annotations and crop are baked into every clipboard frame")
    func editedClipboardPayload() throws {
        var style = AnnotationStyle(color: .red)
        style.filled = true
        let annotation = AnnotationItem(shape: .rectangle(CGRect(x: 12, y: 4, width: 8, height: 8)), style: style)
        let payload = try PasteboardAnimation.prepare(
            source: source(), annotations: [annotation], options: .default,
            cropRect: CGRect(x: 8, y: 0, width: 40, height: 32)
        )
        #expect(payload.webP.pixelSize == CGSize(width: 40, height: 32))
        let gif = try #require(CGImageSourceCreateWithData(payload.gifData as CFData, nil))
        for index in 0..<4 {
            let image = try #require(CGImageSourceCreateImageAtIndex(gif, index, nil))
            #expect(image.width == 40 && image.height == 32)
            let raster = try #require(ImageProcessing.rgbxBytes(image))
            let offset = 8 * raster.stride + 8 * 4
            #expect(raster.bytes[offset] > 180 && raster.bytes[offset + 1] < 90)
        }
    }

    @Test("One pasteboard item contains animations and a temporary GIF for file-only receivers")
    @MainActor
    func pasteboardRoundTrip() throws {
        let payload = try PasteboardAnimation.prepare(source: source(), annotations: [], options: .default)
        let board = NSPasteboard.withUniqueName()
        defer {
            board.clearContents()
            AnimationClipboardFileStore.removeExpiredFiles()
            AnimationClipboardFileStore.removeExpiredFiles(now: Date().addingTimeInterval(301))
            board.releaseGlobally()
        }
        let receipt = try #require(PasteboardAnimation.write(payload, to: board))
        #expect(board.pasteboardItems?.count == 1)
        #expect(board.data(forType: PasteboardAnimation.gifType) == payload.gifData)
        #expect(board.data(forType: PasteboardAnimation.webPType) == payload.webP.data)
        #expect(board.data(forType: .png) == nil)
        // macOS may synthesize TIFF when asked, even though we never advertise/write it.
        #expect(board.string(forType: .fileURL) == receipt.temporaryFileURL.absoluteString)
        #expect(receipt.temporaryFileURL.deletingLastPathComponent() == AnimationClipboardFileStore.directory)
        #expect(try Data(contentsOf: receipt.temporaryFileURL) == payload.gifData)
        let files = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        #expect((files?.first as? URL) == receipt.temporaryFileURL)
        #expect(board.string(forType: .string) == nil)
        #expect(receipt.frameCount == 4 && receipt.durationMs == 1000)
        board.clearContents()
        AnimationClipboardFileStore.removeExpiredFiles()
        #expect(FileManager.default.fileExists(atPath: receipt.temporaryFileURL.path))
        AnimationClipboardFileStore.removeExpiredFiles(now: Date().addingTimeInterval(301))
        #expect(!FileManager.default.fileExists(atPath: receipt.temporaryFileURL.path))
    }

    @Test("A cancelled copy never reaches frame loading")
    func cancelledCopy() throws {
        let unloaded = AnimationFrameSource(
            frameCount: 2, timestampsMs: [0, 100], endTimestampMs: 200,
            canvasSize: CGSize(width: 64, height: 48)
        ) { _ in
            Issue.record("Cancelled clipboard preparation must not load a frame")
            return WebPTestImages.solid(width: 64, height: 48, red: 1, green: 1, blue: 1)
        }
        #expect(throws: TriCapError.self) {
            _ = try PasteboardAnimation.prepare(
                source: unloaded, annotations: [], options: .default, isCancelled: { true }
            )
        }
    }

    @Test("A motionless recording is reported as an image, with one GIF frame")
    @MainActor
    func staticRecordingIsHonest() throws {
        let still = AnimationFrameSource(
            frameCount: 2, timestampsMs: [0, 100], endTimestampMs: 200,
            canvasSize: CGSize(width: 64, height: 48)
        ) { _ in WebPTestImages.solid(width: 64, height: 48, red: 1, green: 0, blue: 0) }
        let payload = try PasteboardAnimation.prepare(source: still, annotations: [], options: .default)
        let gif = try #require(CGImageSourceCreateWithData(payload.gifData as CFData, nil))
        #expect(CGImageSourceGetCount(gif) == 1)
        let board = NSPasteboard.withUniqueName()
        defer {
            board.clearContents()
            AnimationClipboardFileStore.removeExpiredFiles()
            AnimationClipboardFileStore.removeExpiredFiles(now: Date().addingTimeInterval(301))
            board.releaseGlobally()
        }
        let receipt = try #require(PasteboardAnimation.write(payload, to: board))
        #expect(receipt.collapsedToSingleFrame)
        #expect(receipt.message.contains("nothing moved"))
    }
}
