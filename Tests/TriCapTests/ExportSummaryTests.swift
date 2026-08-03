import CoreGraphics
import Foundation
import Testing
@testable import AnnotationCore
@testable import ExportCore
@testable import TriCapKit

/// The post-export confirmation is the only place TriCap tells the user what just happened, so its
/// wording is behaviour, not decoration. `ExportSummary` is a value type precisely so these claims
/// can be asserted instead of eyeballed.
@Suite("Export summary wording")
struct ExportSummaryTests {

    private func result(
        fileName: String = "TriCap-2026-08-03-141530.png",
        folder: String = "/Users/someone/Pictures/TriCap",
        format: OutputFormat = .png,
        bytes: Int = 1_234_567,
        pixelSize: CGSize = CGSize(width: 1440, height: 900),
        animationInfo: WebPCodec.AnimationInfo? = nil,
        collapsed: Bool = false,
        colorSpaceNotice: String? = nil
    ) -> ExportResult {
        ExportResult(
            url: URL(fileURLWithPath: folder).appendingPathComponent(fileName),
            format: format,
            pixelSize: pixelSize,
            byteCount: bytes,
            reference: "![shot](shot.png)",
            container: .png,
            animationInfo: animationInfo,
            submittedFrameCount: nil,
            collapsedToSingleFrame: collapsed,
            colorSpaceNotice: colorSpaceNotice
        )
    }

    @Test("A saved still reports its name, folder, size and dimensions")
    func stillSummary() {
        let summary = ExportSummary.make(
            from: result(), copiedReference: true, copiedImage: false, insideVault: false
        )
        #expect(summary.fileName == "TriCap-2026-08-03-141530.png")
        #expect(summary.folderDisplayPath.hasSuffix("Pictures/TriCap"))
        #expect(summary.detailDescription.contains("1440 × 900"))
        #expect(summary.detailDescription.contains("PNG"))
        #expect(!summary.sizeDescription.isEmpty)
        #expect(summary.warning == nil)
    }

    @Test("An animation reports its frame count and playback length")
    func animationSummary() {
        let info = WebPCodec.AnimationInfo(
            canvasWidth: 800, canvasHeight: 600, frameCount: 52, loopCount: 0,
            frameTimestampsMs: [], isAnimated: true
        )
        let summary = ExportSummary.make(
            from: result(format: .animatedWebP, animationInfo: info),
            copiedReference: true, copiedImage: false, insideVault: true
        )
        #expect(summary.detailDescription.contains("52 frames"))
        #expect(summary.detailDescription.contains("Animated WebP"))
    }

    @Test("The clipboard line names what will actually be pasted", arguments: [
        (true, false, true, "Copied the Markdown reference"),
        (true, false, false, "Copied the file path"),
        (false, true, false, "Copied the image"),
        (true, true, true, "Copied the image and the Markdown reference"),
    ])
    func clipboardWording(reference: Bool, image: Bool, insideVault: Bool, expected: String) {
        // "Copied to clipboard" does not tell the user whether they are about to paste a picture,
        // a Markdown embed, or a bare path — three very different outcomes in a note-taking app.
        #expect(
            ExportSummary.clipboardDescription(
                copiedReference: reference, copiedImage: image, insideVault: insideVault
            ) == expected
        )
    }

    @Test("Nothing copied says nothing, rather than claiming a copy")
    func nothingCopied() {
        #expect(
            ExportSummary.clipboardDescription(
                copiedReference: false, copiedImage: false, insideVault: true
            ) == nil
        )
        let summary = ExportSummary.make(
            from: result(), copiedReference: false, copiedImage: false, insideVault: true
        )
        #expect(summary.clipboardDescription == nil)
    }

    @Test("A summary reflects what actually happened, not what was requested")
    func reflectsRealOutcome() {
        // The caller passes the *result* of each pasteboard write, so a failed copy cannot be
        // reported as a success.
        let summary = ExportSummary.make(
            from: result(), copiedReference: false, copiedImage: true, insideVault: false
        )
        #expect(summary.clipboardDescription == "Copied the image")
    }

    @Test("A motionless recording is surfaced as a warning")
    func collapsedRecordingWarns() {
        let summary = ExportSummary.make(
            from: result(format: .animatedWebP, collapsed: true),
            copiedReference: true, copiedImage: false, insideVault: false
        )
        #expect(summary.warning?.contains("Nothing moved") == true)
    }

    @Test("A colour-space notice is carried into the confirmation")
    func colorSpaceWarningSurfaces() {
        let summary = ExportSummary.make(
            from: result(colorSpaceNotice: "Captured content was Display P3."),
            copiedReference: true, copiedImage: false, insideVault: false
        )
        #expect(summary.warning?.contains("Display P3") == true)
    }

    @Test("Byte counts are shown in units a person reads, not raw bytes")
    func byteFormatting() {
        let small = ExportSummary.byteDescription(24_000)
        let large = ExportSummary.byteDescription(5_400_000)
        #expect(!small.contains("24000"))
        #expect(large.contains("MB"))
    }
}

@Suite("Annotation tool affordances")
struct AnnotationToolAffordanceTests {

    @Test("Every tool has a distinct number shortcut matching its toolbar position")
    func shortcutsAreDistinctAndOrdered() {
        let numbers = AnnotationTool.allCases.map(\.shortcutNumber)
        #expect(numbers == Array(1...AnnotationTool.allCases.count))
        #expect(Set(numbers).count == numbers.count)
    }

    @Test("Every tool tip explains what the tool does and shows its shortcut")
    func toolTipsAreUseful() {
        for tool in AnnotationTool.allCases {
            let tip = tool.toolTip
            #expect(tip.contains(tool.displayName), "\(tool) tip should name the tool")
            #expect(tip.contains("\(tool.shortcutNumber)"), "\(tool) tip should show its shortcut")
            // A tip that only repeats the label teaches nothing; each one explains a purpose.
            #expect(tip.count > tool.displayName.count + 6)
        }
    }

    @Test("The mosaic tool is described in terms of what it is for")
    func mosaicExplainsItsPurpose() {
        #expect(AnnotationTool.mosaic.toolTip.lowercased().contains("private"))
    }
}
