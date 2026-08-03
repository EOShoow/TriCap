import Foundation

/// libwebp animation-encoder strategy: how hard the encoder works per frame.
///
/// These are *not* user settings. `AnimatedWebPOptions` holds what the user chose — quality,
/// lossless, method, loop count — and this holds two internal `WebPAnimEncoderOptions` flags that
/// only trade encoding time against file size.
///
/// They are separated out because measurement showed them to be the entire cost of an export.
/// Profiling a 1440×900 high-motion clip (`TriCap --benchmark-export`) attributed **857 ms per
/// frame** to `WebPAnimEncoderAdd`, against 0.1 ms for PNG decode and 8.7 ms for pixel extraction.
/// At a 12 fps capture interval of 83 ms that is 10× real time, which is why a fifteen-second
/// recording takes minutes to export and why no amount of rescheduling the work can fix it on its
/// own.
public struct AnimationEncodeStrategy: Sendable, Equatable {

    /// `WebPAnimEncoderOptions.minimize_size`. Makes the encoder retry frames looking for a
    /// smaller result. Documented by libwebp as slow.
    public let minimizeSize: Bool

    /// `WebPAnimEncoderOptions.allow_mixed`. Encodes each frame **both** lossily and losslessly and
    /// keeps whichever is smaller. Lossless encoding of a noisy megapixel frame is the single most
    /// expensive thing in the pipeline, so this roughly multiplies the cost of every frame.
    public let allowMixed: Bool

    public init(minimizeSize: Bool, allowMixed: Bool) {
        self.minimizeSize = minimizeSize
        self.allowMixed = allowMixed
    }

    /// What TriCap shipped through commit `79d20b3`: both flags on. Kept as a named value so the
    /// benchmark can measure against it and so the change is a diff rather than a mystery.
    public static let thorough = AnimationEncodeStrategy(minimizeSize: true, allowMixed: true)

    /// The default. Both flags off.
    ///
    /// The user's quality, method and lossless choices are untouched — this only stops the encoder
    /// from *also* trying the other mode and re-running frames hunting for a few percent. See
    /// REVIEW_HANDOFF.md for the measured time and size at both settings.
    public static let balanced = AnimationEncodeStrategy(minimizeSize: false, allowMixed: false)

    public static let `default` = AnimationEncodeStrategy.balanced
}
