import Foundation

/// Output formats TriCap can write.
public enum OutputFormat: String, Codable, CaseIterable, Sendable {
    case png
    case jpeg
    case webp          // static
    case animatedWebP  // animated

    public var fileExtension: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpg"
        case .webp, .animatedWebP: return "webp"
        }
    }

    public var displayName: String {
        switch self {
        case .png: return "PNG"
        case .jpeg: return "JPEG"
        case .webp: return "WebP"
        case .animatedWebP: return "Animated WebP"
        }
    }

    public var isAnimated: Bool { self == .animatedWebP }
}

/// How a copied reference should be shaped when the file lands inside the vault root.
public enum MarkdownLinkStyle: String, Codable, CaseIterable, Sendable {
    /// `![](assets/shot.png)` — portable CommonMark, works in Obsidian too.
    case markdown
    /// `![[assets/shot.png]]` — Obsidian wiki-link embed.
    case wikiLink

    public var displayName: String {
        switch self {
        case .markdown: return "Markdown  ![](path)"
        case .wikiLink: return "Obsidian wiki-link  ![[path]]"
        }
    }
}

/// Everything the user can configure. Plain `Codable` value type so it can be diffed,
/// snapshotted in tests, and persisted as a single JSON blob in `UserDefaults`.
public struct AppSettings: Codable, Equatable, Sendable {
    public var hotKey: HotKeyCombo
    /// Directory files are written to.
    public var saveDirectoryPath: String
    /// Optional Markdown/Obsidian vault root. When the output lands inside it, TriCap
    /// copies a *relative* reference instead of an absolute path.
    public var markdownVaultRootPath: String?
    public var markdownLinkStyle: MarkdownLinkStyle

    public var stillFormat: OutputFormat
    /// 0...100, used for JPEG and static WebP. PNG ignores it — see `OutputFormat.usesQualityParameter`.
    public var stillQuality: Int

    /// The named quality choice these values correspond to.
    ///
    /// Derived, not authoritative: ``reconcileQualityPreset()`` recomputes it from the advanced
    /// values after every edit, so a hand-tuned setting always reads as ``QualityPreset/custom``
    /// and can never be quietly replaced by a preset's numbers.
    public var qualityPreset: QualityPreset

    public var recordingLimits: RecordingLimits
    public var animatedWebPOptions: AnimatedWebPOptions
    /// Seconds of countdown before a recording starts. 0 disables it.
    public var countdownSeconds: Int
    /// Copy the Markdown/absolute reference to the clipboard after a successful export.
    public var copyReferenceAfterExport: Bool
    /// Also place the rendered image itself on the pasteboard.
    public var copyImageAfterExport: Bool
    /// Filename prefix; the timestamp is appended.
    public var filenamePrefix: String

    public static let countdownRange = 0...10

    /// What a fresh install starts on.
    public static let defaultPreset: QualityPreset = .balanced

    public init(
        hotKey: HotKeyCombo = .default,
        saveDirectoryPath: String = AppSettings.defaultSaveDirectory.path,
        markdownVaultRootPath: String? = nil,
        markdownLinkStyle: MarkdownLinkStyle = .markdown,
        stillFormat: OutputFormat = .png,
        stillQuality: Int = AppSettings.defaultPreset.values!.stillQuality,
        qualityPreset: QualityPreset = AppSettings.defaultPreset,
        recordingLimits: RecordingLimits = .default,
        animatedWebPOptions: AnimatedWebPOptions = .default,
        countdownSeconds: Int = 3,
        copyReferenceAfterExport: Bool = true,
        copyImageAfterExport: Bool = false,
        filenamePrefix: String = "TriCap"
    ) {
        self.hotKey = hotKey
        self.saveDirectoryPath = saveDirectoryPath
        self.markdownVaultRootPath = markdownVaultRootPath
        self.markdownLinkStyle = markdownLinkStyle
        self.stillFormat = stillFormat
        self.stillQuality = stillQuality.clamped(to: 0...100)
        self.qualityPreset = qualityPreset
        self.recordingLimits = recordingLimits
        self.animatedWebPOptions = animatedWebPOptions
        self.countdownSeconds = countdownSeconds.clamped(to: Self.countdownRange)
        self.copyReferenceAfterExport = copyReferenceAfterExport
        self.copyImageAfterExport = copyImageAfterExport
        self.filenamePrefix = filenamePrefix.isEmpty ? "TriCap" : filenamePrefix
    }

    public static var defaultSaveDirectory: URL {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return pictures.appendingPathComponent("TriCap", isDirectory: true)
    }

