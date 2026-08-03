import CWebP
import CoreGraphics
import Foundation
import TriCapKit

/// Thin, memory-safe Swift bridge over the vendored libwebp encoder and demuxer.
///
/// Everything libwebp allocates is released on every path (including error paths) via `defer`.
/// The `WebPPicture` import always uses `RGBX`, matching `ImageProcessing`'s canonical opaque
/// layout — importing `RGBA` from that buffer would read the unused X byte as alpha and produce
/// a fully transparent file.
public enum WebPCodec {

    /// libwebp version as (major, minor, patch), read from the linked-in library at runtime.
    public static var encoderVersion: (Int, Int, Int) { decompose(Int(WebPGetEncoderVersion())) }
    public static var muxVersion: (Int, Int, Int) { decompose(Int(WebPGetMuxVersion())) }
    public static var demuxVersion: (Int, Int, Int) { decompose(Int(WebPGetDemuxVersion())) }

    public static var versionString: String {
        let v = encoderVersion
        return "\(v.0).\(v.1).\(v.2)"
    }

    private static func decompose(_ packed: Int) -> (Int, Int, Int) {
        ((packed >> 16) & 0xFF, (packed >> 8) & 0xFF, packed & 0xFF)
    }

    // MARK: - Still

    /// Encode a single image as a static WebP.
    public static func encodeStill(_ image: CGImage, quality: Int, lossless: Bool = false, method: Int = 4) throws -> Data {
        guard let raster = ImageProcessing.rgbxBytes(image) else {
            throw TriCapError.encodingFailed("Could not read pixels for WebP encoding.")
        }

        var config = WebPConfig()
        guard WebPConfigInit(&config) != 0 else {
            throw TriCapError.encodingFailed("WebPConfigInit failed (libwebp ABI mismatch).")
        }
        try configure(&config, quality: quality, lossless: lossless, method: method)

        var picture = WebPPicture()
        guard WebPPictureInit(&picture) != 0 else {
            throw TriCapError.encodingFailed("WebPPictureInit failed (libwebp ABI mismatch).")
        }
        defer { WebPPictureFree(&picture) }

        picture.use_argb = 1
        picture.width = Int32(raster.width)
        picture.height = Int32(raster.height)

        let imported = raster.bytes.withUnsafeBufferPointer { buffer in
            WebPPictureImportRGBX(&picture, buffer.baseAddress, Int32(raster.stride))
        }
        guard imported != 0 else {
            throw TriCapError.encodingFailed("WebPPictureImportRGBX failed (out of memory?).")
        }

        var writer = WebPMemoryWriter()
        WebPMemoryWriterInit(&writer)
        defer { WebPMemoryWriterClear(&writer) }

        // The writer pointer must not escape the `withUnsafeMutablePointer` body, so the whole
        // encode happens inside it rather than stashing the pointer in `picture.custom_ptr` and
        // calling `WebPEncode` afterwards (which would be undefined behaviour).
        let encoded: Int32 = withUnsafeMutablePointer(to: &writer) { writerPointer in
            picture.writer = WebPMemoryWrite
            picture.custom_ptr = UnsafeMutableRawPointer(writerPointer)
            return WebPEncode(&config, &picture)
        }
        guard encoded != 0 else {
            throw TriCapError.encodingFailed("WebPEncode failed: \(errorName(picture.error_code))")
        }
        guard let mem = writer.mem, writer.size > 0 else {
            throw TriCapError.encodingFailed("WebPEncode produced no output.")
        }
        return Data(bytes: mem, count: writer.size)
    }

    // MARK: - Animation

    /// One frame handed to the animated encoder.
    public struct AnimationFrame {
        public let image: CGImage
        /// Absolute presentation timestamp in milliseconds; must be strictly increasing.
        public let timestampMs: Int

        public init(image: CGImage, timestampMs: Int) {
            self.image = image
            self.timestampMs = timestampMs
        }
    }

    /// Encode an animated WebP.
    ///
    /// - Parameters:
    ///   - frames: strictly-increasing timestamps starting at 0. All frames must share `canvasSize`.
    ///   - endTimestampMs: when the last frame stops being shown; must exceed the last timestamp.
    ///   - options: quality / loop count / method.
    ///   - progress: called with `0...1` after each frame so a long encode can show progress.
    public static func encodeAnimation(
        frames: [AnimationFrame],
        canvasSize: CGSize,
        endTimestampMs: Int,
        options: AnimatedWebPOptions,
        progress: ((Double) -> Void)? = nil
    ) throws -> Data {
        try encodeAnimationStreaming(
            frameCount: frames.count,
            canvasSize: canvasSize,
            endTimestampMs: endTimestampMs,
            options: options,
            progress: progress
        ) { index in
            (frames[index].image, frames[index].timestampMs)
        }
    }

