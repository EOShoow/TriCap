import AnnotationCore
import AppKit
import CaptureCore
import CoreGraphics
import ExportCore
import Foundation
import ImageIO
import TriCapKit

/// Exercises the real editor actions against an isolated pasteboard, without Screen Recording.
@MainActor
enum AnimationClipboardSelfTest {
    static let flag = "--selftest-animation-clipboard"

    static func runIfRequested(arguments: [String]) -> Bool {
        guard let index = arguments.firstIndex(of: flag) else { return false }
        let directory = index + 1 < arguments.count
            ? URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
            : FileManager.default.temporaryDirectory.appendingPathComponent("tricap-clipboard-\(UUID().uuidString)")
        Task { @MainActor in
            do {
                try await run(directory: directory)
                print("ALL ANIMATION CLIPBOARD CHECKS PASSED")
                exit(0)
            } catch {
                print("FAIL \(error.localizedDescription)")
                exit(1)
            }
        }
        NSApp.run()
        return true
    }

    private static func check(_ condition: Bool, _ label: String) throws {
        guard condition else { throw TriCapError.encodingFailed(label) }
        print("PASS \(label)")
    }

    private static func settled(_ model: EditorModel) async throws {
        let deadline = Date().addingTimeInterval(30)
        while model.isPreparingExport || model.isCopying || model.isExporting {
            guard Date() < deadline else { throw TriCapError.encodingFailed("Editor action timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
        try check(model.errorMessage == nil, model.errorMessage ?? "Editor action completed")
    }

    private static func run(directory: URL) async throws {
        let board = NSPasteboard.withUniqueName()
        defer {
            board.clearContents()
            AnimationClipboardFileStore.removeExpiredFiles()
            AnimationClipboardFileStore.removeExpiredFiles(now: Date().addingTimeInterval(301))
            board.releaseGlobally()
        }
        let saveDirectory = directory.appendingPathComponent("selected-save-\(UUID().uuidString)")
        var settings = AppSettings()
        settings.saveDirectoryPath = saveDirectory.path
        var saves = 0
        var copies = 0
        let clip = try fixture()
        let model = EditorModel(
            source: .clip(clip), settings: settings, autoCopyAnimation: true,
            pasteboard: board, onCopied: { _ in copies += 1 },
            onExported: { _ in saves += 1 }, onClosed: {}
        )
        defer { model.close() }
        try await settled(model)
        try check(copies == 1 && saves == 0, "Recording automatically copies once without saving")
        try check(model.savedFileURL == nil, "Copy has no saved file URL")
        try check(!FileManager.default.fileExists(atPath: saveDirectory.path), "Automatic copy creates no permanent export or save directory")
        guard let originalData = board.data(forType: PasteboardAnimation.webPType),
              let originalGIF = board.data(forType: PasteboardAnimation.gifType) else {
            throw TriCapError.encodingFailed("Both animation formats must be on the clipboard")
        }
        let original = try WebPCodec.inspectAnimation(data: originalData)
        try check(original.frameCount == 4 && original.totalDurationMs == 400, "Automatic copy retains all frames and playback duration")
        try check(CGImageSourceCreateWithData(originalGIF as CFData, nil).map(CGImageSourceGetCount) == 4,
                  "Automatic copy also provides a four-frame GIF")

        model.trimStart = 1
        model.trimEnd = 2
        model.commitCropDrag(from: .zero, to: CGPoint(x: 32, y: 32))
        var style = AnnotationStyle(color: .red)
        style.filled = true
        model.add(AnnotationItem(shape: .rectangle(CGRect(x: 4, y: 4, width: 8, height: 8)), style: style))
        try await settled(model)
        try check(copies == 1 && board.data(forType: PasteboardAnimation.webPType) == originalData,
                  "Editing waits for an explicit Copy")
        model.copyAnimation()
        try await settled(model)
        let edited = try WebPCodec.inspectAnimation(data: board.data(forType: PasteboardAnimation.webPType) ?? Data())
        try check(copies == 2 && edited.canvasWidth == 32 && edited.canvasHeight == 32
                  && edited.frameCount == 2 && edited.totalDurationMs == 200,
                  "Explicit Copy uses the edited trim and crop")
        try check(saves == 0 && !FileManager.default.fileExists(atPath: saveDirectory.path),
                  "Edited Copy still creates no saved export")

        model.export()
        try await settled(model)
        try check(saves == 1 && model.savedFileURL != nil, "Only explicit Save produces a file")
        let files = try FileManager.default.contentsOfDirectory(atPath: saveDirectory.path)
        try check(files.count == 1 && files[0].hasSuffix(".webp"), "Explicit Save writes exactly one WebP")

        let liveSource = AnimationFrameSource(
            frameCount: 4, timestampsMs: [0, 100, 200, 300], endTimestampMs: 400, canvasSize: clip.pixelSize
        ) { index in
            guard let image = clip.frames[index].decodedImage() else { throw TriCapError.noFramesCaptured }
            return image
        }
        let liveArtifact = try ExportService.prepareAnimation(
            source: liveSource, options: settings.animatedWebPOptions, cropRect: nil
        )
        let liveModel = EditorModel(
            source: .clip(clip), settings: settings, preEncoded: liveArtifact, autoCopyAnimation: true,
            pasteboard: board, onCopied: { _ in copies += 1 }, onExported: { _ in saves += 1 }, onClosed: {}
        )
        try await settled(liveModel)
        try check(copies == 3 && saves == 1, "A live pre-encoded recording automatically copies without saving")
        liveModel.close()

        let boardCount = board.changeCount
        let cancelled = EditorModel(
            source: .clip(clip), settings: settings, autoCopyAnimation: true,
            pasteboard: board, onExported: { _ in saves += 1 }, onClosed: {}
        )
        cancelled.close()
        try await Task.sleep(for: .milliseconds(500))
        try check(board.changeCount == boardCount && saves == 1, "Closing an editor cancels pending copy without saving")

        let presenter = EditorPresenter()
        let handle = presenter.present(
            source: .clip(clip), settings: settings, windowDelegate: nil, orderFront: false,
            autoCopyAnimation: true, pasteboard: board, onExported: { _ in saves += 1 }
        )
        guard let heldModel = handle.model, let window = handle.window else {
            throw TriCapError.encodingFailed("Could not create the editor window")
        }
        presenter.release(window)
        window.close()
        try await Task.sleep(for: .milliseconds(500))
        try check(!heldModel.isPreparingExport && !heldModel.isCopying && board.changeCount == boardCount,
                  "Title-bar teardown cancels work even while the model remains alive")

        let superseded = EditorModel(
            source: .clip(clip), settings: settings, autoCopyAnimation: true,
            pasteboard: board, onExported: { _ in saves += 1 }, onClosed: {}
        )
        board.clearContents()
        board.setString("a newer clipboard item", forType: .string)
        try await settled(superseded)
        try check(board.string(forType: .string) == "a newer clipboard item",
                  "A delayed automatic copy preserves newer clipboard contents")
        superseded.close()
    }

    private static func fixture() throws -> RecordedClip {
        let frames: [RecordedFrame] = try (0..<4).map { index in
            guard let ctx = ImageProcessing.makeContext(width: 64, height: 48) else {
                throw TriCapError.encodingFailed("Could not create the test image")
            }
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: index * 6, y: 24, width: 6, height: 12))
            guard let image = ctx.makeImage(), let png = ImageProcessing.pngData(from: image) else {
                throw TriCapError.encodingFailed("Could not encode the test image")
            }
            return RecordedFrame(pngData: png, timestamp: Double(index) / 10)
        }
        let display = DisplayGeometry(
            displayID: 1, appKitBounds: CGRect(x: 0, y: 0, width: 64, height: 48),
            quartzBounds: CGRect(x: 0, y: 0, width: 64, height: 48),
            pointPixelScale: 1, primaryHeightInPoints: 48
        )
        return RecordedClip(
            frames: frames, pixelSize: CGSize(width: 64, height: 48),
            region: CaptureRegion(
                display: display, appKitGlobalRect: CGRect(x: 0, y: 0, width: 64, height: 48),
                displayPixelRect: CGRect(x: 0, y: 0, width: 64, height: 48),
                sourceRectInDisplayPoints: CGRect(x: 0, y: 0, width: 64, height: 48)
            ),
            nominalFrameInterval: 0.1, stopReason: .userStopped, droppedFrameCount: 0,
            colorSpace: nil, retainedBytes: frames.reduce(0) { $0 + $1.pngData.count }, wallClockDuration: 0.4
        )
    }
}