    public var saveDirectoryURL: URL {
        URL(fileURLWithPath: (saveDirectoryPath as NSString).expandingTildeInPath, isDirectory: true)
    }

    public var markdownVaultRootURL: URL? {
        guard let path = markdownVaultRootPath, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    // MARK: - Quality presets

    /// The advanced values, in the shape ``QualityPreset`` compares against.
    public var qualityValues: QualityPreset.Values {
        QualityPreset.Values(
            stillQuality: stillQuality,
            recordingLongEdgePixels: recordingLimits.maxLongEdgePixels,
            recordingFrameRate: recordingLimits.frameRate,
            animationQuality: animatedWebPOptions.quality
        )
    }

    /// Write a preset's values into the real encoder parameters.
    ///
    /// Selecting `.custom` is a no-op: there are no canonical values to write, and clobbering the
    /// user's numbers with a preset's would be exactly the accident this design avoids.
    public mutating func applyQualityPreset(_ preset: QualityPreset) {
        guard let values = preset.values else { return }
        stillQuality = values.stillQuality
        recordingLimits.maxLongEdgePixels = values.recordingLongEdgePixels
        recordingLimits.frameRate = values.recordingFrameRate
        animatedWebPOptions.quality = values.animationQuality
        // Read the label back off the values rather than trusting the argument: `RecordingLimits`
        // clamps what it is given, so a preset whose numbers fall outside the allowed range would
        // otherwise claim to be applied when it is not.
        qualityPreset = QualityPreset.matching(qualityValues)
    }

    /// A copy whose ``qualityPreset`` matches its values. Non-mutating so an observable store can
    /// compare before assigning and avoid an update loop.
    public func reconciledForQualityPreset() -> AppSettings {
        var copy = self
        copy.reconcileQualityPreset()
        return copy
    }

    /// Recompute ``qualityPreset`` from the current values. Cheap; safe to call after any edit.
    public mutating func reconcileQualityPreset() {
        qualityPreset = QualityPreset.matching(qualityValues)
    }

    /// The quality factor that actually applies to `stillFormat`, or `nil` when the format is
    /// lossless and no quality control should be shown at all.
    public var effectiveStillQuality: Int? {
        stillFormat.usesQualityParameter ? stillQuality : nil
    }

    /// Decoding tolerates missing keys so a settings blob written by an older build keeps working.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = AppSettings()
        hotKey = try c.decodeIfPresent(HotKeyCombo.self, forKey: .hotKey) ?? fallback.hotKey
        saveDirectoryPath = try c.decodeIfPresent(String.self, forKey: .saveDirectoryPath) ?? fallback.saveDirectoryPath
        markdownVaultRootPath = try c.decodeIfPresent(String.self, forKey: .markdownVaultRootPath)
        markdownLinkStyle = try c.decodeIfPresent(MarkdownLinkStyle.self, forKey: .markdownLinkStyle) ?? fallback.markdownLinkStyle
        stillFormat = try c.decodeIfPresent(OutputFormat.self, forKey: .stillFormat) ?? fallback.stillFormat
        stillQuality = (try c.decodeIfPresent(Int.self, forKey: .stillQuality) ?? fallback.stillQuality).clamped(to: 0...100)
        recordingLimits = try c.decodeIfPresent(RecordingLimits.self, forKey: .recordingLimits) ?? fallback.recordingLimits
        animatedWebPOptions = try c.decodeIfPresent(AnimatedWebPOptions.self, forKey: .animatedWebPOptions) ?? fallback.animatedWebPOptions

        // A blob written before presets existed has no `qualityPreset` key. Rather than assuming
        // a preset — which would rewrite whatever quality the user had been getting — the stored
        // values decide: they map to a preset only if they match one exactly, and otherwise the
        // settings load as `.custom` with every number preserved.
        if let stored = try c.decodeIfPresent(QualityPreset.self, forKey: .qualityPreset) {
            qualityPreset = stored
        } else {
            qualityPreset = .custom
        }
        countdownSeconds = (try c.decodeIfPresent(Int.self, forKey: .countdownSeconds) ?? fallback.countdownSeconds).clamped(to: Self.countdownRange)
        copyReferenceAfterExport = try c.decodeIfPresent(Bool.self, forKey: .copyReferenceAfterExport) ?? fallback.copyReferenceAfterExport
        copyImageAfterExport = try c.decodeIfPresent(Bool.self, forKey: .copyImageAfterExport) ?? fallback.copyImageAfterExport
        filenamePrefix = try c.decodeIfPresent(String.self, forKey: .filenamePrefix) ?? fallback.filenamePrefix
    }
}