    /// Streaming variant: frames are pulled one at a time so only a single decoded bitmap is
    /// alive at once. This is what the recording path uses; a 15 s clip at 1440 px would
    /// otherwise need roughly a gigabyte of simultaneously-decoded frames.
    ///
    /// - Parameter nextFrame: returns `(image, absoluteTimestampMs)` for the given index.
    ///   Called exactly once per index, in ascending order.
    public static func encodeAnimationStreaming(
        frameCount: Int,
        canvasSize: CGSize,
        endTimestampMs: Int,
        options: AnimatedWebPOptions,
        strategy: AnimationEncodeStrategy = .default,
        progress: ((Double) -> Void)? = nil,
        nextFrame: (Int) throws -> (image: CGImage, timestampMs: Int)
    ) throws -> Data {
        guard frameCount > 0 else { throw TriCapError.noFramesCaptured }

        let width = Int32(canvasSize.width.rounded())
        let height = Int32(canvasSize.height.rounded())
        guard width > 0, height > 0 else {
            throw TriCapError.encodingFailed("Animation canvas is empty.")
        }

        var encoderOptions = WebPAnimEncoderOptions()
        guard WebPAnimEncoderOptionsInit(&encoderOptions) != 0 else {
            throw TriCapError.encodingFailed("WebPAnimEncoderOptionsInit failed (libwebp ABI mismatch).")
        }
        encoderOptions.anim_params.loop_count = Int32(options.loopCount)  // 0 == loop forever
        encoderOptions.anim_params.bgcolor = 0xFFFFFFFF
        encoderOptions.minimize_size = strategy.minimizeSize ? 1 : 0
        encoderOptions.allow_mixed = (strategy.allowMixed && !options.lossless) ? 1 : 0

        guard let encoder = WebPAnimEncoderNew(width, height, &encoderOptions) else {
            throw TriCapError.encodingFailed("WebPAnimEncoderNew failed (canvas too large?).")
        }
        defer { WebPAnimEncoderDelete(encoder) }

        var config = WebPConfig()
        guard WebPConfigInit(&config) != 0 else {
            throw TriCapError.encodingFailed("WebPConfigInit failed (libwebp ABI mismatch).")
        }
        try configure(&config, quality: options.quality, lossless: options.lossless, method: options.method)

        // Timestamps are validated here as well as in `ClipTiming`: a non-monotonic timestamp
        // makes `WebPAnimEncoderAdd` fail with a message no user could act on.
        var previousTimestamp = Int.min

        for index in 0..<frameCount {
            let (image, timestampMs) = try nextFrame(index)

            guard timestampMs > previousTimestamp else {
                throw TriCapError.encodingFailed(
                    "Frame timestamps are not strictly increasing (\(timestampMs) after \(previousTimestamp))."
                )
            }
            previousTimestamp = timestampMs

            guard image.width == Int(width), image.height == Int(height) else {
                throw TriCapError.encodingFailed(
                    "Frame \(index) is \(image.width)x\(image.height) but the canvas is \(width)x\(height)."
                )
            }
            guard let raster = ImageProcessing.rgbxBytes(image) else {
                throw TriCapError.encodingFailed("Could not read pixels for frame \(index).")
            }

            var picture = WebPPicture()
            guard WebPPictureInit(&picture) != 0 else {
                throw TriCapError.encodingFailed("WebPPictureInit failed (libwebp ABI mismatch).")
            }
            picture.use_argb = 1
            picture.width = width
            picture.height = height

            let imported = raster.bytes.withUnsafeBufferPointer { buffer in
                WebPPictureImportRGBX(&picture, buffer.baseAddress, Int32(raster.stride))
            }
            guard imported != 0 else {
                WebPPictureFree(&picture)
                throw TriCapError.encodingFailed("WebPPictureImportRGBX failed for frame \(index).")
            }

            let added = WebPAnimEncoderAdd(encoder, &picture, Int32(timestampMs), &config)
            WebPPictureFree(&picture)
            guard added != 0 else {
                throw TriCapError.encodingFailed(
                    "WebPAnimEncoderAdd failed at frame \(index): \(animEncoderError(encoder))"
                )
            }
            progress?(Double(index + 1) / Double(frameCount))
        }

        guard endTimestampMs > previousTimestamp else {
            throw TriCapError.encodingFailed(
                "Animation end timestamp \(endTimestampMs) is not after the last frame at \(previousTimestamp)."
            )
        }

        // A NULL frame flushes the encoder and fixes the last frame's duration.
        guard WebPAnimEncoderAdd(encoder, nil, Int32(endTimestampMs), nil) != 0 else {
            throw TriCapError.encodingFailed("WebPAnimEncoderAdd(NULL) failed: \(animEncoderError(encoder))")
        }

        var webpData = WebPData()
        WebPDataInit(&webpData)
        defer { WebPDataClear(&webpData) }

        guard WebPAnimEncoderAssemble(encoder, &webpData) != 0 else {
            throw TriCapError.encodingFailed("WebPAnimEncoderAssemble failed: \(animEncoderError(encoder))")
        }
        guard let bytes = webpData.bytes, webpData.size > 0 else {
            throw TriCapError.encodingFailed("WebPAnimEncoderAssemble produced no output.")
        }
        return Data(bytes: bytes, count: webpData.size)
    }

