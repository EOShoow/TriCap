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

/// Which still flow a plain "screenshot" request means.
///
/// Historically this decided what happened *after* a still capture; since the picker gained the
/// three-flow cycle it instead resolves the still *family* — the menu's "Capture Region" and the
/// ``HotKeyLaunchMode/alwaysStill`` launch mode both map through it, so its old meaning survives.
public enum StillCaptureAction: String, Codable, CaseIterable, Sendable, Identifiable {
    /// The quick flow: straight to the clipboard, with a copy saved to the output folder in the
    /// background. TriCap's default: the common case is pasting a screenshot into something, and
    /// that should not cost a window and a Save.
    case copyToClipboard
    /// Open the annotation editor, where saving is an explicit step.
    case openEditor

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .copyToClipboard: return "Copy to clipboard"
        case .openEditor: return "Open the editor"
        }
    }

    public var summary: String {
        switch self {
        case .copyToClipboard:
            return "The fastest path: capture, then paste. A copy also lands in your save folder in the background."
        case .openEditor:
            return "Annotate first, then save. Press R in the picker (or use “Screenshot and Edit…” in the menu) to do this once without changing the default."
        }
    }
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
    /// Opens the region picker for a screenshot or a recording.
    public var hotKey: HotKeyCombo
    /// Pins whatever image is on the clipboard as a floating window.
    public var pinHotKey: HotKeyCombo
    /// What happens after a still capture succeeds.
    public var stillCaptureAction: StillCaptureAction
    /// What the capture hot key opens: a fixed mode, or whatever completed last.
    public var hotKeyLaunchMode: HotKeyLaunchMode
    /// Legacy mirror of ``lastCaptureFlow``, still written so a downgraded build keeps its
    /// two-state memory. Never read at runtime except as the migration seed for blobs written
    /// before flows existed.
    public var lastCaptureIntent: CaptureIntent
    /// The flow of the last *completed* selection. Only consulted by
    /// ``HotKeyLaunchMode/rememberLast``; a cancelled picker never updates it.
    public var lastCaptureFlow: CaptureFlow
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
        pinHotKey: HotKeyCombo = .defaultPin,
        stillCaptureAction: StillCaptureAction = .copyToClipboard,
        hotKeyLaunchMode: HotKeyLaunchMode = .rememberLast,
        lastCaptureIntent: CaptureIntent = .still,
        lastCaptureFlow: CaptureFlow = .quickStill,
        saveDirectoryPath: String = AppSettings.defaultSaveDirectory.path,
        markdownVaultRootPath: String? = nil,
        markdownLinkStyle: MarkdownLinkStyle = .markdown,
        stillFormat: OutputFormat = .png,
        stillQuality: Int = AppSettings.defaultPreset.values!.stillQuality,
        qualityPreset: QualityPreset = AppSettings.defaultPreset,
        // Derived from the default preset for the same reason `stillQuality` is: a fresh install
        // must actually start on the preset it claims. `RecordingLimits.default` stays the
        // type-neutral 12 fps used by tools and tests that want an explicit baseline.
        recordingLimits: RecordingLimits = RecordingLimits(
            frameRate: AppSettings.defaultPreset.values!.recordingFrameRate,
            maxLongEdgePixels: AppSettings.defaultPreset.values!.recordingLongEdgePixels
        ),
        animatedWebPOptions: AnimatedWebPOptions = .default,
        countdownSeconds: Int = 3,
        copyReferenceAfterExport: Bool = true,
        copyImageAfterExport: Bool = false,
        filenamePrefix: String = "TriCap"
    ) {
        self.hotKey = hotKey
        self.pinHotKey = pinHotKey
        self.stillCaptureAction = stillCaptureAction
        self.hotKeyLaunchMode = hotKeyLaunchMode
        self.lastCaptureIntent = lastCaptureIntent
        self.lastCaptureFlow = lastCaptureFlow
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

    /// The result of one settings edit: what should be stored, and what an observer must be told.
    public struct Update: Equatable, Sendable {
        /// The values as they were before the edit.
        public let previous: AppSettings
        /// The values to store — the proposal after quality-preset normalisation.
        public let current: AppSettings
        /// `false` when normalisation collapsed the edit back to where it started.
        public var isEffective: Bool { previous != current }

        public init(previous: AppSettings, current: AppSettings) {
            self.previous = previous
            self.current = current
        }
    }

    /// Normalise a proposed edit and pair it with the values it actually replaces.
    ///
    /// This exists because normalisation must not be observable as a second edit. A store that
    /// reacts to its own normalising write reports `proposal → normalised` and loses the original
    /// `previous`, which silently swallows anything else the same edit changed.
    ///
    /// The case that broke: settings loaded from a build without presets carry
    /// ``QualityPreset/custom`` even when their values happen to match a preset exactly. The very
    /// first edit — say, only the hot key — therefore also triggers a relabel to that preset. If
    /// the observer is handed `proposal → normalised`, both sides already have the new hot key, so
    /// "did the hot key change?" answers *no* and the shortcut is never re-registered.
    public static func resolveUpdate(previous: AppSettings, proposed: AppSettings) -> Update {
        Update(previous: previous, current: proposed.reconciledForQualityPreset())
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
        // Absent in every blob written before pinning existed: fall back to the shipped F3.
        pinHotKey = try c.decodeIfPresent(HotKeyCombo.self, forKey: .pinHotKey) ?? fallback.pinHotKey
        stillCaptureAction = c.decodeTolerantly(StillCaptureAction.self, forKey: .stillCaptureAction)
            ?? fallback.stillCaptureAction
        hotKeyLaunchMode = c.decodeTolerantly(HotKeyLaunchMode.self, forKey: .hotKeyLaunchMode)
            ?? fallback.hotKeyLaunchMode
        lastCaptureIntent = c.decodeTolerantly(CaptureIntent.self, forKey: .lastCaptureIntent)
            ?? fallback.lastCaptureIntent
        // Blobs from before flows existed recorded still/recording plus the still-action setting;
        // together those say exactly which of the three flows the user last completed.
        lastCaptureFlow = c.decodeTolerantly(CaptureFlow.self, forKey: .lastCaptureFlow)
            ?? CaptureFlow(legacyIntent: lastCaptureIntent, stillAction: stillCaptureAction)
        saveDirectoryPath = try c.decodeIfPresent(String.self, forKey: .saveDirectoryPath) ?? fallback.saveDirectoryPath
        markdownVaultRootPath = try c.decodeIfPresent(String.self, forKey: .markdownVaultRootPath)
        markdownLinkStyle = c.decodeTolerantly(MarkdownLinkStyle.self, forKey: .markdownLinkStyle) ?? fallback.markdownLinkStyle
        stillFormat = c.decodeTolerantly(OutputFormat.self, forKey: .stillFormat) ?? fallback.stillFormat
        stillQuality = (try c.decodeIfPresent(Int.self, forKey: .stillQuality) ?? fallback.stillQuality).clamped(to: 0...100)
        recordingLimits = try c.decodeIfPresent(RecordingLimits.self, forKey: .recordingLimits) ?? fallback.recordingLimits
        animatedWebPOptions = try c.decodeIfPresent(AnimatedWebPOptions.self, forKey: .animatedWebPOptions) ?? fallback.animatedWebPOptions

        // `qualityPreset` is a derived label, so persisted numbers are the authority at the load
        // boundary too. This keeps every old/custom value verbatim while preventing a stale label
        // (for example the withdrawn 20 fps Balanced preset) from promising today's 12 fps values.
        qualityPreset = .custom
        countdownSeconds = (try c.decodeIfPresent(Int.self, forKey: .countdownSeconds) ?? fallback.countdownSeconds).clamped(to: Self.countdownRange)
        copyReferenceAfterExport = try c.decodeIfPresent(Bool.self, forKey: .copyReferenceAfterExport) ?? fallback.copyReferenceAfterExport
        copyImageAfterExport = try c.decodeIfPresent(Bool.self, forKey: .copyImageAfterExport) ?? fallback.copyImageAfterExport
        filenamePrefix = try c.decodeIfPresent(String.self, forKey: .filenamePrefix) ?? fallback.filenamePrefix
        qualityPreset = QualityPreset.matching(qualityValues)
    }
}
