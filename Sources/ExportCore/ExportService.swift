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

/// Verified animation bytes held in memory. Encoding does not imply saving a file.
public struct EncodedAnimation: Sendable {
    public let data: Data
    public let pixelSize: CGSize
    public let container: MagicBytes.Container
    public let animationInfo: WebPCodec.AnimationInfo
    public let submittedFrameCount: Int
    public let collapsedToSingleFrame: Bool
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
        colorSpaceNotice: String? = nil,
        cropRect: CGRect? = nil
    ) throws -> ExportResult {
        guard !format.isAnimated else {
            throw TriCapError.encodingFailed("Use exportAnimation for animated WebP.")
        }
        try validateCrop(cropRect, canvasSize: CGSize(width: image.width, height: image.height))

        // Annotations first, crop last: annotation coordinates are anchored to the full canvas
        // the user drew on, so cropping earlier would shift every arrow and mosaic.
        let annotated = annotations.isEmpty
            ? image
            : (AnnotationRenderer.render(items: annotations, onto: image) ?? image)
        let rendered = try cropped(annotated, to: cropRect)

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

    /// Cancellation for a background preparation encode, checked between frames.
    ///
    /// A plain `Task.cancel()` cannot do this job: the encode runs inside `Task.detached` so it
    /// stays off the main actor, and task cancellation does not propagate into an unstructured
    /// detached child — polling `Task.isCancelled` in there reads the *detached* task's flag,
    /// which nobody ever sets. The flag carries the signal by hand instead; the editor flips it
    /// when the user edits again, presses Save, or closes, and `encodeStreaming` polls it before
    /// every frame so a runaway preparation can never compete with a real export for the encoder.
    public final class PreparationCancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        public init() {}

        public func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }

        public var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }
    }

    /// Encode a particular editor state before the user presses Save.
    ///
    /// The returned artifact carries the source canvas, frame timeline, crop and immutable
    /// annotation snapshot; ``PreEncodeReuse`` only allows it through for that exact same job.
    public static func prepareAnimation(
        source: AnimationFrameSource,
        annotations: [AnnotationItem] = [],
        options: AnimatedWebPOptions,
        cropRect: CGRect?,
        isCancelled: @escaping @Sendable () -> Bool = { false },
        progress: ((Double) -> Void)? = nil
    ) throws -> PreEncodedAnimation {
        guard source.frameCount > 0 else { throw TriCapError.noFramesCaptured }
        guard source.timestampsMs.count == source.frameCount else {
            throw TriCapError.encodingFailed(
                "Timeline has \(source.timestampsMs.count) timestamps for \(source.frameCount) frames."
            )
        }
        try validateCrop(cropRect, canvasSize: source.canvasSize)
        let data = try encodeStreaming(
            source: source,
            annotations: annotations,
            options: options,
            strategy: .default,
            progress: progress,
            cropRect: cropRect,
            isCancelled: isCancelled
        )
        return PreEncodedAnimation(
            data: data,
            canvasSize: source.canvasSize,
            options: options,
            frameCount: source.frameCount,
            timestampsMs: source.timestampsMs,
            endTimestampMs: source.endTimestampMs,
            cropRect: cropRect,
            annotations: annotations
        )
    }

    private static func encodeAnimationData(
        source: AnimationFrameSource,
        annotations: [AnnotationItem],
        options: AnimatedWebPOptions,
        preEncoded: PreEncodedAnimation? = nil,
        strategy: AnimationEncodeStrategy = .default,
        progress: ((Double) -> Void)? = nil,
        cropRect: CGRect? = nil,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) throws -> Data {
        guard !isCancelled() else {
            throw TriCapError.encodingFailed("Animation preparation was cancelled.")
        }
        guard source.frameCount > 0 else { throw TriCapError.noFramesCaptured }
        guard source.timestampsMs.count == source.frameCount else {
            throw TriCapError.encodingFailed(
                "Timeline has \(source.timestampsMs.count) timestamps for \(source.frameCount) frames."
            )
        }
        try validateCrop(cropRect, canvasSize: source.canvasSize)
        // The fast path is an optimisation only: it may change how long this takes and nothing
        // else. Everything downstream — writing, re-reading, and every verification below — is
        // identical either way, so a pre-encoded file that is somehow wrong is caught by the same
        // checks that guard the ordinary path.
        let decision = PreEncodeReuse.decide(
            artifact: preEncoded,
            source: source,
            annotations: annotations,
            options: options,
            cropRect: cropRect
        )
        let data: Data
        if decision.isReuse, let preEncoded {
            data = preEncoded.data
            progress?(1)
        } else {
            data = try encodeStreaming(
                source: source, annotations: annotations, options: options,
                strategy: strategy, progress: progress, cropRect: cropRect,
                isCancelled: isCancelled
            )
        }
        TriCapLog.export.info("animation encoding: \(decision.reason, privacy: .public)")
        return data
    }

    /// Render and verify an animation without touching the filesystem.
    public static func encodeAnimation(
        source: AnimationFrameSource,
        annotations: [AnnotationItem],
        options: AnimatedWebPOptions,
        preEncoded: PreEncodedAnimation? = nil,
        strategy: AnimationEncodeStrategy = .default,
        progress: ((Double) -> Void)? = nil,
        cropRect: CGRect? = nil,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) throws -> EncodedAnimation {
        let data = try encodeAnimationData(
            source: source, annotations: annotations, options: options,
            preEncoded: preEncoded, strategy: strategy, progress: progress,
            cropRect: cropRect, isCancelled: isCancelled
        )
        return try verifyAnimation(
            data, source: source, options: options, cropRect: cropRect
        )
    }

    public static func exportAnimation(
        source: AnimationFrameSource,
        annotations: [AnnotationItem],
        options: AnimatedWebPOptions,
        directory: URL,
        baseName: String,
        vaultRoot: URL?,
        linkStyle: MarkdownLinkStyle,
        colorSpaceNotice: String? = nil,
        preEncoded: PreEncodedAnimation? = nil,
        strategy: AnimationEncodeStrategy = .default,
        progress: ((Double) -> Void)? = nil,
        cropRect: CGRect? = nil
    ) throws -> ExportResult {
        // Save verifies the re-read file once, keeping the original export tail cost.
        let data = try encodeAnimationData(
            source: source, annotations: annotations, options: options,
            preEncoded: preEncoded, strategy: strategy, progress: progress, cropRect: cropRect
        )

        let url = try OutputFileWriter.write(
            data, to: directory, baseName: baseName, fileExtension: OutputFormat.animatedWebP.fileExtension
        )

        do {
            let written = try Data(contentsOf: url, options: [.mappedIfSafe])
            let verified = try verifyAnimation(
                written, source: source, options: options, cropRect: cropRect
            )

            return ExportResult(
                url: url,
                format: .animatedWebP,
                pixelSize: verified.pixelSize,
                byteCount: written.count,
                reference: MarkdownReference.reference(for: url, vaultRoot: vaultRoot, style: linkStyle),
                container: verified.container,
                animationInfo: verified.animationInfo,
                submittedFrameCount: source.frameCount,
                collapsedToSingleFrame: verified.collapsedToSingleFrame,
                colorSpaceNotice: verified.collapsedToSingleFrame
                    ? "Nothing on screen changed during the recording, so it was saved as a single-frame WebP instead of an animation."
                    : colorSpaceNotice
            )
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    /// Both clipboard bytes and the file re-read after Save pass the same gates.
    private static func verifyAnimation(
        _ data: Data,
        source: AnimationFrameSource,
        options: AnimatedWebPOptions,
        cropRect: CGRect?
    ) throws -> EncodedAnimation {
        let outputSize = cropRect?.size ?? source.canvasSize
        let container = MagicBytes.detect(data)
        guard container == .webpAnimated || container == .webpStill else {
            throw TriCapError.encodingFailed("Encoded bytes are not WebP.")
        }
        let info = try WebPCodec.inspectAnimation(data: data)
        guard info.canvasWidth == Int(outputSize.width.rounded()),
              info.canvasHeight == Int(outputSize.height.rounded()) else {
            throw TriCapError.encodingFailed("Encoded animation has the wrong canvas size.")
        }
        // Identical consecutive frames may coalesce, while duration must stay exact.
        guard info.frameCount >= 1, info.frameCount <= source.frameCount else {
            throw TriCapError.encodingFailed("Encoded animation has an invalid frame count.")
        }
        let collapsed = info.frameCount == 1 && container == .webpStill
        if !collapsed {
            guard container == .webpAnimated else {
                throw TriCapError.encodingFailed("Expected an animated WebP.")
            }
            guard info.totalDurationMs == source.endTimestampMs else {
                throw TriCapError.encodingFailed("Encoded animation has the wrong playback duration.")
            }
            guard zip(info.frameTimestampsMs, info.frameTimestampsMs.dropFirst()).allSatisfy({ $1 > $0 }) else {
                throw TriCapError.encodingFailed("Encoded animation has non-increasing frame timestamps.")
            }
            guard info.loopCount == options.loopCount else {
                throw TriCapError.encodingFailed("Encoded animation has the wrong loop count.")
            }
        }
        return EncodedAnimation(
            data: data, pixelSize: outputSize, container: container,
            animationInfo: info, submittedFrameCount: source.frameCount,
            collapsedToSingleFrame: collapsed
        )
    }

    /// Pull each frame, composite the fixed annotation overlay onto it, crop, hand it to libwebp,
    /// drop it. Annotations before crop, always: their coordinates are anchored to the full
    /// canvas the user drew on.
    private static func encodeStreaming(
        source: AnimationFrameSource,
        annotations: [AnnotationItem],
        options: AnimatedWebPOptions,
        strategy: AnimationEncodeStrategy,
        progress: ((Double) -> Void)?,
        cropRect: CGRect? = nil,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) throws -> Data {
        try WebPCodec.encodeAnimationStreaming(
            frameCount: source.frameCount,
            canvasSize: cropRect?.size ?? source.canvasSize,
            endTimestampMs: source.endTimestampMs,
            options: options,
            strategy: strategy,
            progress: progress
        ) { index in
            guard !isCancelled() else {
                throw TriCapError.encodingFailed("Animation preparation was cancelled.")
            }
            let raw = try source.loadFrame(index)
            let composited: CGImage
            if annotations.isEmpty {
                composited = raw
            } else {
                composited = AnnotationRenderer.render(items: annotations, onto: raw) ?? raw
            }
            return (try cropped(composited, to: cropRect), source.timestampsMs[index])
        }
    }

    /// The one crop gate for stills and animations alike, run against the true source canvas
    /// before any encoding or writing.
    ///
    /// This cannot be left to `CGImage.cropping(to:)`: probed on this system, it silently rounds
    /// and clips instead of failing — x=0.5, w=5.25 became a 6×5 image; x=8, w=5 on a 10-wide
    /// image became 2×5; x=-2, w=5 became 3×5. A crop the editor never produced must be an
    /// error, not a slightly different file.
    private static func validateCrop(_ cropRect: CGRect?, canvasSize: CGSize) throws {
        guard let cropRect else { return }
        guard CropGeometry.isValid(cropRect, canvasSize: canvasSize) else {
            throw TriCapError.encodingFailed(
                "Crop \(cropRect) is not an integral rect inside the \(Int(canvasSize.width))×\(Int(canvasSize.height)) canvas."
            )
        }
    }

    /// Cut `rect` out of `image` in row space — the same space annotations live in, so the rect
    /// needs no flip (the lesson the mosaic's mirrored-band defect taught).
    private static func cropped(_ image: CGImage, to rect: CGRect?) throws -> CGImage {
        guard let rect else { return image }
        guard let cut = image.cropping(to: rect) else {
            throw TriCapError.encodingFailed(
                "Crop \(rect) produced no pixels from a \(image.width)×\(image.height) frame."
            )
        }
        return cut
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
