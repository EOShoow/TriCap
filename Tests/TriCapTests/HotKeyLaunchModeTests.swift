import Foundation
import Testing
@testable import TriCapKit

/// The capture hot key can open in a fixed mode or in whatever completed last. The decision is a
/// pure function, and the stored history must survive settings round-trips while never leaking
/// into the fixed modes.
@Suite("Hot key launch mode")
struct HotKeyLaunchModeTests {

    @Test("Fixed modes ignore history entirely", arguments: CaptureIntent.allCases)
    func fixedModesIgnoreHistory(last: CaptureIntent) {
        #expect(HotKeyLaunchMode.alwaysStill.effectiveIntent(lastUsed: last) == .still)
        #expect(HotKeyLaunchMode.alwaysRecording.effectiveIntent(lastUsed: last) == .recording)
    }

    @Test("Remember-last returns exactly what was stored", arguments: CaptureIntent.allCases)
    func rememberLastFollowsHistory(last: CaptureIntent) {
        #expect(HotKeyLaunchMode.rememberLast.effectiveIntent(lastUsed: last) == last)
    }

    @Test("Every mode explains itself and mentions the in-picker switch")
    func copyIsSelfExplanatory() {
        for mode in HotKeyLaunchMode.allCases {
            #expect(!mode.displayName.isEmpty)
            #expect(mode.summary.contains("R") || mode.summary.contains("S"),
                    "the escape hatch (R/S switching) must always be named")
        }
    }

    // MARK: - Persistence

    @Test("An old settings blob gets remember-last starting from a screenshot")
    func legacyBlobDefaults() throws {
        // First press after the upgrade behaves exactly like the old build (screenshot mode);
        // only afterwards does the memory kick in.
        let settings = try JSONDecoder().decode(
            AppSettings.self, from: Data(#"{"filenamePrefix": "Shot"}"#.utf8)
        )
        #expect(settings.hotKeyLaunchMode == .rememberLast)
        #expect(settings.lastCaptureIntent == .still)
        #expect(settings.hotKeyLaunchMode.effectiveIntent(lastUsed: settings.lastCaptureIntent) == .still)
        #expect(settings.filenamePrefix == "Shot", "the rest of the blob survives")
    }

    @Test("Unknown raw values from a future build degrade to the defaults, keeping the blob")
    func unknownRawValuesDegrade() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(
            #"{"hotKeyLaunchMode": "telepathy", "lastCaptureIntent": "hologram", "filenamePrefix": "Keep"}"#.utf8
        ))
        #expect(settings.hotKeyLaunchMode == AppSettings().hotKeyLaunchMode)
        #expect(settings.lastCaptureIntent == AppSettings().lastCaptureIntent)
        #expect(settings.filenamePrefix == "Keep")
    }

    @Test("Both fields round-trip through Codable")
    func roundTrip() throws {
        var original = AppSettings()
        original.hotKeyLaunchMode = .alwaysRecording
        original.lastCaptureIntent = .recording

        let decoded = try JSONDecoder().decode(
            AppSettings.self, from: JSONEncoder().encode(original)
        )
        #expect(decoded == original)
        #expect(decoded.hotKeyLaunchMode == .alwaysRecording)
        #expect(decoded.lastCaptureIntent == .recording)
    }

    @Test("A stored recording history survives a reload and drives the next launch")
    func historyDrivesNextLaunch() throws {
        // The end-to-end story: the user recorded something, the app restarted, the hot key
        // must open in recording mode again.
        var settings = AppSettings()
        settings.lastCaptureIntent = .recording
        let reloaded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(reloaded.hotKeyLaunchMode.effectiveIntent(lastUsed: reloaded.lastCaptureIntent) == .recording)
    }
}
