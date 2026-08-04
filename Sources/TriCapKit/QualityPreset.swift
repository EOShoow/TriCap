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
    /// The largest frame and the highest frame rate TriCap's presets go to.
    ///
    /// Deliberately *not* called "Original size": it caps the long edge at 3840 px, which is a
    /// downscale on any display taller or wider than that, and it does not raise the frame rate to
    /// the 30 fps ceiling or the quality factor to 100 — both of which would multiply the memory a
    /// recording holds for a difference few people could see.
    case highDetail
    /// The advanced values do not match any preset.
    case custom

    public var id: String { rawValue }

    /// Presets a user can actually choose. `custom` is a state, not a choice.
    public static var selectable: [QualityPreset] { [.smallerFile, .balanced, .sharper, .highDetail] }

    public var displayName: String {
        switch self {
        case .smallerFile: return "Smaller file"
        case .balanced: return "Balanced"
        case .sharper: return "Sharper"
        case .highDetail: return "Up to 4K"
        case .custom: return "Custom"
        }
    }

    /// One line the settings window shows under the picker.
    public var summary: String {
        switch self {
        case .smallerFile:
            return "Smallest files. 12 fps recordings; small text may soften."
        case .balanced:
            return "TriCap's default. 12 fps recordings with steadier frame timing; small text stays readable."
        case .sharper:
            return "Keeps thin lines and small text crisp. Files are noticeably larger."
        case .highDetail:
            return "Recordings up to 3840 px on the long edge at 20 fps. Much larger files, and a recording holds a lot more in memory."
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
            return Values(stillQuality: 65, recordingLongEdgePixels: 960, recordingFrameRate: 12, animationQuality: 60)
        case .balanced:
            // The attempted 20 fps promotion was withdrawn after its benchmark driver was found
            // to be excluded from capture and SCK cadence shortfalls were not measured. Keep the
            // proven 12 fps default until a corrected 3×15 s gate can run without compositor SKIP.
            return Values(stillQuality: 85, recordingLongEdgePixels: 1440, recordingFrameRate: 12, animationQuality: 80)
        case .sharper:
            return Values(stillQuality: 95, recordingLongEdgePixels: 1920, recordingFrameRate: 15, animationQuality: 90)
        case .highDetail:
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

    /// Raw values written by earlier builds, mapped to the case that replaced them.
    ///
    /// A rename changes the string a preset persists as. Without this table an upgrading user's
    /// stored `"maximum"` would decode as ``custom``: their numbers would survive, but the label
    /// naming them would not, and the settings window would show *Custom* for values they had
    /// explicitly picked a preset for.
    ///
    /// Only *known* historical names belong here. A raw value from a newer build is still
    /// unknown, and still degrades to ``custom``.
    public static let renamedRawValues: [String: QualityPreset] = [
        "maximum": .highDetail,
    ]

    /// Resolve a stored raw value, honouring renames. `nil` when the value is genuinely unknown.
    public static func fromPersistedRawValue(_ rawValue: String) -> QualityPreset? {
        QualityPreset(rawValue: rawValue) ?? renamedRawValues[rawValue]
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
            return "Lossy, and readable by essentially anything. Photographs compress well; sharp text and flat colour tend to show artefacts first."
        case .webp:
            return "Lossy, and usually smaller than JPEG at a comparable setting — how much smaller depends on the image. Supported by current versions of the major browsers."
        case .animatedWebP:
            return "Lossy, with one quality factor applied to every frame. For a recording, resolution and frame rate usually matter more to the file size than the quality factor does."
        }
    }

    /// Which of the recording-specific knobs apply.
    public var isRecordingFormat: Bool { isAnimated }
}