    // MARK: - Inspection (verification + tests)

    /// What TriCap can read back out of a `.webp` file without trusting the encoder.
    public struct AnimationInfo: Sendable, Equatable {
        public let canvasWidth: Int
        public let canvasHeight: Int
        public let frameCount: Int
        /// 0 means "loop forever".
        public let loopCount: Int
        /// Absolute end-of-frame timestamps in milliseconds, as stored in the file.
        public let frameTimestampsMs: [Int]
        public let isAnimated: Bool

        public var durationsMs: [Int] {
            var previous = 0
            var out: [Int] = []
            for timestamp in frameTimestampsMs {
                out.append(timestamp - previous)
                previous = timestamp
            }
            return out
        }

        public var totalDurationMs: Int { frameTimestampsMs.last ?? 0 }
    }

    /// Decode a WebP's structure with libwebp's demuxer.
    ///
    /// Used by the test-suite and by the post-export self-check, so a corrupt file is caught
    /// before TriCap tells the user the export succeeded.
    public static func inspectAnimation(data: Data) throws -> AnimationInfo {
        var info: AnimationInfo?
        var thrown: TriCapError?

        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else {
                thrown = .encodingFailed("Empty WebP data.")
                return
            }
            var webpData = WebPData()
            WebPDataInit(&webpData)
            webpData.bytes = base.assumingMemoryBound(to: UInt8.self)
            webpData.size = raw.count

            var options = WebPAnimDecoderOptions()
            guard WebPAnimDecoderOptionsInit(&options) != 0 else {
                thrown = .encodingFailed("WebPAnimDecoderOptionsInit failed.")
                return
            }
            options.color_mode = MODE_RGBA
            options.use_threads = 0

            guard let decoder = WebPAnimDecoderNew(&webpData, &options) else {
                thrown = .encodingFailed("WebPAnimDecoderNew failed — the file is not a readable WebP.")
                return
            }
            defer { WebPAnimDecoderDelete(decoder) }

            var animInfo = WebPAnimInfo()
            guard WebPAnimDecoderGetInfo(decoder, &animInfo) != 0 else {
                thrown = .encodingFailed("WebPAnimDecoderGetInfo failed.")
                return
            }

            var timestamps: [Int] = []
            var framePointer: UnsafeMutablePointer<UInt8>?
            var timestamp: Int32 = 0
            while WebPAnimDecoderHasMoreFrames(decoder) != 0 {
                guard WebPAnimDecoderGetNext(decoder, &framePointer, &timestamp) != 0 else {
                    thrown = .encodingFailed("WebPAnimDecoderGetNext failed after \(timestamps.count) frames.")
                    return
                }
                timestamps.append(Int(timestamp))
            }

            info = AnimationInfo(
                canvasWidth: Int(animInfo.canvas_width),
                canvasHeight: Int(animInfo.canvas_height),
                frameCount: Int(animInfo.frame_count),
                loopCount: Int(animInfo.loop_count),
                frameTimestampsMs: timestamps,
                isAnimated: animInfo.frame_count > 1
            )
        }

