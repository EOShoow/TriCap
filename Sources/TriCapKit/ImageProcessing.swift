import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Bitmap plumbing shared by capture, annotation and export.
///
/// **Colour policy.** TriCap renders and exports everything in sRGB, 8 bits per component,
/// opaque, with the byte order `R G B X`. Screen captures are opaque by definition and the
/// annotation canvas is composited over them, so an alpha channel would only add a
/// premultiplication trap for no benefit. Fixing the layout here means the libwebp bridge can
/// use `WebPPictureImportRGBX` unconditionally and PNG/JPEG go through the same buffer.
public enum ImageProcessing {

    /// The one colour space TriCap ever renders into.
    public static let outputColorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    /// `noneSkipLast` = opaque RGBX. Combined with `.byteOrder32Big` the bytes are literally R,G,B,X.
    public static let outputBitmapInfo: CGBitmapInfo = CGBitmapInfo(
        rawValue: CGImageAlphaInfo.noneSkipLast.rawValue
    ).union(.byteOrder32Big)

    /// Create an opaque sRGB RGBX drawing context of the given pixel size.
    public static func makeContext(width: Int, height: Int) -> CGContext? {
        makeContext(width: width, height: height, colorSpace: outputColorSpace)
    }

    /// Create an opaque RGBX context while retaining an intermediate image's source profile.
    private static func makeContext(width: Int, height: Int, colorSpace: CGColorSpace) -> CGContext? {
        guard width > 0, height > 0 else { return nil }
        return CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: outputBitmapInfo.rawValue
        )
    }

    /// Describes what happened to an image's colour space on the way into TriCap's pipeline.
    public struct ColorSpaceOutcome: Sendable, Equatable {
        /// Name of the colour space the capture arrived in, for logging and the UI notice.
        public let sourceName: String
        /// `true` when the source was not already sRGB and TriCap converted it.
        public let converted: Bool
        /// `true` when the source was a wide-gamut / HDR space whose appearance cannot be
        /// preserved in an 8-bit sRGB file. Callers surface this to the user instead of
        /// pretending the conversion was lossless.
        public let wasWideGamutOrHDR: Bool

        public init(sourceName: String, converted: Bool, wasWideGamutOrHDR: Bool) {
            self.sourceName = sourceName
            self.converted = converted
            self.wasWideGamutOrHDR = wasWideGamutOrHDR
        }

        public var userFacingNotice: String? {
            guard wasWideGamutOrHDR else { return nil }
            return "Captured content was \(sourceName). TriCap exports 8-bit sRGB, so colours outside sRGB are gamut-mapped and extended-range highlights, when present, are clipped."
        }
    }

    /// Redraw `image` into TriCap's canonical opaque sRGB RGBX bitmap.
    ///
    /// Always returns a freshly rendered image (never the input) so downstream code can rely on
    /// the exact layout. Returns `nil` only if a context of that size cannot be allocated.
    public static func normalizedToSRGB(
        _ image: CGImage,
        fallbackSourceColorSpace: CGColorSpace? = nil,
        sourceDisplayIsWideGamutOrHDR: Bool = false
    ) -> (image: CGImage, outcome: ColorSpaceOutcome)? {
        let sourceSpace = resolvedSourceColorSpace(
            imageColorSpace: image.colorSpace,
            fallback: fallbackSourceColorSpace
        )
        let profileName = (sourceSpace?.name as String?) ?? "unknown colour space"
        let bufferIdentifiesWideGamutOrHDR = isWideGamutOrHDR(sourceSpace)
        let sourceName = sourceDisplayIsWideGamutOrHDR && !bufferIdentifiesWideGamutOrHDR
            ? "\(profileName) (wide-gamut or extended-range display)"
            : profileName
        let isAlreadySRGB = sourceSpace?.name == CGColorSpace.sRGB
        let wide = bufferIdentifiesWideGamutOrHDR || sourceDisplayIsWideGamutOrHDR

        // SCScreenshotManager and some SCStream pixel buffers omit the colour attachment even
        // though the pixels are in the display-native profile. Attach the public NSScreen profile
        // before drawing so Core Graphics performs the intended conversion rather than treating
        // the bytes as uncalibrated device RGB.
        let sourceImage: CGImage
        if image.colorSpace == nil,
           let sourceSpace,
           let tagged = image.copy(colorSpace: sourceSpace) {
            sourceImage = tagged
        } else {
            sourceImage = image
        }

        guard let context = makeContext(width: image.width, height: image.height) else { return nil }
        context.interpolationQuality = .high
        context.draw(sourceImage, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let out = context.makeImage() else { return nil }

        return (
            out,
            ColorSpaceOutcome(
                sourceName: sourceName,
                converted: !isAlreadySRGB,
                wasWideGamutOrHDR: wide
            )
        )
    }

    static func resolvedSourceColorSpace(
        imageColorSpace: CGColorSpace?,
        fallback: CGColorSpace?
    ) -> CGColorSpace? {
        imageColorSpace ?? fallback
    }

    /// Wide-gamut and HDR spaces we refuse to convert silently.
    ///
    /// The list is name-based on purpose: `CGColorSpace` exposes no "is HDR" predicate on
    /// macOS 14, and matching on the documented constant names is stable and auditable.
    public static func isWideGamutOrHDR(_ space: CGColorSpace?) -> Bool {
        guard let name = space?.name as String? else { return false }
        let wideNames: Set<String> = [
            CGColorSpace.displayP3 as String,
            CGColorSpace.displayP3_HLG as String,
            CGColorSpace.displayP3_PQ as String,
            CGColorSpace.extendedSRGB as String,
            CGColorSpace.extendedLinearSRGB as String,
            CGColorSpace.extendedDisplayP3 as String,
            CGColorSpace.itur_2020 as String,
            CGColorSpace.itur_2100_HLG as String,
            CGColorSpace.itur_2100_PQ as String,
            CGColorSpace.adobeRGB1998 as String,
        ]
        return wideNames.contains(name)
    }

    /// High-quality aspect-agnostic resample into an exact pixel size.
    public static func scaled(_ image: CGImage, to size: CGSize) -> CGImage? {
        let w = Int(size.width.rounded())
        let h = Int(size.height.rounded())
        guard w > 0, h > 0 else { return nil }
        if w == image.width && h == image.height { return image }
        guard let context = makeContext(
            width: w,
            height: h,
            colorSpace: image.colorSpace ?? outputColorSpace
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return context.makeImage()
    }

    /// Straight, unpremultiplied `R G B X` bytes, tightly packed at `width * 4` per row.
    ///
    /// libwebp wants a contiguous buffer with an explicit stride, and `CGImage` gives no
    /// guarantee about its own stride, so this re-renders rather than poking at `dataProvider`.
    public static func rgbxBytes(_ image: CGImage) -> (bytes: [UInt8], width: Int, height: Int, stride: Int)? {
        let w = image.width
        let h = image.height
        guard w > 0, h > 0 else { return nil }
        let stride = w * 4
        var bytes = [UInt8](repeating: 0, count: stride * h)
        let ok: Bool = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(
                      data: base,
                      width: w,
                      height: h,
                      bitsPerComponent: 8,
                      bytesPerRow: stride,
                      space: outputColorSpace,
                      bitmapInfo: outputBitmapInfo.rawValue
                  )
            else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        return (bytes, w, h, stride)
    }

    // MARK: - PNG round trip (used by the in-memory frame buffer)

    public static func pngData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    public static func image(fromPNG data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
