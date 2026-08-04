import Foundation
import Testing
@testable import TriCapKit

@Suite("Quality presets")
struct QualityPresetTests {

    @Test("Custom is a state, not something the user picks")
    func customIsNotSelectable() {
        #expect(!QualityPreset.selectable.contains(.custom))
        #expect(QualityPreset.custom.values == nil)
        #expect(QualityPreset.selectable.allSatisfy { $0.values != nil })
    }

    @Test("Every selectable preset maps to a distinct set of values")
    func presetsAreDistinct() {
        let all = QualityPreset.selectable.compactMap(\.values)
        #expect(all.count == QualityPreset.selectable.count)
        // If two presets shared values, `matching` could not tell them apart and selecting one
        // would silently relabel itself as the other.
        for (index, values) in all.enumerated() {
            for other in all[(index + 1)...] {
                #expect(values != other)
            }
        }
    }

    @Test("Presets are ordered from smallest to largest on the quality axes")
    func presetsAreMonotonic() {
        // Frame rate is deliberately NOT on this list any more. The ladder is a quality ladder —
        // still quality, resolution and animation quality all rise monotonically — but fps is a
        // throughput trade against resolution: Balanced runs 1440 px at 20 fps (measured to hold
        // on the real capture path), while Sharper spends the same budget on 1920 px at 15 fps.
        // Making fps monotonic again would mean raising Sharper past what the pre-encoder
        // sustains at 1920 px (it abandons at 20 fps there on worst-case content) or capping
        // Balanced below what it can honestly deliver.
        let ordered = QualityPreset.selectable.compactMap(\.values)
        for (a, b) in zip(ordered, ordered.dropFirst()) {
            #expect(b.stillQuality >= a.stillQuality)
            #expect(b.recordingLongEdgePixels >= a.recordingLongEdgePixels)
            #expect(b.animationQuality >= a.animationQuality)
        }
    }

    @Test("The evidence-gated frame rates are exactly the shipped ones")
    func gatedFrameRates() {
        // Pinned so a casual "just bump it to 30" cannot land without re-running the gate matrix
        // (release plan: 0 dropped frames, no pre-encode abandonment, tail ≤ 2 s, retained
        // ≤ 384 MB, and for 30 fps a p95 encode ≤ 26.7 ms that no measured configuration meets).
        #expect(QualityPreset.smallerFile.values?.recordingFrameRate == 12)
        #expect(QualityPreset.balanced.values?.recordingFrameRate == 20)
        #expect(QualityPreset.sharper.values?.recordingFrameRate == 15)
        #expect(QualityPreset.highDetail.values?.recordingFrameRate == 20)
    }

    @Test("A pre-upgrade Balanced user keeps their exact values and becomes Custom")
    func oldBalancedValuesRelabelAsCustom() {
        // Stored settings hold real numbers; the preset label is derived by matching. Changing
        // the Balanced definition therefore must not touch anyone's stored 12 fps — their label
        // flips to Custom and every number stays exactly as they had it. Nobody's recordings
        // change behind their back; picking Balanced again opts into the new 20 fps.
        let oldBalanced = QualityPreset.Values(
            stillQuality: 85, recordingLongEdgePixels: 1440, recordingFrameRate: 12, animationQuality: 80
        )
        #expect(QualityPreset.matching(oldBalanced) == .custom)
    }

    @Test("Every preset's values are inside the ranges the encoders accept")
    func presetsAreInRange() {
        for preset in QualityPreset.selectable {
            let values = preset.values!
            #expect(AnimatedWebPOptions.qualityRange.contains(values.animationQuality))
            #expect((0...100).contains(values.stillQuality))
            #expect(RecordingLimits.longEdgeRange.contains(values.recordingLongEdgePixels))
            #expect(RecordingLimits.frameRateRange.contains(values.recordingFrameRate))
        }
    }

    @Test("matching() round-trips every preset")
    func matchingRoundTrips() {
        for preset in QualityPreset.selectable {
            #expect(QualityPreset.matching(preset.values!) == preset)
        }
    }

    @Test("The top preset does not promise more than its values deliver")
    func topPresetCopyIsAccurate() {
        // It was called "Maximum" and described as "no downscaling and the highest quality
        // factor", while actually capping the long edge at 3840 px and stopping at 20 fps / 95.
        let preset = QualityPreset.highDetail
        let values = preset.values!

        #expect(!preset.displayName.lowercased().contains("maximum"))
        #expect(!preset.summary.lowercased().contains("no downscaling"))
        // The summary quotes the real cap, so the name and the numbers cannot drift apart.
        #expect(preset.summary.contains("\(values.recordingLongEdgePixels)"))
        #expect(preset.summary.contains("\(values.recordingFrameRate)"))

        // And it genuinely is not the encoder ceiling on every axis.
        #expect(values.recordingFrameRate < RecordingLimits.frameRateRange.upperBound)
        #expect(values.animationQuality < AnimatedWebPOptions.qualityRange.upperBound)
    }

