import AnnotationCore
import AppKit
import CaptureCore
import CoreGraphics
import ExportCore
import Foundation
import SwiftUI
import TriCapKit

/// What the editor is editing.
public enum EditorSource {
    case still(CapturedStill)
    case clip(RecordedClip)

    var isClip: Bool { if case .clip = self { return true }; return false }
}

/// State behind the annotation editor window.
///
/// Annotations live in *canvas pixel* coordinates (top-left origin), which for a clip is the
/// recorded frame size. Because every frame of a clip shares that size, the same annotation list
/// composites onto all of them as a fixed overlay — that is the whole reason the editor never
/// stores per-frame annotations.
@MainActor
public final class EditorModel: ObservableObject {

    public let source: EditorSource
    public let canvasSize: CGSize

    @Published public var document = AnnotationDocument()
    @Published public var tool: AnnotationTool = .arrow
    @Published public var style = AnnotationStyle()
    @Published public var format: OutputFormat

    /// Inclusive trim handles, in original frame indices.
    @Published public var trimStart = 0
    @Published public var trimEnd = 0
    /// Which frame the canvas is currently showing.
    @Published public var previewIndex = 0

    @Published public var isExporting = false
    @Published public var exportProgress: Double = 0
    @Published public var statusMessage: String?
    @Published public var errorMessage: String?

    /// Set when the capture's colour space could not be represented losslessly in sRGB.
    public let colorSpaceNotice: String?
    /// Set when a recording was cut short by one of the configured limits.
    public let truncationNotice: String?

    private let settings: AppSettings
    private var frameCache: (index: Int, image: CGImage)?
    private let onExported: (ExportResult) -> Void
    private let onClosed: () -> Void

    public init(
        source: EditorSource,
        settings: AppSettings,
        onExported: @escaping (ExportResult) -> Void,
        onClosed: @escaping () -> Void
    ) {
        self.source = source
        self.settings = settings
        self.onExported = onExported
        self.onClosed = onClosed
        self.style = AnnotationStyle()

        switch source {
        case .still(let still):
            canvasSize = still.pixelSize
            format = settings.stillFormat == .animatedWebP ? .png : settings.stillFormat
            colorSpaceNotice = still.colorSpace.userFacingNotice
            truncationNotice = nil
        case .clip(let clip):
            canvasSize = clip.pixelSize
            format = .animatedWebP
            trimEnd = max(0, clip.frames.count - 1)
            colorSpaceNotice = clip.colorSpaceNotice
            truncationNotice = Self.truncationNotice(for: clip)
        }

        // Annotation defaults scale with the canvas so a 400 px capture and a 2800 px capture
        // both get a sensibly-sized arrow.
        let scale = max(1.0, min(canvasSize.width, canvasSize.height) / 400.0)
        style.lineWidth = (4 * scale).rounded()
        style.fontSize = (24 * scale).rounded()
        style.mosaicBlockSize = (12 * scale).rounded()
    }

    private static func truncationNotice(for clip: RecordedClip) -> String? {
        switch clip.stopReason {
        case .durationLimit:
            return "Recording stopped at the \(Int(clip.duration.rounded())) s duration limit."
        case .frameCountLimit:
            return "Recording stopped at the frame-count limit (\(clip.frames.count) frames)."
        case .memoryLimit:
            return "Recording stopped at the memory limit (\(clip.retainedBytes / 1_048_576) MB of frames)."
        case .streamError:
            return "The capture stream ended early; the frames recorded so far were kept."
        case .userStopped, .cancelled:
            return nil
        }
    }

    // MARK: - Clip helpers

    public var frameCount: Int {
        if case .clip(let clip) = source { return clip.frames.count }
        return 1
    }

    public var trimmedFrameCount: Int { max(0, trimEnd - trimStart + 1) }

    /// A one-frame clip has no trim handles and no scrub positions.
    public var isTrimmable: Bool { ClipTrimUI.isTrimmable(frameCount: frameCount) }

    /// Range for the Start/End handles. Only read when ``isTrimmable``.
    public var trimHandleRange: ClosedRange<Double> {
        ClipTrimUI.handleRange(frameCount: frameCount) ?? 0...0
    }

    /// Range for the preview scrubber, always inside the current trim.
    public var previewScrubRange: ClosedRange<Double> {
        ClipTrimUI.scrubRange(trimStart: trimStart, trimEnd: trimEnd) ?? Double(trimStart)...Double(trimStart)
    }

    /// Length the trimmed clip will actually play for.
    ///
    /// Uses the same rule as the exporter (``ClipTrimmer/trimmedDuration(frames:range:clipDuration:)``):
    /// keeping the tail keeps the recording's real end time, so a final frame that sat unchanged
    /// for ten seconds is reported — and exported — as ten seconds, not as one frame interval.
    public var trimmedDuration: TimeInterval {
        guard case .clip(let clip) = source, !clip.frames.isEmpty,
              let range = ClipTrimmer.normalizedRange(first: trimStart, last: trimEnd, count: clip.frames.count)
        else { return 0 }
        return ClipTrimmer.trimmedDuration(frames: clip.frames, range: range, clipDuration: clip.duration)
    }

