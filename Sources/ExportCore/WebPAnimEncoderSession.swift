import CWebP
import CoreGraphics
import Foundation
import TriCapKit

/// A `WebPAnimEncoder` that stays alive across many `add` calls, so frames can be encoded while
/// they are still arriving instead of all at once after the user clicks Export.
///
/// `WebPCodec.encodeAnimationStreaming` owns its encoder for the duration of one call, which is
/// right for the editor's path — trim, annotate, re-render — but means the entire encode happens
/// after recording ends. On a genuinely high-motion clip almost nothing coalesces, so that tail is
/// proportional to the recording length and the user waits through it twice: once recording, once
/// encoding.
///
/// # Thread safety
///
/// **None.** libwebp's encoder is not re-entrant and this type does no locking. Every call must
/// come from one serial execution context; `CaptureCore.LivePreEncoder` is what provides that, and
/// it is the only thing that should construct this. In particular it must never be driven from a
/// ScreenCaptureKit sample callback: encoding a 1440×900 frame takes far longer than the interval
/// between frames, and blocking that queue drops captures.
public final class WebPAnimEncoderSession: @unchecked Sendable {

    /// The parameters this session was built with. Reusing its output later is only legitimate if
    /// these still match what the export is asking for — see ``PreEncodedAnimation``.
    public let canvasSize: CGSize
    public let options: AnimatedWebPOptions
    public let strategy: AnimationEncodeStrategy

    private var encoder: OpaquePointer?
    private var config = WebPConfig()
    private var previousTimestampMs = Int.min
    private var addedFrames = 0
    private var timestamps: [Int] = []
    private var finished = false

    public private(set) var failure: String?

    public init(
        canvasSize: CGSize,
        options: AnimatedWebPOptions,
        strategy: AnimationEncodeStrategy = .default
    ) throws {
        self.canvasSize = canvasSize
        self.options = options
        self.strategy = strategy

        let width = Int32(canvasSize.width.rounded())
        let height = Int32(canvasSize.height.rounded())
        guard width > 0, height > 0 else {
            throw TriCapError.encodingFailed("Animation canvas is empty.")
        }

        var encoderOptions = WebPAnimEncoderOptions()
        guard WebPAnimEncoderOptionsInit(&encoderOptions) != 0 else {
            throw TriCapError.encodingFailed("WebPAnimEncoderOptionsInit failed (libwebp ABI mismatch).")
        }
        // Identical to `encodeAnimationStreaming`, deliberately: the two paths must produce the
        // same file for the same frames, or the fast path would silently change output.
        encoderOptions.anim_params.loop_count = Int32(options.loopCount)
        encoderOptions.anim_params.bgcolor = 0xFFFFFFFF
        encoderOptions.minimize_size = strategy.minimizeSize ? 1 : 0
        encoderOptions.allow_mixed = (strategy.allowMixed && !options.lossless) ? 1 : 0

        guard let created = WebPAnimEncoderNew(width, height, &encoderOptions) else {
            throw TriCapError.encodingFailed("WebPAnimEncoderNew failed (canvas too large?).")
        }
        encoder = created

        guard WebPConfigInit(&config) != 0 else {
            WebPAnimEncoderDelete(created)
            encoder = nil
            throw TriCapError.encodingFailed("WebPConfigInit failed (libwebp ABI mismatch).")
        }
        do {
            try WebPCodec.configure(
                &config, quality: options.quality, lossless: options.lossless, method: options.method
            )
        } catch {
            WebPAnimEncoderDelete(created)
            encoder = nil
            throw error
        }
    }

    deinit {
        if let encoder { WebPAnimEncoderDelete(encoder) }
    }

    public var frameCount: Int { addedFrames }
    public var acceptedTimestampsMs: [Int] { timestamps }
    public var isUsable: Bool { encoder != nil && failure == nil && !finished }

    /// Encode one frame into the running animation.
    ///
    /// Records the first failure and refuses further work rather than throwing repeatedly: the
    /// caller is a background pre-encoder whose only correct response to any failure is to give up
    /// the fast path and let the ordinary export run.
    @discardableResult
    public func add(image: CGImage, timestampMs: Int) -> Bool {
        guard let encoder, failure == nil, !finished else { return false }

        let width = Int(canvasSize.width.rounded())
        let height = Int(canvasSize.height.rounded())
        guard image.width == width, image.height == height else {
            failure = "Frame \(addedFrames) is \(image.width)×\(image.height) but the canvas is \(width)×\(height)."
            return false
        }
        guard timestampMs > previousTimestampMs else {
            failure = "Frame timestamps are not strictly increasing (\(timestampMs) after \(previousTimestampMs))."
            return false
        }
        guard let raster = ImageProcessing.rgbxBytes(image) else {
            failure = "Could not read pixels for frame \(addedFrames)."
            return false
        }

        var picture = WebPPicture()
        guard WebPPictureInit(&picture) != 0 else {
            failure = "WebPPictureInit failed (libwebp ABI mismatch)."
            return false
        }
        picture.use_argb = 1
        picture.width = Int32(width)
        picture.height = Int32(height)

        let imported = raster.bytes.withUnsafeBufferPointer { buffer in
            WebPPictureImportRGBX(&picture, buffer.baseAddress, Int32(raster.stride))
        }
        guard imported != 0 else {
            WebPPictureFree(&picture)
            failure = "WebPPictureImportRGBX failed for frame \(addedFrames)."
            return false
        }

        let added = WebPAnimEncoderAdd(encoder, &picture, Int32(timestampMs), &config)
        WebPPictureFree(&picture)
        guard added != 0 else {
            failure = "WebPAnimEncoderAdd failed at frame \(addedFrames)."
            return false
        }

        previousTimestampMs = timestampMs
        timestamps.append(timestampMs)
        addedFrames += 1
        return true
    }

    /// Flush the last frame's duration and assemble the file.
    ///
    /// Returns `nil` — rather than throwing — for every failure, for the same reason ``add`` does:
    /// there is always a working fallback, so a pre-encode failure is not an error the user needs
    /// to see. The encoder is released either way.
    public func finish(endTimestampMs: Int) -> Data? {
        defer { release() }
        guard let encoder, failure == nil, !finished, addedFrames > 0 else { return nil }
        finished = true

        guard endTimestampMs > previousTimestampMs else {
            failure = "End timestamp \(endTimestampMs) is not after the last frame at \(previousTimestampMs)."
            return nil
        }
        guard WebPAnimEncoderAdd(encoder, nil, Int32(endTimestampMs), nil) != 0 else {
            failure = "WebPAnimEncoderAdd(NULL) failed."
            return nil
        }

        var webpData = WebPData()
        WebPDataInit(&webpData)
        defer { WebPDataClear(&webpData) }

        guard WebPAnimEncoderAssemble(encoder, &webpData) != 0,
              let bytes = webpData.bytes, webpData.size > 0 else {
            failure = "WebPAnimEncoderAssemble failed."
            return nil
        }
        return Data(bytes: bytes, count: webpData.size)
    }

    /// Drop the encoder and everything it holds. Idempotent, and safe to call after ``finish``.
    public func release() {
        if let encoder {
            WebPAnimEncoderDelete(encoder)
            self.encoder = nil
        }
    }
}
