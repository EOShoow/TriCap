import CoreGraphics
import Foundation

/// A screen snapshot reduced to the one layout ``VisualRegionDetector`` reads.
///
/// Deliberately a plain value type with no Core Graphics object inside it: the detector is the
/// part most likely to be wrong, and it has to be testable against hand-built fixtures in a
/// process with no window server, no display and no Screen Recording permission. `CaptureCore`
/// builds these from a real capture; the tests build them from a closure.
///
/// The byte layout is exactly what `ImageProcessing.rgbxBytes` produces — row-major, top-left
/// origin, four bytes per sample, `R G B X` — so a capture becomes a field without a second copy
/// or a second opinion about channel order.
public struct PixelField: Sendable, Equatable {

    public static let bytesPerSample = 4

    public let width: Int
    public let height: Int
    public let bytes: [UInt8]

    /// - Returns: `nil` for a degenerate size or a buffer too short to describe it, rather than
    ///   trapping. The caller is holding a capture that may have come back in an unexpected shape.
    public init?(width: Int, height: Int, bytes: [UInt8]) {
        guard width > 0, height > 0, let needed = Self.byteCount(width: width, height: height),
              bytes.count >= needed
        else { return nil }
        self.width = width
        self.height = height
        self.bytes = bytes
    }

    /// Bytes needed for a `width` × `height` field, or `nil` if that product overflows.
    ///
    /// A display size arriving as a bad number is not a reason to trap the process. The
    /// multiplication is checked rather than assumed because the only thing standing between a
    /// bogus width and a wildly undersized allocation is this arithmetic.
    static func byteCount(width: Int, height: Int) -> Int? {
        let (samples, samplesOverflowed) = width.multipliedReportingOverflow(by: height)
        guard !samplesOverflowed else { return nil }
        let (total, totalOverflowed) = samples.multipliedReportingOverflow(by: bytesPerSample)
        guard !totalOverflowed else { return nil }
        return total
    }

    /// Build a field from a generator returning `(r, g, b)` in `0...1`.
    ///
    /// This is the fixture entry point. Nothing in the app uses it, which is the point: a test
    /// fixture that went through the same downsampling code as production would hide bugs in it.
    public init(width: Int, height: Int, sample: (Int, Int) -> (Float, Float, Float)) {
        precondition(width > 0 && height > 0, "a pixel field needs a positive size")
        guard let count = Self.byteCount(width: width, height: height) else {
            preconditionFailure("field size \(width)×\(height) overflows")
        }
        var bytes = [UInt8](repeating: 255, count: count)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = sample(x, y)
                let i = (y * width + x) * Self.bytesPerSample
                bytes[i] = Self.byte(r)
                bytes[i + 1] = Self.byte(g)
                bytes[i + 2] = Self.byte(b)
            }
        }
        self.width = width
        self.height = height
        self.bytes = bytes
    }

    private static func byte(_ value: Float) -> UInt8 {
        UInt8(max(0, min(255, (value * 255).rounded())))
    }

    public var size: CGSize { CGSize(width: width, height: height) }

    /// One sample, components in `0...1`.
    public struct Sample: Equatable, Sendable {
        public let red: Float
        public let green: Float
        public let blue: Float
        /// Rec. 709 luma of the stored (non-linear) components. Good enough to rank "brighter
        /// than its surroundings", which is all the detector asks of it.
        public var luma: Float { 0.2126 * red + 0.7152 * green + 0.0722 * blue }
    }

    public subscript(x: Int, y: Int) -> Sample {
        precondition(x >= 0 && x < width && y >= 0 && y < height, "sample out of bounds")
        let i = (y * width + x) * Self.bytesPerSample
        return Sample(
            red: Float(bytes[i]) / 255,
            green: Float(bytes[i + 1]) / 255,
            blue: Float(bytes[i + 2]) / 255
        )
    }

    /// Swap the axes.
    ///
    /// The detector runs one single-axis pass, over this field and over its transpose. That is
    /// what guarantees the horizontal and vertical logic cannot drift apart — there is only one
    /// implementation, and `transposed().transposed() == self` is a test.
    public func transposed() -> PixelField {
        // Same sample count as `self`, which already proved it does not overflow.
        var flipped = [UInt8](repeating: 255, count: Self.byteCount(width: width, height: height)!)
        bytes.withUnsafeBufferPointer { source in
            flipped.withUnsafeMutableBufferPointer { destination in
                for y in 0..<height {
                    for x in 0..<width {
                        let from = (y * width + x) * Self.bytesPerSample
                        let to = (x * height + y) * Self.bytesPerSample
                        destination[to] = source[from]
                        destination[to + 1] = source[from + 1]
                        destination[to + 2] = source[from + 2]
                        destination[to + 3] = source[from + 3]
                    }
                }
            }
        }
        // Non-degenerate by construction, so the failable initializer cannot fail here.
        return PixelField(width: height, height: width, bytes: flipped)!
    }

    /// Box-average this field down by an integer factor.
    ///
    /// Production hands the downscale to ScreenCaptureKit, which is faster and better filtered.
    /// This exists so a test can reproduce the *effect* of that downscale on a known fixture and
    /// measure what it costs in edge accuracy — the error bound between a detected boundary and
    /// the true one in source pixels is a claim this file makes, so it has to be a claim a test
    /// can check rather than a comment.
    ///
    /// - Returns: `nil` for a factor below 1 or a result that would be degenerate.
    public func downsampled(by factor: Int) -> PixelField? {
        guard factor >= 1 else { return nil }
        if factor == 1 { return self }

        let outWidth = (width + factor - 1) / factor
        let outHeight = (height + factor - 1) / factor
        guard outWidth > 0, outHeight > 0,
              let count = Self.byteCount(width: outWidth, height: outHeight)
        else { return nil }

        var reduced = [UInt8](repeating: 255, count: count)
        bytes.withUnsafeBufferPointer { source in
            reduced.withUnsafeMutableBufferPointer { destination in
                for oy in 0..<outHeight {
                    // The last block along each axis is short when the size is not a multiple of
                    // the factor; averaging only the samples that exist keeps the edge honest
                    // instead of smearing it against a padded value.
                    let yRange = (oy * factor)..<min(height, (oy + 1) * factor)
                    for ox in 0..<outWidth {
                        let xRange = (ox * factor)..<min(width, (ox + 1) * factor)
                        var r = 0, g = 0, b = 0, n = 0
                        for y in yRange {
                            for x in xRange {
                                let i = (y * width + x) * Self.bytesPerSample
                                r += Int(source[i]); g += Int(source[i + 1]); b += Int(source[i + 2])
                                n += 1
                            }
                        }
                        guard n > 0 else { continue }
                        let o = (oy * outWidth + ox) * Self.bytesPerSample
                        destination[o] = UInt8(r / n)
                        destination[o + 1] = UInt8(g / n)
                        destination[o + 2] = UInt8(b / n)
                    }
                }
            }
        }
        return PixelField(width: outWidth, height: outHeight, bytes: reduced)
    }
}
