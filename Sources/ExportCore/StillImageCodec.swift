import CoreGraphics
import Foundation
import ImageIO
import TriCapKit
import UniformTypeIdentifiers

/// PNG and JPEG encoding via ImageIO, plus format sniffing used to verify what we wrote.
public enum StillImageCodec {

    /// Encode `image` in `format`. `quality` (0...100) applies to JPEG and lossy WebP only.
    public static func encode(_ image: CGImage, format: OutputFormat, quality: Int) throws -> Data {
        switch format {
        case .png:
            return try encodePNG(image)
        case .jpeg:
            return try encodeJPEG(image, quality: quality)
        case .webp:
            return try WebPCodec.encodeStill(image, quality: quality)
        case .animatedWebP:
            throw TriCapError.encodingFailed("Animated WebP needs the animation encoder, not the still encoder.")
        }
    }

    public static func encodePNG(_ image: CGImage) throws -> Data {
        try encodeWithImageIO(image, type: UTType.png, properties: nil)
    }

    public static func encodeJPEG(_ image: CGImage, quality: Int) throws -> Data {
        let q = Double(quality.clamped(to: 0...100)) / 100.0
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: q,
            // ImageIO writes the CGImage's colour space; ours is always sRGB.
            kCGImagePropertyHasAlpha: false,
        ]
        return try encodeWithImageIO(image, type: UTType.jpeg, properties: properties as CFDictionary)
    }

    private static func encodeWithImageIO(_ image: CGImage, type: UTType, properties: CFDictionary?) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, type.identifier as CFString, 1, nil
        ) else {
            throw TriCapError.encodingFailed("ImageIO has no encoder for \(type.identifier).")
        }
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else {
            throw TriCapError.encodingFailed("ImageIO could not finalise the \(type.preferredFilenameExtension ?? type.identifier) file.")
        }
        guard data.length > 0 else {
            throw TriCapError.encodingFailed("ImageIO produced an empty \(type.identifier) file.")
        }
        return data as Data
    }
}

/// Container sniffing from the first bytes of a file.
///
/// TriCap uses this after every export to confirm that what landed on disk really matches the
/// extension it was given — a cheap guard against "the extension says .webp but ImageIO wrote a
/// PNG" class of bugs, and the thing the verification steps in REVIEW_HANDOFF.md check.
public enum MagicBytes {
    public enum Container: String, Sendable, Equatable {
        case png
        case jpeg
        case webpStill
        case webpAnimated
        case unknown

        public var matchesExtension: String? {
            switch self {
            case .png: return "png"
            case .jpeg: return "jpg"
            case .webpStill, .webpAnimated: return "webp"
            case .unknown: return nil
            }
        }
    }

    public static func detect(_ data: Data) -> Container {
        // Copy the head into a plain array: `Data` slices keep their parent's indices, so
        // subscripting a slice by 0 would trap.
        let b = [UInt8](data.prefix(32))

        if b.count >= 8, b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47,
           b[4] == 0x0D, b[5] == 0x0A, b[6] == 0x1A, b[7] == 0x0A {
            return .png
        }
        if b.count >= 3, b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF {
            return .jpeg
        }
        // "RIFF" <u32 size> "WEBP"
        if b.count >= 16 {
            let riff = b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46
            let webp = b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50
            if riff && webp {
                // The "VP8X" extended header carries the animation flag in its first payload byte.
                let isVP8X = b[12] == 0x56 && b[13] == 0x50 && b[14] == 0x38 && b[15] == 0x58
                if isVP8X, b.count >= 21 {
                    // bit 1 (0x02) == animation
                    return (b[20] & 0x02) != 0 ? .webpAnimated : .webpStill
                }
                return .webpStill
            }
        }
        return .unknown
    }

    public static func detect(fileAt url: URL) throws -> Container {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let head = try handle.read(upToCount: 32) ?? Data()
        return detect(head)
    }
}