        if let thrown { throw thrown }
        guard let info else { throw TriCapError.encodingFailed("Could not inspect the WebP file.") }
        return info
    }

    /// Decode every frame of an animation into raw RGBA bytes (`width * height * 4` per frame).
    ///
    /// Used by the test-suite to prove that the fixed annotation overlay really is present on
    /// every frame, which structural inspection alone cannot show.
    public static func decodeAnimationFrames(data: Data) throws -> [[UInt8]] {
        var frames: [[UInt8]] = []
        var thrown: TriCapError?

        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else {
                thrown = .encodingFailed("Empty WebP data.")
                return
            }
            var webpData = WebPData()
            WebPDataInit(&webpData)
            webpData.bytes = base.assumingMemoryBound(to: UInt8.self)
            webpData.size = raw.count

            var options = WebPAnimDecoderOptions()
            guard WebPAnimDecoderOptionsInit(&options) != 0 else {
                thrown = .encodingFailed("WebPAnimDecoderOptionsInit failed.")
                return
            }
            options.color_mode = MODE_RGBA
            options.use_threads = 0

            guard let decoder = WebPAnimDecoderNew(&webpData, &options) else {
                thrown = .encodingFailed("WebPAnimDecoderNew failed.")
                return
            }
            defer { WebPAnimDecoderDelete(decoder) }

            var animInfo = WebPAnimInfo()
            guard WebPAnimDecoderGetInfo(decoder, &animInfo) != 0 else {
                thrown = .encodingFailed("WebPAnimDecoderGetInfo failed.")
                return
            }
            let byteCount = Int(animInfo.canvas_width) * Int(animInfo.canvas_height) * 4

            var framePointer: UnsafeMutablePointer<UInt8>?
            var timestamp: Int32 = 0
            while WebPAnimDecoderHasMoreFrames(decoder) != 0 {
                guard WebPAnimDecoderGetNext(decoder, &framePointer, &timestamp) != 0,
                      let pixels = framePointer else {
                    thrown = .encodingFailed("WebPAnimDecoderGetNext failed after \(frames.count) frames.")
                    return
                }
                frames.append([UInt8](UnsafeBufferPointer(start: pixels, count: byteCount)))
            }
        }

        if let thrown { throw thrown }
        return frames
    }

    /// Decode a still WebP back to a `CGImage` (used by tests to confirm round-trip fidelity).
    public static func decodeStill(data: Data) throws -> CGImage {
        var width: Int32 = 0
        var height: Int32 = 0

        let decoded: UnsafeMutablePointer<UInt8>? = data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
            return WebPDecodeRGBA(base, raw.count, &width, &height)
        }
        guard let decoded, width > 0, height > 0 else {
            throw TriCapError.encodingFailed("WebPDecodeRGBA failed.")
        }
        defer { WebPFree(decoded) }

        let byteCount = Int(width) * Int(height) * 4
        let pixels = Data(bytes: decoded, count: byteCount)
        guard let provider = CGDataProvider(data: pixels as CFData) else {
            throw TriCapError.encodingFailed("Could not wrap decoded WebP pixels.")
        }
        guard let image = CGImage(
            width: Int(width),
            height: Int(height),
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: Int(width) * 4,
            space: ImageProcessing.outputColorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue).union(.byteOrder32Big),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            throw TriCapError.encodingFailed("Could not build a CGImage from decoded WebP pixels.")
        }
        return image
    }

    // MARK: - Helpers

    /// Internal rather than private so `WebPAnimEncoderSession` configures its encoder through
    /// exactly the same code — the streaming path and the live path must not drift apart.
    static func configure(_ config: inout WebPConfig, quality: Int, lossless: Bool, method: Int) throws {
        if lossless {
            guard WebPConfigLosslessPreset(&config, Int32(method.clamped(to: 0...9))) != 0 else {
                throw TriCapError.encodingFailed("WebPConfigLosslessPreset rejected the settings.")
            }
        } else {
            config.lossless = 0
            config.quality = Float(quality.clamped(to: 0...100))
            config.method = Int32(method.clamped(to: 0...6))
        }
        config.thread_level = 1
        guard WebPValidateConfig(&config) != 0 else {
            throw TriCapError.encodingFailed("WebPValidateConfig rejected quality=\(quality) method=\(method).")
        }
    }

    private static func animEncoderError(_ encoder: OpaquePointer?) -> String {
        guard let encoder, let message = WebPAnimEncoderGetError(encoder) else { return "unknown error" }
        return String(cString: message)
    }

    private static func errorName(_ code: WebPEncodingError) -> String {
        switch code {
        case VP8_ENC_OK: return "ok"
        case VP8_ENC_ERROR_OUT_OF_MEMORY: return "out of memory"
        case VP8_ENC_ERROR_BITSTREAM_OUT_OF_MEMORY: return "bitstream out of memory"
        case VP8_ENC_ERROR_NULL_PARAMETER: return "null parameter"
        case VP8_ENC_ERROR_INVALID_CONFIGURATION: return "invalid configuration"
        case VP8_ENC_ERROR_BAD_DIMENSION: return "bad dimension"
        case VP8_ENC_ERROR_PARTITION0_OVERFLOW: return "partition 0 overflow"
        case VP8_ENC_ERROR_PARTITION_OVERFLOW: return "partition overflow"
        case VP8_ENC_ERROR_BAD_WRITE: return "bad write"
        case VP8_ENC_ERROR_FILE_TOO_BIG: return "file too big"
        case VP8_ENC_ERROR_USER_ABORT: return "user abort"
        default: return "error \(code.rawValue)"
        }
    }
}
