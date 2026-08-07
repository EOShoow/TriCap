import Foundation
import Testing
@testable import TriCapKit

/// The capture hot key opens one of three flows — quick screenshot, screenshot-to-editor, or a
/// recording — either fixed or remembered. The decision is a pure function, the `R` key cycles
/// the three flows in a fixed order, and stored history must survive settings round-trips,
/// including blobs written when the memory was only two states wide.
@Suite("Hot key launch flow")
struct HotKeyLaunchModeTests {

    // MARK: - The R cycle

    @Test("R cycles quick screenshot → edit → recording → quick screenshot")
    func cycleOrder() {
        #expect(CaptureFlow.quickStill.next == .editStill)
        #expect(CaptureFlow.editStill.next == .recording)
        #expect(CaptureFlow.recording.next == .quickStill)
    }

    @Test("Three presses always return to the starting flow", arguments: CaptureFlow.allCases)
    func cycleIsClosed(start: CaptureFlow) {
        #expect(start.next.next.next == start)
    }

    // MARK: - Legacy mapping

    @Test("A legacy still intent resolves through the still-action setting")
    func legacyStillMapsThroughAction() {
        #expect(CaptureFlow(legacyIntent: .still, stillAction: .copyToClipboard) == .quickStill)
        #expect(CaptureFlow(legacyIntent: .still, stillAction: .openEditor) == .editStill)
    }

    @Test("A legacy recording intent is a recording regardless of the still action",
          arguments: StillCaptureAction.allCases)
    func legacyRecordingIgnoresAction(action: StillCaptureAction) {
        #expect(CaptureFlow(legacyIntent: .recording, stillAction: action) == .recording)
    }

    @Test("The downgrade mirror collapses both still flows to the legacy still")
    func legacyMirror() {
        #expect(CaptureFlow.quickStill.legacyIntent == .still)
        #expect(CaptureFlow.editStill.legacyIntent == .still)
        #expect(CaptureFlow.recording.legacyIntent == .recording)
    }

    // MARK: - Launch decision

    @Test("Fixed modes ignore history entirely", arguments: CaptureFlow.allCases)
    func fixedModesIgnoreHistory(last: CaptureFlow) {
        #expect(HotKeyLaunchMode.alwaysStill.effectiveFlow(lastUsed: last, stillAction: .copyToClipboard) == .quickStill)
        #expect(HotKeyLaunchMode.alwaysStill.effectiveFlow(lastUsed: last, stillAction: .openEditor) == .editStill)
        #expect(HotKeyLaunchMode.alwaysRecording.effectiveFlow(lastUsed: last, stillAction: .copyToClipboard) == .recording)
    }

    @Test("Remember-last returns exactly what was stored", arguments: CaptureFlow.allCases)
    func rememberLastFollowsHistory(last: CaptureFlow) {
        #expect(HotKeyLaunchMode.rememberLast.effectiveFlow(lastUsed: last, stillAction: .copyToClipboard) == last)
        #expect(HotKeyLaunchMode.rememberLast.effectiveFlow(lastUsed: last, stillAction: .openEditor) == last)
    }

    @Test("Every mode explains itself and mentions the in-picker cycle key")
    func copyIsSelfExplanatory() {
        for mode in HotKeyLaunchMode.allCases {
            #expect(!mode.displayName.isEmpty)
            #expect(mode.summary.contains("R"), "the escape hatch (the R cycle) must always be named")
        }
        for flow in CaptureFlow.allCases {
            #expect(!flow.displayName.isEmpty)
        }
    }

    // MARK: - Persistence

    @Test("An old settings blob gets remember-last starting from a quick screenshot")
    func legacyBlobDefaults() throws {
        // First press after the upgrade behaves exactly like the old build: clipboard screenshot
        // mode (the old default still action); only afterwards does the memory kick in.
        let settings = try JSONDecoder().decode(
            AppSettings.self, from: Data(#"{"filenamePrefix": "Shot"}"#.utf8)
        )
        #expect(settings.hotKeyLaunchMode == .rememberLast)
        #expect(settings.lastCaptureFlow == .quickStill)
        #expect(settings.filenamePrefix == "Shot", "the rest of the blob survives")
    }

    @Test("A legacy still-with-editor blob migrates to the edit flow")
    func legacyEditorBlobMigrates() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(
            #"{"lastCaptureIntent": "still", "stillCaptureAction": "openEditor"}"#.utf8
        ))
        #expect(settings.lastCaptureFlow == .editStill,
                "the still/editor fork used to live in the setting; migration must keep it")
    }

    @Test("A legacy recording blob migrates to the recording flow")
    func legacyRecordingBlobMigrates() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(
            #"{"lastCaptureIntent": "recording"}"#.utf8
        ))
        #expect(settings.lastCaptureFlow == .recording)
    }

    @Test("Unknown raw values from a future build degrade to the migration seed, keeping the blob")
    func unknownRawValuesDegrade() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(
            #"{"hotKeyLaunchMode": "telepathy", "lastCaptureFlow": "hologram", "lastCaptureIntent": "recording", "filenamePrefix": "Keep"}"#.utf8
        ))
        #expect(settings.hotKeyLaunchMode == AppSettings().hotKeyLaunchMode)
        #expect(settings.lastCaptureFlow == .recording,
                "an unreadable flow falls back to the legacy two-state memory, not to the default")
        #expect(settings.filenamePrefix == "Keep")
    }

    @Test("Flow and its legacy mirror round-trip through Codable")
    func roundTrip() throws {
        var original = AppSettings()
        original.hotKeyLaunchMode = .alwaysRecording
        original.lastCaptureFlow = .editStill
        original.lastCaptureIntent = original.lastCaptureFlow.legacyIntent

        let decoded = try JSONDecoder().decode(
            AppSettings.self, from: JSONEncoder().encode(original)
        )
        #expect(decoded == original)
        #expect(decoded.lastCaptureFlow == .editStill)
        #expect(decoded.lastCaptureIntent == .still)
    }

    @Test("A stored recording history survives a reload and drives the next launch")
    func historyDrivesNextLaunch() throws {
        // The end-to-end story: the user recorded something, the app restarted, the hot key
        // must open in recording mode again.
        var settings = AppSettings()
        settings.lastCaptureFlow = .recording
        let reloaded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(reloaded.hotKeyLaunchMode.effectiveFlow(
            lastUsed: reloaded.lastCaptureFlow, stillAction: reloaded.stillCaptureAction
        ) == .recording)
    }
}
