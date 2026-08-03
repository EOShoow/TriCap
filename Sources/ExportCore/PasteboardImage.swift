import AppKit
import CoreGraphics
import Foundation
import TriCapKit
import UniformTypeIdentifiers

/// Reading images out of the system pasteboard, and writing them back in.
///
/// Split from the pin UI so the *policy* — which representations are preferred, what counts as
/// "no image", what gets written on a copy — is testable without a window.
public enum PasteboardImage {

    /// Types TriCap will read, best first.
    ///
    /// PNG before TIFF because PNG is what most applications put on the pasteboard for a
    /// screenshot and it is smaller; TIFF is AppKit's lossless lingua franca and the fallback that
    /// almost always exists. `NSImage` last: it can wrap a vector or a multi-representation image
    /// whose rasterisation we would rather not guess at unless nothing else is available.
    public static let readableTypes: [NSPasteboard.PasteboardType] = [
        .png,
        .tiff,
    ]

    /// Why a paste produced nothing.
    public enum ReadFailure: Error, Equatable, Sendable {
        case empty
        case unsupportedContent

        public var message: String {
            switch self {
            case .empty:
                return "The clipboard is empty."
            case .unsupportedContent:
                return "The clipboard does not contain an image."
            }
        }
    }

    /// Decide what a pasteboard's advertised types mean, without touching one.
    ///
    /// - Returns: the type TriCap would read, or the reason it would decline.
    public static func preferredType(
        available: [NSPasteboard.PasteboardType],
        canProvideImageObject: Bool
    ) -> Result<NSPasteboard.PasteboardType?, ReadFailure> {
        if available.isEmpty && !canProvideImageObject { return .failure(.empty) }
        for type in readableTypes where available.contains(type) {
            return .success(type)
        }
        // No raw bitmap type, but AppKit can still hand over an `NSImage` — a PDF or a file
        // promise, for instance.
        if canProvideImageObject { return .success(nil) }
        return .failure(.unsupportedContent)
    }

    /// Read the current clipboard image.
    ///
    /// - Returns: an opaque sRGB `CGImage` normalised through `ImageProcessing`, so a pinned image
    ///   and a saved one go through exactly the same colour pipeline.
    @MainActor
    public static func read(from pasteboard: NSPasteboard = .general) -> Result<CGImage, ReadFailure> {
        let available = pasteboard.types ?? []
        let canProvideImage = pasteboard.canReadObject(forClasses: [NSImage.self], options: nil)

        switch preferredType(available: available, canProvideImageObject: canProvideImage) {
        case .failure(let failure):
            return .failure(failure)
        case .success(let type):
            if let type, let data = pasteboard.data(forType: type),
               let image = decode(data: data) {
                return .success(image)
            }
            // Fall back to whatever AppKit can make of it.
            if let image = pasteboard.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage,
               let cgImage = normalize(image) {
                return .success(cgImage)
            }
            return .failure(.unsupportedContent)
        }
    }

    /// Decode raw pasteboard bytes into TriCap's canonical bitmap.
    public static func decode(data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let raw = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return ImageProcessing.normalizedToSRGB(raw)?.image
    }

    @MainActor
    private static func normalize(_ image: NSImage) -> CGImage? {
        var rect = CGRect(origin: .zero, size: image.size)
        guard let raw = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        return ImageProcessing.normalizedToSRGB(raw)?.image
    }

    // MARK: - Writing

    /// What a successful clipboard write put there.
    public struct WriteReceipt: Equatable, Sendable {
        /// The pasteboard types actually written.
        public let types: [String]
        public var wroteRasterData: Bool { types.contains(NSPasteboard.PasteboardType.png.rawValue) }

        public init(types: [String]) {
            self.types = types
        }
    }

    /// Put an image on the clipboard as both PNG data and a system image object.
    ///
    /// Two representations because applications disagree about what they will accept: a browser
    /// or an editor generally wants `public.png`, while Notes, Pages and Mail take the `NSImage`.
    /// Writing only one of them makes "copy" work in half the places a user tries it.
    ///
    /// - Returns: the receipt, or `nil` when the pasteboard refused every representation — which
    ///   the caller must surface rather than claiming a copy that did not happen.
    @MainActor
    @discardableResult
    public static func write(_ image: CGImage, to pasteboard: NSPasteboard = .general) -> WriteReceipt? {
        pasteboard.clearContents()
        var written: [String] = []

        if let png = ImageProcessing.pngData(from: image),
           pasteboard.setData(png, forType: .png) {
            written.append(NSPasteboard.PasteboardType.png.rawValue)
        }

        let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        if pasteboard.writeObjects([nsImage]) {
            written.append(NSPasteboard.PasteboardType.tiff.rawValue)
        }

        guard !written.isEmpty else { return nil }
        return WriteReceipt(types: written)
    }
}