    @Test("No format explanation states an unmeasured ratio as fact")
    func formatCopyAvoidsInventedNumbers() {
        // TriCap has not benchmarked WebP against JPEG on representative screen content, so it
        // must not quote a percentage. Any digit here would be one.
        for format in OutputFormat.allCases {
            let text = format.qualityExplanation
            #expect(!text.contains("%"), "\(format) quotes a percentage it cannot support")
            #expect(
                text.rangeOfCharacter(from: CharacterSet.decimalDigits) == nil,
                "\(format) states a bare number as fact: \(text)"
            )
        }
    }

    @Test("Values that belong to no preset are Custom")
    func unmatchedValuesAreCustom() {
        let odd = QualityPreset.Values(
            stillQuality: 77, recordingLongEdgePixels: 1234, recordingFrameRate: 9, animationQuality: 41
        )
        #expect(QualityPreset.matching(odd) == .custom)
    }
}

@Suite("Quality preset ↔ encoder parameters")
struct QualityPresetApplicationTests {

    @Test("Applying a preset writes every real encoder parameter", arguments: QualityPreset.selectable)
    func applyingWritesEncoderParameters(preset: QualityPreset) {
        var settings = AppSettings()
        settings.applyQualityPreset(preset)

        let values = preset.values!
        // These four fields are the ones that actually reach an encoder call.
        #expect(settings.stillQuality == values.stillQuality)
        #expect(settings.recordingLimits.maxLongEdgePixels == values.recordingLongEdgePixels)
        #expect(settings.recordingLimits.frameRate == values.recordingFrameRate)
        #expect(settings.animatedWebPOptions.quality == values.animationQuality)
        #expect(settings.qualityPreset == preset)
    }

    @Test("A fresh install starts on the default preset with matching values")
    func freshInstallIsConsistent() {
        let settings = AppSettings()
        #expect(settings.qualityPreset == AppSettings.defaultPreset)
        #expect(settings.qualityPreset == QualityPreset.matching(settings.qualityValues))
        #expect(settings.qualityValues == AppSettings.defaultPreset.values)
    }

    @Test("Selecting Custom does not overwrite the user's values")
    func applyingCustomIsANoOp() {
        var settings = AppSettings()
        settings.stillQuality = 73
        settings.recordingLimits.frameRate = 7
        let before = settings

        settings.applyQualityPreset(.custom)
        #expect(settings.stillQuality == before.stillQuality)
        #expect(settings.recordingLimits.frameRate == before.recordingLimits.frameRate)
    }

    @Test("Editing any advanced value drops the settings to Custom", arguments: [0, 1, 2, 3])
    func editingAnAdvancedValueBecomesCustom(axis: Int) {
        var settings = AppSettings()
        settings.applyQualityPreset(.balanced)
        #expect(settings.qualityPreset == .balanced)

        switch axis {
        case 0: settings.stillQuality = 71
        case 1: settings.recordingLimits.maxLongEdgePixels = 1600
        case 2: settings.recordingLimits.frameRate = 24
        default: settings.animatedWebPOptions.quality = 55
        }
        settings.reconcileQualityPreset()
        #expect(settings.qualityPreset == .custom)
    }

    @Test("Editing back onto a preset's exact values restores that preset's name")
    func editingBackOntoAPresetRestoresIt() {
        var settings = AppSettings()
        settings.applyQualityPreset(.balanced)
        settings.stillQuality = 71
        settings.reconcileQualityPreset()
        #expect(settings.qualityPreset == .custom)

        settings.stillQuality = QualityPreset.balanced.values!.stillQuality
        settings.reconcileQualityPreset()
        #expect(settings.qualityPreset == .balanced)
    }

    @Test("A preset's label is read back from the clamped values, not assumed")
    func labelReflectsClamping() {
        // `RecordingLimits` clamps whatever it is given; `applyQualityPreset` re-derives the label
        // afterwards so it can never claim a preset that was not actually applied.
        var settings = AppSettings()
        settings.applyQualityPreset(.highDetail)
        #expect(settings.recordingLimits.maxLongEdgePixels == RecordingLimits.longEdgeRange.upperBound)
        #expect(settings.qualityPreset == .highDetail)
    }
}

