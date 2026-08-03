import Foundation
import Testing
@testable import TriCapKit

/// One user edit must produce exactly one notification, carrying the values as they were *before*
/// that edit — not as they were after the store's own normalising rewrite.
@Suite("Settings update resolution")
struct SettingsUpdateTests {

    /// Settings as a build without quality presets would have left them: the label is `.custom`
    /// (the decoder never invents one), while the values happen to match a preset exactly.
    private func legacySettingsMatchingBalanced() -> AppSettings {
        var settings = AppSettings()
        settings.applyQualityPreset(.balanced)
        settings.qualityPreset = .custom
        return settings
    }

    @Test("Legacy settings that match a preset are relabelled on the first edit")
    func legacyRelabelHappens() {
        let previous = legacySettingsMatchingBalanced()
        #expect(previous.qualityPreset == .custom)
        #expect(previous.qualityValues == QualityPreset.balanced.values)

        var proposed = previous
        proposed.filenamePrefix = "Shot"

        let update = AppSettings.resolveUpdate(previous: previous, proposed: proposed)
        #expect(update.current.qualityPreset == .balanced)
        #expect(update.isEffective)
    }

    @Test("Changing only the hot key is still visible after the preset relabel")
    func hotKeyChangeSurvivesRelabel() {
        // The regression: the store used to hand the observer `proposal → normalised`. Both of
        // those already carry the new hot key, so `previous.hotKey != current.hotKey` answered
        // *no* and `AppDelegate` never re-registered the shortcut. The user's new shortcut was
        // persisted but dead until the next launch.
        let previous = legacySettingsMatchingBalanced()
        let newCombo = HotKeyCombo(
            keyCode: 17,
            carbonModifiers: HotKeyCombo.CarbonModifier.command.rawValue
                | HotKeyCombo.CarbonModifier.control.rawValue
        )

        var proposed = previous
        proposed.hotKey = newCombo

        let update = AppSettings.resolveUpdate(previous: previous, proposed: proposed)

        #expect(update.previous.hotKey == previous.hotKey)
        #expect(update.current.hotKey == newCombo)
        #expect(update.previous.hotKey != update.current.hotKey, "the hot-key change must be observable")
        // …and the normalisation still happened.
        #expect(update.current.qualityPreset == .balanced)
    }

    @Test("Every field of a multi-field edit stays visible across normalisation")
    func multiFieldEditSurvives() {
        let previous = legacySettingsMatchingBalanced()
        var proposed = previous
        proposed.filenamePrefix = "Capture"
        proposed.countdownSeconds = 7
        proposed.copyImageAfterExport = !previous.copyImageAfterExport

        let update = AppSettings.resolveUpdate(previous: previous, proposed: proposed)
        #expect(update.previous.filenamePrefix != update.current.filenamePrefix)
        #expect(update.previous.countdownSeconds != update.current.countdownSeconds)
        #expect(update.previous.copyImageAfterExport != update.current.copyImageAfterExport)
    }

    @Test("An edit that normalisation undoes entirely is reported as ineffective")
    func normalisationCanCollapseAnEdit() {
        // Setting only the label, to something the values do not support, is not a real change.
        var previous = AppSettings()
        previous.applyQualityPreset(.balanced)

        var proposed = previous
        proposed.qualityPreset = .sharper  // values still say Balanced

        let update = AppSettings.resolveUpdate(previous: previous, proposed: proposed)
        #expect(update.current.qualityPreset == .balanced)
        #expect(!update.isEffective, "nothing actually changed, so nothing should be announced")
    }

    @Test("An already-normalised edit passes through untouched")
    func normalisedEditIsUnchanged() {
        var previous = AppSettings()
        previous.applyQualityPreset(.balanced)

        var proposed = previous
        proposed.applyQualityPreset(.sharper)

        let update = AppSettings.resolveUpdate(previous: previous, proposed: proposed)
        #expect(update.current == proposed)
        #expect(update.isEffective)
        #expect(update.current.qualityPreset == .sharper)
    }

    @Test("Editing an advanced value both relabels and stays visible")
    func advancedEditRelabelsAndIsVisible() {
        var previous = AppSettings()
        previous.applyQualityPreset(.balanced)

        var proposed = previous
        proposed.recordingLimits.frameRate = 24

        let update = AppSettings.resolveUpdate(previous: previous, proposed: proposed)
        #expect(update.previous.qualityPreset == .balanced)
        #expect(update.current.qualityPreset == .custom)
        #expect(update.current.recordingLimits.frameRate == 24)
    }

    @Test("Resolving is idempotent — applying it twice changes nothing further")
    func idempotent() {
        let previous = legacySettingsMatchingBalanced()
        var proposed = previous
        proposed.filenamePrefix = "Shot"

        let first = AppSettings.resolveUpdate(previous: previous, proposed: proposed)
        let second = AppSettings.resolveUpdate(previous: first.previous, proposed: first.current)
        #expect(second.current == first.current)
    }
}
