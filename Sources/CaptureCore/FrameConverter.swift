import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit
import TriCapKit

/// Turns a ScreenCaptureKit sample buffer into a normalised `CGImage`.
///
/// Deliberately CPU-only (`CGContext` over the locked `CVPixelBuffer`) rather than CoreImage:
/// no GPU context to create or lose, no surprise colour management, and `CGContext.makeImage()`
/// copies the bits so the IOSurface can be released immediately — which matters because SCK only
/// lends us `queueDepth` surfaces at a time.
enum FrameConverter {

    struct Frame {
        let image: CGImage
        let presentationSeconds: TimeInterval
        let colorSpace: ImageProcessing.ColorSpaceOutcome
    }

    /// `nil` means "skip this sample": SCK sends idle/blank frames when nothing on screen changed.
    static func frame(from sampleBuffer: CMSampleBuffer, expectedPixelSize: CGSize) -> Frame? {
        guard CMSampleBufferIsValid(sampleBuffer) else { return nil }

        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]]
        let info = attachments?.first

        if let statusValue = info?[.status] as? Int,
           let status = SCFrameStatus(rawValue: statusValue),
           status != .complete {
            return nil
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        guard let raw = cgImage(from: pixelBuffer) else { return nil }

        // SCK may hand back a surface larger than the requested size (IOSurface alignment).
        // `contentRect` is in points, `scaleFactor` converts it to the buffer's pixels.
        var cropped = raw
        if let rectDict = info?[.contentRect] as? [String: Any],
           let contentRect = CGRect(dictionaryRepresentation: rectDict as CFDictionary) {
            let scale = (info?[.scaleFactor] as? CGFloat) ?? 1.0
            let pixelRect = CGRect(
                x: contentRect.origin.x * scale,
                y: contentRect.origin.y * scale,
                width: contentRect.width * scale,
                height: contentRect.height * scale
            ).integralOutward.intersection(CGRect(x: 0, y: 0, width: raw.width, height: raw.height))

            if !pixelRect.isNull, pixelRect.width >= 1, pixelRect.height >= 1,
               pixelRect != CGRect(x: 0, y: 0, width: raw.width, height: raw.height),
               let sub = raw.cropping(to: pixelRect) {
                cropped = sub
            }
        }

        let targetW = max(1, Int(expectedPixelSize.width.rounded()))
        let targetH = max(1, Int(expectedPixelSize.height.rounded()))
        let sized: CGImage
        if cropped.width != targetW || cropped.height != targetH {
            guard let scaled = ImageProcessing.scaled(cropped, to: CGSize(width: targetW, height: targetH)) else {
                return nil
            }
            sized = scaled
        } else {
            sized = cropped
        }

        guard let normalized = ImageProcessing.normalizedToSRGB(sized) else { return nil }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let seconds = pts.isValid && !pts.isIndefinite ? pts.seconds : 0

        return Frame(image: normalized.image, presentationSeconds: seconds, colorSpace: normalized.outcome)
    }

    private static func cgImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard width > 0, height > 0, bytesPerRow > 0 else { return nil }

        // SCK is configured for kCVPixelFormatType_32BGRA. Screen content is opaque, so the
        // alpha byte is ignored rather than treated as premultiplied.
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)
            .union(.byteOrder32Little)

        // The colour space is whatever the stream was configured with (sRGB); attaching it here
        // keeps `normalizedToSRGB` honest about whether a conversion actually happened.
        let space = CVImageBufferGetColorSpace(pixelBuffer)?.takeUnretainedValue()
            ?? ImageProcessing.outputColorSpace

        guard let context = CGContext(
            data: base,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: space,
            bitmapInfo: bitmapInfo.rawValue
        ) else { return nil }

        return context.makeImage()
    }
}
