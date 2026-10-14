import AnnotationCore
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import TriCapKit
import UniformTypeIdentifiers

/// Complete animations on the clipboard, without a permanent export or a flattened NSImage.
public enum PasteboardAnimation {
    public static let webPType = NSPasteboard.PasteboardType("org.webmproject.webp")
    public static let gifType = NSPasteboard.PasteboardType(UTType.gif.identifier)

    public struct Payload: Sendable {
        public let webP: EncodedAnimation
        public let gifData: Data
    }

    public struct WriteReceipt: Equatable, Sendable {
        public let types: [String]
        public let frameCount: Int
        public let durationMs: Int
        public let collapsedToSingleFrame: Bool
        public let temporaryFileURL: URL

        public var message: String {
            collapsedToSingleFrame
                ? "Copied image — nothing moved in this recording."
                : "Copied animation — ready to paste."
        }
    }

    /// WebP retains the original quality; GIF lets apps that accept GIF paste the whole clip.
    /// Only one decoded source frame is retained at a time, including after trim/crop/annotation.
    public static func prepare(
        source: AnimationFrameSource,
        annotations: [AnnotationItem],
        options: AnimatedWebPOptions,
        preEncoded: PreEncodedAnimation? = nil,
        cropRect: CGRect? = nil,
        isCancelled: @escaping @Sendable () -> Bool = { false },
        progress: ((Double) -> Void)? = nil
    ) throws -> Payload {
        let encoded = try ExportService.encodeAnimation(
            source: source, annotations: annotations, options: options,
            preEncoded: preEncoded, progress: { progress?($0 * 0.5) },
            cropRect: cropRect, isCancelled: isCancelled
        )
        let frameCount = encoded.collapsedToSingleFrame ? 1 : source.frameCount
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.gif.identifier as CFString, frameCount, nil
        ) else {
            throw TriCapError.encodingFailed("Could not create the clipboard GIF encoder.")
        }
        // ImageIO counts total plays, like WebP. It writes repeats = plays - 1 into the GIF
        // extension itself, and omits that extension for one play. Zero means forever.
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: options.loopCount]
        ] as CFDictionary)

        for index in 0..<frameCount {
            guard !isCancelled() else { throw TriCapError.cancelled }
            try autoreleasepool {
                let raw = try source.loadFrame(index)
                let annotated = annotations.isEmpty ? raw
                    : (AnnotationRenderer.render(items: annotations, onto: raw) ?? raw)
                let image: CGImage
                if let cropRect {
                    guard let cropped = annotated.cropping(to: cropRect) else {
                        throw TriCapError.encodingFailed("Could not crop the clipboard GIF.")
                    }
                    image = cropped
                } else {
                    image = annotated
                }
                let next = index + 1 < source.frameCount
                    ? source.timestampsMs[index + 1] : source.endTimestampMs
                // GIF timing is in centiseconds. Round absolute endpoints so errors don't
                // accumulate over hundreds of frames; a 12 fps clip alternates 80/90 ms.
                let startTick = Int((Double(source.timestampsMs[index]) / 10).rounded())
                let endTick = Int((Double(next) / 10).rounded())
                let delay = Double(max(1, endTick - startTick)) / 100
                CGImageDestinationAddImage(destination, image, [
                    kCGImagePropertyGIFDictionary: [
                        kCGImagePropertyGIFDelayTime: delay,
                        kCGImagePropertyGIFUnclampedDelayTime: delay
                    ]
                ] as CFDictionary)
            }
            progress?(0.5 + 0.5 * Double(index + 1) / Double(frameCount))
        }
        guard !isCancelled() else { throw TriCapError.cancelled }
        guard CGImageDestinationFinalize(destination),
              let decoded = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(decoded) == frameCount else {
            throw TriCapError.encodingFailed("The clipboard GIF did not retain its frames.")
        }
        return Payload(webP: encoded, gifData: data as Data)
    }

    /// Put all representations on ONE pasteboard item. We do not advertise a static PNG/TIFF;
    /// receivers can choose the original bytes or the GIF file to preserve animation.
    @MainActor
    @discardableResult
    public static func write(
        _ payload: Payload,
        to pasteboard: NSPasteboard = .general
    ) -> WriteReceipt? {
        guard let url = try? AnimationClipboardFileStore.stage(payload.gifData) else { return nil }
        var retained = false
        defer { if !retained { try? FileManager.default.removeItem(at: url) } }
        let item = NSPasteboardItem()
        guard item.setData(payload.gifData, forType: gifType),
              item.setData(payload.webP.data, forType: webPType),
              item.setString(url.absoluteString, forType: .fileURL) else { return nil }
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else { return nil }
        // Read back the actual representations before telling the user Copy succeeded.
        guard pasteboard.data(forType: gifType) == payload.gifData,
              pasteboard.data(forType: webPType) == payload.webP.data,
              pasteboard.string(forType: .fileURL) == url.absoluteString else { return nil }
        AnimationClipboardFileStore.retain(url, for: pasteboard)
        retained = true
        return WriteReceipt(
            types: [gifType.rawValue, webPType.rawValue, NSPasteboard.PasteboardType.fileURL.rawValue],
            frameCount: payload.webP.animationInfo.frameCount,
            durationMs: payload.webP.animationInfo.totalDurationMs,
            collapsedToSingleFrame: payload.webP.collapsedToSingleFrame,
            temporaryFileURL: url
        )
    }
}
