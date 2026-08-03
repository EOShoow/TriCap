import Foundation
import Testing
@testable import TriCapKit

@Suite("Bare-key allow list")
struct BareKeyAllowListTests {

    private func bare(_ keyCode: UInt32) -> HotKeyCombo {
        HotKeyCombo(keyCode: keyCode, carbonModifiers: 0)
    }

    @Test("A bare function key is a legal shortcut")
    func functionKeysAreAllowed() {
        #expect(bare(99).isValid, "F3 must be bindable — it is the shipped pin shortcut")
        #expect(HotKeyCombo.defaultPin.isValid)
        #expect(HotKeyCombo.defaultPin.keyCode == 99)
        #expect(!HotKeyCombo.defaultPin.hasModifier)
    }

    @Test("Bare letters and digits are refused", arguments: [
        UInt32(0),   // A
        UInt32(23),  // 5 — the capture shortcut's key, which must stay modifier-bound
        UInt32(49),  // Space
        UInt32(36),  // Return
        UInt32(51),  // Delete
    ])
    func ordinaryKeysAreRefused(keyCode: UInt32) {
        // A modifier-less hot key is swallowed system-wide, so binding one of these would make
        // that character untypeable in every application.
        #expect(!bare(keyCode).isValid)
        #expect(!bare(keyCode).isAllowedAsBareKey)
    }

    @Test("Escape is not on the allow list")
    func escapeIsNotBindable() {
        // It is claimed transiently during a recording, never as a persistent shortcut.
        #expect(!HotKeyCombo.bareEscape.isValid)
        #expect(!HotKeyCombo.bareEscape.isAllowedAsBareKey)
    }

    @Test("The allow list is exactly the function row")
    func allowListContents() {
        #expect(HotKeyCombo.bareKeyAllowList.count == 20)
        for keyCode in HotKeyCombo.bareKeyAllowList {
            #expect(HotKeyCombo.keyName(for: keyCode).hasPrefix("F"), "\(keyCode) should be a function key")
        }
    }

    @Test("Any key becomes legal once a modifier is added")
    func modifiersRehabilitateAnyKey() {
        let withModifier = HotKeyCombo(
            keyCode: 0, carbonModifiers: HotKeyCombo.CarbonModifier.command.rawValue
        )
        #expect(withModifier.isValid)
        #expect(withModifier.hasModifier)
    }

    @Test("The two shipped defaults are different keys and both legal")
    func shippedDefaultsAreDistinct() {
        #expect(HotKeyCombo.default != HotKeyCombo.defaultPin)
        #expect(HotKeyCombo.default.isValid)
        #expect(HotKeyCombo.defaultPin.isValid)
        // The capture shortcut keeps its modifiers; only the pin key is bare.
        #expect(HotKeyCombo.default.hasModifier)
    }
}

@Suite("Independent shortcut registration")
struct ShortcutIndependenceTests {

    let capture = HotKeyCombo.default
    let pin = HotKeyCombo.defaultPin
    let replacement = HotKeyCombo(
        keyCode: 17, carbonModifiers: HotKeyCombo.CarbonModifier.command.rawValue
    )

    @Test("A failed pin registration rolls back without touching the capture shortcut")
    func pinRollbackIsIndependent() {
        // F3 is Mission Control's factory binding, so this is the registration most likely to
        // fail. It must not take ⌥⇧5 down with it.
        var attempted: [HotKeyCombo] = []
        let outcome = HotKeyRegistrationPolicy.apply(desired: replacement, previous: pin) { combo in
            attempted.append(combo)
            return combo == pin
        }

        #expect(outcome.active == pin)
        #expect(outcome.rolledBack)
        #expect(attempted == [replacement, pin])
    }

    @Test("A pin shortcut that cannot be claimed at all is reported, not silently swapped")
    func lostPinShortcutIsReported() {
        let outcome = HotKeyRegistrationPolicy.apply(desired: pin, previous: nil) { _ in false }
        #expect(outcome.lostShortcut)
        #expect(outcome.active == nil)
        // Nothing in the policy invents a replacement key.
        #expect(!outcome.rolledBack)
    }

    @Test("The capture shortcut rolls back on its own terms")
    func captureRollbackIsIndependent() {
        let outcome = HotKeyRegistrationPolicy.apply(desired: replacement, previous: capture) { combo in
            combo == capture
        }
        #expect(outcome.active == capture)
        #expect(outcome.rolledBack)
    }
}

@Suite("Screenshot post-capture action")
struct StillCaptureActionTests {

    @Test("Copying to the clipboard is the shipped default")
    func defaultIsCopy() {
        #expect(AppSettings().stillCaptureAction == .copyToClipboard)
    }

    @Test("Both actions are offered and explain themselves")
    func bothActionsDescribed() {
        #expect(StillCaptureAction.allCases.count == 2)
        for action in StillCaptureAction.allCases {
            #expect(!action.displayName.isEmpty)
            #expect(!action.summary.isEmpty)
        }
        // The editor option must mention the one-off menu entry, so choosing the default does not
        // feel like giving up annotation.
        #expect(StillCaptureAction.openEditor.summary.contains("Screenshot and Edit"))
    }
}

@Suite("Pin shortcut migration")
struct PinShortcutMigrationTests {

    private func decode(_ json: String) throws -> AppSettings {
        try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
    }

    @Test("A settings blob written before pinning existed gains the default pin key")
    func legacyBlobGetsDefaultPinKey() throws {
        let settings = try decode(#"{"filenamePrefix": "Shot"}"#)
        #expect(settings.pinHotKey == .defaultPin)
        #expect(settings.filenamePrefix == "Shot")
    }

    @Test("A legacy blob keeps its capture shortcut untouched")
    func legacyCaptureShortcutSurvives() throws {
        let settings = try decode(#"{"hotKey": {"keyCode": 17, "carbonModifiers": 256}}"#)
        #expect(settings.hotKey.keyCode == 17)
        #expect(settings.pinHotKey == .defaultPin, "the new key defaults without disturbing the old one")
    }

    @Test("A stored pin shortcut is honoured")
    func storedPinShortcutDecodes() throws {
        let settings = try decode(#"{"pinHotKey": {"keyCode": 118, "carbonModifiers": 0}}"#)
        #expect(settings.pinHotKey.keyCode == 118)  // F4
        #expect(settings.pinHotKey.isValid)
    }

    @Test("An unknown capture action degrades to the default without losing the blob")
    func unknownActionDegrades() throws {
        let settings = try decode(#"{"stillCaptureAction": "teleport", "filenamePrefix": "Keep"}"#)
        #expect(settings.stillCaptureAction == AppSettings().stillCaptureAction)
        #expect(settings.filenamePrefix == "Keep")
    }

    @Test("Both shortcuts round-trip through Codable")
    func roundTrip() throws {
        var original = AppSettings()
        original.pinHotKey = HotKeyCombo(keyCode: 118, carbonModifiers: 0)
        original.stillCaptureAction = .openEditor

        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
    }
}