@Suite("Settings migration")
struct SettingsMigrationTests {

    private func decode(_ json: String) throws -> AppSettings {
        try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
    }

    @Test("A blob from a build without presets keeps its values and reads as Custom")
    func legacyBlobIsNotOverwritten() throws {
        // This is the guarantee that matters: the old default still quality was 90, which is not
        // any preset's value. Snapping it to a preset would silently change the user's output.
        let legacy = """
        {"stillQuality": 90, "stillFormat": "jpeg",
         "recordingLimits": {"frameRate": 12, "maxDuration": 15, "maxLongEdgePixels": 1440, "maxFrameBufferBytes": 536870912},
         "animatedWebPOptions": {"quality": 80, "loopCount": 0, "lossless": false, "method": 4}}
        """
        let settings = try decode(legacy)

        #expect(settings.stillQuality == 90)
        #expect(settings.recordingLimits.maxLongEdgePixels == 1440)
        #expect(settings.animatedWebPOptions.quality == 80)
        #expect(settings.qualityPreset == .custom)
    }

    @Test("A legacy blob that happens to match a preset is still loaded verbatim")
    func legacyBlobMatchingAPreset() throws {
        // Uses the CURRENT Balanced numbers (20 fps). A blob carrying the pre-upgrade 12 fps
        // values is the other case: loaded verbatim and reconciled to .custom — pinned by
        // `oldBalancedValuesRelabelAsCustom`.
        let legacy = """
        {"stillQuality": 85,
         "recordingLimits": {"frameRate": 20, "maxDuration": 15, "maxLongEdgePixels": 1440, "maxFrameBufferBytes": 536870912},
         "animatedWebPOptions": {"quality": 80, "loopCount": 0, "lossless": false, "method": 4}}
        """
        let settings = try decode(legacy)
        #expect(settings.qualityValues == QualityPreset.balanced.values)
        // Decoding does not relabel; the store reconciles on first edit, and the values are already
        // right either way.
        #expect(settings.reconciledForQualityPreset().qualityPreset == .balanced)
    }

    @Test("An empty blob falls back to the shipped defaults")
    func emptyBlob() throws {
        let settings = try decode("{}")
        #expect(settings.stillQuality == AppSettings.defaultPreset.values!.stillQuality)
        // The shipped default is the preset-derived one (20 fps Balanced), not the type-neutral
        // `RecordingLimits.default` baseline.
        #expect(settings.recordingLimits == AppSettings().recordingLimits)
        #expect(settings.recordingLimits.frameRate == QualityPreset.balanced.values?.recordingFrameRate)
    }

