import Foundation
import TriCapKit

/// What the user is told after a successful save.
///
/// Pulled out of the presentation layer so the wording — which is the whole point of the feature —
/// can be asserted in tests rather than eyeballed in a screenshot.
public struct ExportSummary: Equatable, Sendable {
    /// `TriCap-2026-08-03-141530.webp`
    public let fileName: String
    /// The folder, abbreviated with `~`.
    public let folderDisplayPath: String
    /// `1.2 MB`
    public let sizeDescription: String
    /// `1440 × 900 · Animated WebP · 52 frames · 4.7 s`
    public let detailDescription: String
    /// What landed on the clipboard, in the user's terms. `nil` when nothing was copied.
    public let clipboardDescription: String?
    /// Non-nil when something about the export deserves a warning rather than a tick.
    public let warning: String?

    public init(
        fileName: String,
        folderDisplayPath: String,
        sizeDescription: String,
        detailDescription: String,
        clipboardDescription: String?,
        warning: String?
    ) {
        self.fileName = fileName
        self.folderDisplayPath = folderDisplayPath
        self.sizeDescription = sizeDescription
        self.detailDescription = detailDescription
        self.clipboardDescription = clipboardDescription
        self.warning = warning
    }

    /// Build the summary from a finished export plus what the clipboard settings did.
    ///
    /// `copiedReference` / `copiedImage` describe what actually happened, not what the settings
    /// say, so the toast can never claim a copy that did not take place.
    public static func make(
        from result: ExportResult,
        copiedReference: Bool,
        copiedImage: Bool,
        insideVault: Bool
    ) -> ExportSummary {
        ExportSummary(
            fileName: result.url.lastPathComponent,
            folderDisplayPath: (result.url.deletingLastPathComponent().path as NSString)
                .abbreviatingWithTildeInPath,
            sizeDescription: byteDescription(result.byteCount),
            detailDescription: detail(for: result),
            clipboardDescription: clipboardDescription(
                copiedReference: copiedReference,
                copiedImage: copiedImage,
                insideVault: insideVault
            ),
            warning: result.collapsedToSingleFrame
                ? "Nothing moved during the recording, so this is a single-frame WebP."
                : result.colorSpaceNotice
        )
    }

    static func detail(for result: ExportResult) -> String {
        var parts = [
            "\(Int(result.pixelSize.width)) × \(Int(result.pixelSize.height))",
            result.format.displayName,
        ]
        if let info = result.animationInfo, !result.collapsedToSingleFrame {
            parts.append("\(info.frameCount) frames")
            parts.append(String(format: "%.1f s", Double(info.totalDurationMs) / 1000.0))
        }
        return parts.joined(separator: " · ")
    }

    /// Says *what kind* of thing was copied, because "copied to clipboard" does not tell the user
    /// whether they are about to paste an image, a Markdown embed, or a bare file path.
    static func clipboardDescription(
        copiedReference: Bool,
        copiedImage: Bool,
        insideVault: Bool
    ) -> String? {
        let referenceKind = insideVault ? "Markdown reference" : "file path"
        switch (copiedReference, copiedImage) {
        case (true, true):
            return "Copied the image and the \(referenceKind)"
        case (true, false):
            return "Copied the \(referenceKind)"
        case (false, true):
            return "Copied the image"
        case (false, false):
            return nil
        }
    }

    static func byteDescription(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}
