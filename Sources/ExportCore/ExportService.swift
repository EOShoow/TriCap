import AnnotationCore
import CoreGraphics
import Foundation
import TriCapKit

/// What an export produced, including the facts TriCap verified after writing.
public struct ExportResult: Sendable, Equatable {
    public let url: URL
    public let format: OutputFormat
    public let pixelSize: CGSize
    public let byteCount: Int
    /// Clipboard payload: a relative Markdown reference inside the vault, otherwise the file path.
    public let reference: String
    /// Container actually detected in the written bytes.
    public let container: MagicBytes.Container
    /// Present for animated WebP: what the demuxer read back out of the finished file.
    public let animationInfo: WebPCodec.AnimationInfo?
    /// Frames handed to the encoder. May exceed `animationInfo.frameCount`: libwebp coalesces a
    /// frame that is byte-identical to its predecessor into a longer display duration for the
    /// earlier frame, which shortens the file without changing playback.
    public let submittedFrameCount: Int?
    /// `true` when *every* submitted frame was identical, so libwebp emitted a single-frame still
    /// WebP rather than an animation. The file is valid and TriCap keeps it, but the user is told
    /// that nothing moved instead of being handed a "clip" that does not move.
    public let collapsedToSingleFrame: Bool
    /// Non-nil when the source colour space could not be represented losslessly in sRGB.
    public let colorSpaceNotice: String?
}

/// Lazily supplies annotated frames to the animated encoder.
///
/// Frames are pulled one at a time rather than handed over as an array: a 15 s clip at 1440 px
/// would be roughly a gigabyte of decoded bitmaps held simultaneously, whereas this keeps peak
/// usage at one decoded frame plus libwebp's own canvas.
public struct AnimationFrameSource: @unchecked Sendable {
    public let frameCount: Int
    /// Strictly increasing absolute timestamps in milliseconds, starting at 0.
    public let timestampsMs: [Int]
    public let endTimestampMs: Int
    public let canvasSize: CGSize
    /// Decode frame `index` at `canvasSize`. Called exactly once per frame, in order.
    public let loadFrame: (Int) throws -> CGImage

    public init(
        frameCount: Int,
        timestampsMs: [Int],
        endTimestampMs: Int,
        canvasSize: CGSize,
        loadFrame: @escaping (Int) throws -> CGImage
    ) {
        self.frameCount = frameCount
        self.timestampsMs = timestampsMs
        self.endTimestampMs = endTimestampMs
        self.canvasSize = canvasSize
        self.loadFrame = loadFrame
    }
}

/// Renders, encodes, writes and then *verifies* an export.
public enum ExportService {

    // MARK: - Stills