    @Test("A current blob round-trips through Codable unchanged")
    func roundTrip() throws {
        var original = AppSettings()
        original.applyQualityPreset(.sharper)
        original.markdownVaultRootPath = "/tmp/vault"
        original.filenamePrefix = "Shot"

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded == original)
        #expect(decoded.qualityPreset == .sharper)
    }

    @Test("A preset renamed since the blob was written keeps its label")
    func renamedPresetMigrates() throws {
        // The build before the rename persisted `.maximum` as "maximum". Tolerant decoding alone
        // would have degraded that to Custom: the numbers survive, but the user's explicit preset
        // choice is silently forgotten.
        let settings = try decode(
            #"{"qualityPreset": "maximum", "stillQuality": 100, "filenamePrefix": "Shot", "markdownVaultRootPath": "/tmp/vault", "recordingLimits": {"frameRate": 20, "maxDuration": 15, "maxLongEdgePixels": 3840, "maxFrameBufferBytes": 536870912}, "animatedWebPOptions": {"quality": 95, "loopCount": 0, "lossless": false, "method": 4}}"#
        )

        #expect(settings.qualityPreset == .highDetail)
        // Every other field, and every number, survives the migration untouched.
        #expect(settings.stillQuality == 100)
        #expect(settings.recordingLimits.frameRate == 20)
        #expect(settings.recordingLimits.maxLongEdgePixels == 3840)
        #expect(settings.animatedWebPOptions.quality == 95)
        #expect(settings.filenamePrefix == "Shot")
        #expect(settings.markdownVaultRootPath == "/tmp/vault")
        // The migrated label agrees with the values it names.
        #expect(settings.reconciledForQualityPreset().qualityPreset == .highDetail)
    }

    @Test("The rename table resolves the old name and leaves the new one alone")
    func renameTableIsConsistent() {
        #expect(QualityPreset.fromPersistedRawValue("maximum") == .highDetail)
        #expect(QualityPreset.fromPersistedRawValue("highDetail") == .highDetail)
        #expect(QualityPreset.fromPersistedRawValue("someFuturePreset") == nil)

        // Every alias must point at a case that still exists, and must not shadow a live raw value.
        for (alias, target) in QualityPreset.renamedRawValues {
            #expect(QualityPreset.allCases.contains(target))
            #expect(QualityPreset(rawValue: alias) == nil, "\(alias) is still a live raw value")
        }
    }

    @Test("Every current preset still round-trips through its own raw value")
    func currentPresetsRoundTrip() {
        for preset in QualityPreset.allCases {
            #expect(QualityPreset.fromPersistedRawValue(preset.rawValue) == preset)
        }
    }

    @Test("An unknown quality preset falls back to Custom without discarding anything else")
    func unknownPresetDoesNotDestroySettings() throws {
        // A preset renamed since the blob was written, or one from a newer build. Strict decoding
        // would throw, and `SettingsStore`'s `try?` would then drop the user's save folder, vault
        // root and hot key along with it.
        let settings = try decode(
            #"{"qualityPreset": "someFuturePreset", "stillQuality": 73, "filenamePrefix": "Shot", "markdownVaultRootPath": "/tmp/vault"}"#
        )
        #expect(settings.qualityPreset == .custom)
        #expect(settings.stillQuality == 73)
        #expect(settings.filenamePrefix == "Shot")
        #expect(settings.markdownVaultRootPath == "/tmp/vault")
    }

    @Test("An unknown output format or link style also degrades gracefully")
    func unknownEnumsDegradeGracefully() throws {
        let settings = try decode(
            #"{"stillFormat": "avif", "markdownLinkStyle": "orgMode", "filenamePrefix": "Keep"}"#
        )
        #expect(settings.stillFormat == AppSettings().stillFormat)
        #expect(settings.markdownLinkStyle == AppSettings().markdownLinkStyle)
        #expect(settings.filenamePrefix == "Keep", "the rest of the blob must survive")
    }

    @Test("A known preset raw value still decodes")
    func knownPresetDecodes() throws {
        let settings = try decode(#"{"qualityPreset": "sharper"}"#)
        #expect(settings.qualityPreset == .sharper)
    }

    @Test("An out-of-range legacy value is clamped rather than rejected")
    func clampsOutOfRange() throws {
        let settings = try decode("""
        {"stillQuality": 500,
         "recordingLimits": {"frameRate": 999, "maxDuration": 9999, "maxLongEdgePixels": 99999, "maxFrameBufferBytes": 1}}
        """)
        #expect(settings.stillQuality == 100)
        #expect(settings.recordingLimits.frameRate == RecordingLimits.frameRateRange.upperBound)
        #expect(settings.recordingLimits.maxLongEdgePixels == RecordingLimits.longEdgeRange.upperBound)
    }
}

@Suite("Format-conditional quality controls")
struct FormatQualityDisplayTests {

    @Test("Only lossy formats advertise a quality parameter")
    func lossyFormatsOnly() {
        #expect(!OutputFormat.png.usesQualityParameter)
        #expect(OutputFormat.jpeg.usesQualityParameter)
        #expect(OutputFormat.webp.usesQualityParameter)
        #expect(OutputFormat.animatedWebP.usesQualityParameter)
    }

    @Test("effectiveStillQuality is nil exactly when the format is lossless")
    func effectiveQualityMatchesFormat() {
        var settings = AppSettings()
        settings.stillQuality = 88

        settings.stillFormat = .png
        #expect(settings.effectiveStillQuality == nil)

        for format in [OutputFormat.jpeg, .webp] {
            settings.stillFormat = format
            #expect(settings.effectiveStillQuality == 88)
        }
    }

    @Test("Every format explains itself in plain language")
    func everyFormatHasAnExplanation() {
        for format in OutputFormat.allCases {
            #expect(!format.qualityExplanation.isEmpty)
            #expect(!format.displayName.isEmpty)
        }
        #expect(OutputFormat.png.qualityExplanation.lowercased().contains("lossless"))
    }

    @Test("Only the animated format is a recording format")
    func recordingFormat() {
        #expect(OutputFormat.animatedWebP.isRecordingFormat)
        for format in [OutputFormat.png, .jpeg, .webp] {
            #expect(!format.isRecordingFormat)
        }
    }
}
