import Foundation

/// Result-oriented quality choices.
///
/// The encoder parameters TriCap exposes — a 0–100 quality factor, a long-edge cap in pixels, a
/// frame rate — are meaningful to someone who already knows what they do and meaningless to
/// everyone else. A preset names the *outcome* ("smaller file", "sharper") and writes a coherent
/// set of those parameters in one go.
///
/// `custom` is not something the user picks from a menu: it is what the settings become the moment
/// any advanced value stops matching a preset. That is what stops the preset system from silently
/// overwriting values somebody deliberately tuned — including values carried over from a build
/// that had no presets at all.
public enum QualityPreset: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Noticeably smaller files, visibly softer. Good for chat and issue trackers.
    case smallerFile
    /// TriCap's default: full legibility at a sane size.
    case balanced
    /// Keeps fine detail — small text, thin lines — at a larger size.
    case sharper
    /// No downscaling within TriCap's ceiling, top quality factor.
    case maximum
    /// The advanced values do not match any preset.
    case custom

    public var id: String { rawValue }

    /// Presets a user can actually choose. `custom` is a state, not a choice.
    public static var selectable: [QualityPreset] { [.smallerFile, .balanced, .sharper, .maximum] }

    public var displayName: String {
        switch self {
        case .smallerFile: return "Smaller file"
        case .balanced: return "Balanced"
        case .sharper: return "Sharper"
        case .maximum: return "Maximum"
        case .custom: return "Custom"
        }
    }

    /// One line the settings window shows under the picker.
    public var summary: String {
        switch self {
        case .smallerFile:
            return "Smallest files. Fine for screenshots of whole windows; small text may soften."
        case .balanced:
            return "TriCap's default. Small text stays readable at a size that pastes comfortably."
        case .sharper:
            return "Keeps thin lines and small text crisp. Files are noticeably larger."
        case .maximum:
            return "No downscaling and the highest quality factor. Largest files by far."
        case .custom:
            return "Your own values. Pick a preset above to go back to a standard set."
        }
    }

    /// The encoder parameters this preset stands for.
    ///
    /// Every number here is a real argument to a real encoder call — the still quality reaches
    /// `StillImageCodec.encode(quality:)`, the animation quality reaches `WebPConfig.quality`,
    /// and the long edge and frame rate reach `SCStreamConfiguration`. `QualityPresetTests`
    /// asserts that mapping rather than trusting it.
    public struct Values: Equatable, Sendable {
        /// 0–100 for JPEG and static WebP. Ignored by PNG, which is lossless.
        public let stillQuality: Int
        /// Longest edge of a recorded frame, in pixels.
        public let recordingLongEdgePixels: Int
        public let recordingFrameRate: Int
        /// 0–100 for animated WebP.
        public let animationQuality: Int

        public init(
            stillQuality: Int,
            recordingLongEdgePixels: Int,
            recordingFrameRate: Int,
            animationQuality: Int
        ) {
            self.stillQuality = stillQuality
            self.recordingLongEdgePixels = recordingLongEdgePixels
            self.recordingFrameRate = recordingFrameRate
            self.animationQuality = animationQuality
        }
    }

    /// `nil` for ``custom``, which by definition has no canonical values.
    public var values: Values? {
        switch self {
        case .smallerFile:
            return Values(stillQuality: 65, recordingLongEdgePixels: 960, recordingFrameRate: 10, animationQuality: 60)
        case .balanced:
            return Values(stillQuality: 85, recordingLongEdgePixels: 1440, recordingFrameRate: 12, animationQuality: 80)
        case .sharper:
            return Values(stillQuality: 95, recordingLongEdgePixels: 1920, recordingFrameRate: 15, animationQuality: 90)
        case .maximum:
            return Values(
                stillQuality: 100,
                recordingLongEdgePixels: RecordingLimits.longEdgeRange.upperBound,
                recordingFrameRate: 20,
                animationQuality: 95
            )
        case .custom:
            return nil
        }
    }

    /// Which preset (if any) a set of values corresponds to.
    ///
    /// Used both when the user edits an advanced field — to decide whether they have left the
    /// preset — and when loading settings written by a build that had no presets.
    public static func matching(_ values: Values) -> QualityPreset {
        for preset in selectable where preset.values == values {
            return preset
        }
        return .custom
    }
}

extension OutputFormat {
    /// Whether the 0–100 quality factor does anything for this format.
    ///
    /// PNG is lossless: `StillImageCodec.encodePNG` takes no quality argument and ImageIO ignores
    /// `kCGImageDestinationLossyCompressionQuality` for it. Offering a Quality control for PNG
    /// would be a control that does nothing, so the UI hides it — see
    /// `QualityParameterRealityTests`, which encodes the same image at quality 1 and 100 and
    /// asserts the bytes are identical.
    public var usesQualityParameter: Bool {
        switch self {
        case .png: return false
        case .jpeg, .webp, .animatedWebP: return true
        }
    }

    /// Plain-language note about what this format costs and preserves.
    public var qualityExplanation: String {
        switch self {
        case .png:
            return "Lossless — every pixel is preserved exactly. Largest files, and no quality setting to make."
        case .jpeg:
            return "Lossy and universally supported. Photographs compress well; sharp text and flat colour show artefacts first."
        case .webp:
            return "Lossy, typically 25–35% smaller than JPEG at the same quality. Supported by every current browser."
        case .animatedWebP:
            return "Lossy, one quality factor for every frame. Resolution and frame rate affect the file size far more than quality does."
        }
    }

    /// Which of the recording-specific knobs apply.
    public var isRecordingFormat: Bool { isAnimated }
}