    /// The image drawn underneath the annotations right now.
    public func currentBaseImage() -> CGImage? {
        switch source {
        case .still(let still):
            return still.image
        case .clip(let clip):
            guard !clip.frames.isEmpty else { return nil }
            let index = previewIndex.clamped(to: 0...(clip.frames.count - 1))
            if let cached = frameCache, cached.index == index { return cached.image }
            guard let image = clip.frames[index].decodedImage() else { return nil }
            frameCache = (index, image)
            return image
        }
    }

    /// Keep the preview inside the trim handles as the user drags them.
    public func clampPreviewToTrim() {
        if previewIndex < trimStart { previewIndex = trimStart }
        if previewIndex > trimEnd { previewIndex = trimEnd }
    }

    // MARK: - Editing

    public func add(_ item: AnnotationItem) {
        document.add(item)
    }

    public func undo() { document.undo() }
    public func redo() { document.redo() }
    public func clearAnnotations() { document.clear() }

    // MARK: - Export

    public func export() {
        guard !isExporting else { return }
        isExporting = true
        exportProgress = 0
        errorMessage = nil
        statusMessage = nil

        let settings = self.settings
        let annotations = document.items
        let baseName = OutputFileWriter.baseName(prefix: settings.filenamePrefix, date: Date())

        switch source {
        case .still(let still):
            let image = still.image
            let format = self.format
            let notice = colorSpaceNotice
            Task.detached(priority: .userInitiated) {
                do {
                    let result = try ExportService.exportStill(
                        image: image,
                        annotations: annotations,
                        format: format,
                        quality: settings.stillQuality,
                        directory: settings.saveDirectoryURL,
                        baseName: baseName,
                        vaultRoot: settings.markdownVaultRootURL,
                        linkStyle: settings.markdownLinkStyle,
                        colorSpaceNotice: notice
                    )
                    await self.finishExport(.success(result))
                } catch {
                    await self.finishExport(.failure(error))
                }
            }

        case .clip(let clip):
            let range = ClipTrimmer.normalizedRange(first: trimStart, last: trimEnd, count: clip.frames.count) ?? 0...0
            let trimmed = ClipTrimmer.trim(frames: clip.frames, to: range)
            let trimmedSpan = ClipTrimmer.trimmedDuration(
                frames: clip.frames, range: range, clipDuration: clip.duration
            )
            guard let timeline = ClipTiming.timeline(
                for: trimmed,
                nominalFrameInterval: clip.nominalFrameInterval,
                totalDuration: trimmedSpan
            ) else {
                isExporting = false
                errorMessage = TriCapError.noFramesCaptured.localizedDescription
                return
            }

            let canvasSize = self.canvasSize
            let options = settings.animatedWebPOptions
            let notice = colorSpaceNotice

            let source = AnimationFrameSource(
                frameCount: trimmed.count,
                timestampsMs: timeline.timestampsMs,
                endTimestampMs: timeline.endTimestampMs,
                canvasSize: canvasSize
            ) { index in
                guard let image = trimmed[index].decodedImage() else {
                    throw TriCapError.encodingFailed("Frame \(index) could not be decoded.")
                }
                return image
            }

            Task.detached(priority: .userInitiated) {
                do {
                    let result = try ExportService.exportAnimation(
                        source: source,
                        annotations: annotations,
                        options: options,
                        directory: settings.saveDirectoryURL,
                        baseName: baseName,
                        vaultRoot: settings.markdownVaultRootURL,
                        linkStyle: settings.markdownLinkStyle,
                        colorSpaceNotice: notice,
                        progress: { value in
                            Task { @MainActor in self.exportProgress = value }
                        }
                    )
                    await self.finishExport(.success(result))
                } catch {
                    await self.finishExport(.failure(error))
                }
            }
        }
    }

    private func finishExport(_ outcome: Result<ExportResult, Error>) {
        isExporting = false
        switch outcome {
        case .success(let result):
            var message = "Saved \(result.url.lastPathComponent)"
            if let info = result.animationInfo, let submitted = result.submittedFrameCount {
                message += " — \(info.frameCount) of \(submitted) frames stored, \(info.totalDurationMs) ms"
            }
            if result.collapsedToSingleFrame {
                message += ". Nothing moved during the recording, so this is a single-frame WebP."
            }
            statusMessage = message
            onExported(result)
            TriCapLog.export.info(
                "exported \(result.url.lastPathComponent, privacy: .public) \(result.byteCount, privacy: .public) bytes"
            )
        case .failure(let error):
            errorMessage = (error as? TriCapError)?.localizedDescription ?? error.localizedDescription
            TriCapLog.export.error("export failed: \(String(describing: error), privacy: .public)")
        }
    }

    public func close() { onClosed() }
}