    public static func exportStill(
        image: CGImage,
        annotations: [AnnotationItem],
        format: OutputFormat,
        quality: Int,
        directory: URL,
        baseName: String,
        vaultRoot: URL?,
        linkStyle: MarkdownLinkStyle,
        colorSpaceNotice: String? = nil
    ) throws -> ExportResult {
        guard !format.isAnimated else {
            throw TriCapError.encodingFailed("Use exportAnimation for animated WebP.")
        }

        let rendered = annotations.isEmpty
            ? image
            : (AnnotationRenderer.render(items: annotations, onto: image) ?? image)

        let data = try StillImageCodec.encode(rendered, format: format, quality: quality)
        let url = try OutputFileWriter.write(
            data, to: directory, baseName: baseName, fileExtension: format.fileExtension
        )

        do {
            let container = try verifyContainer(at: url, expected: format)
            return ExportResult(
                url: url,
                format: format,
                pixelSize: CGSize(width: rendered.width, height: rendered.height),
                byteCount: data.count,
                reference: MarkdownReference.reference(for: url, vaultRoot: vaultRoot, style: linkStyle),
                container: container,
                animationInfo: nil,
                submittedFrameCount: nil,
                collapsedToSingleFrame: false,
                colorSpaceNotice: colorSpaceNotice
            )
        } catch {
            // A file that failed verification is worse than no file: remove it rather than
            // leaving something the user will paste into a note and discover is broken later.
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    // MARK: - Animation

    public static func exportAnimation(
        source: AnimationFrameSource,
        annotations: [AnnotationItem],
        options: AnimatedWebPOptions,
        directory: URL,
        baseName: String,
        vaultRoot: URL?,
        linkStyle: MarkdownLinkStyle,
        colorSpaceNotice: String? = nil,
        progress: ((Double) -> Void)? = nil
    ) throws -> ExportResult {
        guard source.frameCount > 0 else { throw TriCapError.noFramesCaptured }
        guard source.timestampsMs.count == source.frameCount else {
            throw TriCapError.encodingFailed(
                "Timeline has \(source.timestampsMs.count) timestamps for \(source.frameCount) frames."
            )
        }

        let data = try encodeStreaming(source: source, annotations: annotations, options: options, progress: progress)

        let url = try OutputFileWriter.write(
            data, to: directory, baseName: baseName, fileExtension: OutputFormat.animatedWebP.fileExtension
        )

        do {
            let container = try MagicBytes.detect(fileAt: url)
            guard container == .webpAnimated || container == .webpStill else {
                throw TriCapError.encodingFailed(
                    "Wrote \(url.lastPathComponent) but its bytes look like \(container.rawValue), not WebP."
                )
            }
            let written = try Data(contentsOf: url, options: [.mappedIfSafe])
            let info = try WebPCodec.inspectAnimation(data: written)

            guard info.canvasWidth == Int(source.canvasSize.width.rounded()),
                  info.canvasHeight == Int(source.canvasSize.height.rounded()) else {
                throw TriCapError.encodingFailed(
                    "Written animation is \(info.canvasWidth)x\(info.canvasHeight) but should be \(Int(source.canvasSize.width))x\(Int(source.canvasSize.height))."
                )
            }
            // libwebp merges a frame that is identical to its predecessor into that frame's
            // duration, so the stored count can legitimately be lower than the submitted count —
            // but never higher, and never zero.
            guard info.frameCount >= 1, info.frameCount <= source.frameCount else {
                throw TriCapError.encodingFailed(
                    "Written animation has \(info.frameCount) frames, which is not between 1 and the \(source.frameCount) submitted."
                )
            }

            // When *nothing* changed for the whole recording, every frame merges into one and
            // libwebp writes a plain still WebP with no ANIM chunk (hence loop count 1 and a zero
            // duration). That file is correct, so it is kept — but it is reported rather than
            // dressed up as an animation.
            let collapsed = info.frameCount == 1 && container == .webpStill
            if !collapsed {
                guard container == .webpAnimated else {
                    throw TriCapError.encodingFailed(
                        "Expected an animated WebP but the written file is \(container.rawValue)."
                    )
                }
                // Playback length is the invariant that must survive frame coalescing exactly.
                guard info.totalDurationMs == source.endTimestampMs else {
                    throw TriCapError.encodingFailed(
                        "Written animation runs \(info.totalDurationMs) ms but should run \(source.endTimestampMs) ms."
                    )
                }
                guard zip(info.frameTimestampsMs, info.frameTimestampsMs.dropFirst()).allSatisfy({ $1 > $0 }) else {
                    throw TriCapError.encodingFailed("Written animation has non-increasing frame timestamps.")
                }
                guard info.loopCount == options.loopCount else {
                    throw TriCapError.encodingFailed(
                        "Written animation loops \(info.loopCount) times but \(options.loopCount) was requested."
                    )
                }
            }

            return ExportResult(
                url: url,
                format: .animatedWebP,
                pixelSize: source.canvasSize,
                byteCount: data.count,
                reference: MarkdownReference.reference(for: url, vaultRoot: vaultRoot, style: linkStyle),
                container: container,
                animationInfo: info,
                submittedFrameCount: source.frameCount,
                collapsedToSingleFrame: collapsed,
                colorSpaceNotice: collapsed
                    ? "Nothing on screen changed during the recording, so it was saved as a single-frame WebP instead of an animation."
                    : colorSpaceNotice
            )
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    /// Pull each frame, composite the fixed annotation overlay onto it, hand it to libwebp, drop it.
    private static func encodeStreaming(
        source: AnimationFrameSource,
        annotations: [AnnotationItem],
        options: AnimatedWebPOptions,
        progress: ((Double) -> Void)?
    ) throws -> Data {
        try WebPCodec.encodeAnimationStreaming(
            frameCount: source.frameCount,
            canvasSize: source.canvasSize,
            endTimestampMs: source.endTimestampMs,
            options: options,
            progress: progress
        ) { index in
            let raw = try source.loadFrame(index)
            let composited: CGImage
            if annotations.isEmpty {
                composited = raw
            } else {
                composited = AnnotationRenderer.render(items: annotations, onto: raw) ?? raw
            }
            return (composited, source.timestampsMs[index])
        }
    }

    // MARK: - Verification

    /// Re-read the written file and confirm the container matches the extension we chose.
    @discardableResult
    static func verifyContainer(at url: URL, expected: OutputFormat) throws -> MagicBytes.Container {
        let detected = try MagicBytes.detect(fileAt: url)
        let extensionMatches = detected.matchesExtension == expected.fileExtension
        let animationMatches: Bool
        switch expected {
        case .animatedWebP: animationMatches = detected == .webpAnimated
        case .webp: animationMatches = detected == .webpStill || detected == .webpAnimated
        default: animationMatches = true
        }
        guard extensionMatches, animationMatches else {
            throw TriCapError.encodingFailed(
                "Wrote \(url.lastPathComponent) but its bytes look like \(detected.rawValue), not \(expected.displayName)."
            )
        }
        return detected
    }
}
