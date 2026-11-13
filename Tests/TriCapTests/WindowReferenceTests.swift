import CoreGraphics
import Foundation
import Testing
@testable import TriCapKit

private func window(
    id: UInt32 = 42, pid: Int32 = 501, bundle: String = "com.example.Editor",
    title: String? = "Report — Draft", frame: CGRect = CGRect(x: 100, y: 200, width: 800, height: 500),
    stackingIndex: Int = 0, isOnScreen: Bool = true
) -> WindowCandidate {
    WindowCandidate(
        id: id, frame: frame, isOnScreen: isOnScreen,
        bundleIdentifier: bundle, title: title, applicationName: "Editor", processID: pid,
        stackingIndex: stackingIndex
    )
}

@Suite("Command-Command recognition")
struct DoubleCommandTapTests {
    /// One modifier change. A free function because `#expect` cannot call a mutating method.
    private func change(
        _ recognizer: inout DoubleCommandTap, command: Bool, both: Bool = false, others: Bool = false,
        at time: TimeInterval
    ) -> Bool {
        recognizer.modifiersChanged(command: command, bothCommands: both, others: others, at: time)
    }

    /// Press and release ⌘ alone, `hold` seconds long, starting at `at`.
    private func tap(_ recognizer: inout DoubleCommandTap, at time: TimeInterval, hold: TimeInterval = 0.08) -> Bool {
        let down = change(&recognizer, command: true, at: time)
        let up = change(&recognizer, command: false, at: time + hold)
        return down || up
    }

    @Test("Two quick taps fire once; a third tap starts a new pair")
    func doubleTapFires() {
        var recognizer = DoubleCommandTap()
        #expect(!tap(&recognizer, at: 0))
        #expect(tap(&recognizer, at: 0.25))
        #expect(!tap(&recognizer, at: 0.5))
        #expect(tap(&recognizer, at: 0.75))
    }

    @Test("A slow second tap or a held ⌘ does not fire")
    func timingLimits() {
        var slow = DoubleCommandTap()
        #expect(!tap(&slow, at: 0))
        #expect(!tap(&slow, at: 0.08 + DoubleCommandTap.maximumGap + 0.05))

        var held = DoubleCommandTap()
        #expect(!tap(&held, at: 0, hold: DoubleCommandTap.maximumHold + 0.1))
        #expect(!tap(&held, at: 0.6))
    }

    @Test("⌘C then ⌘V, or ⌘ with another modifier, never fires")
    func shortcutsDoNotFire() {
        var copyPaste = DoubleCommandTap()
        _ = change(&copyPaste, command: true, at: 0)
        copyPaste.keyPressed()
        _ = change(&copyPaste, command: false, at: 0.08)
        _ = change(&copyPaste, command: true, at: 0.2)
        copyPaste.keyPressed()
        #expect(!change(&copyPaste, command: false, at: 0.28))

        var typedBetween = DoubleCommandTap()
        #expect(!tap(&typedBetween, at: 0))
        typedBetween.keyPressed()
        #expect(!tap(&typedBetween, at: 0.2))

        var shifted = DoubleCommandTap()
        #expect(!tap(&shifted, at: 0))
        _ = change(&shifted, command: true, at: 0.2)
        _ = change(&shifted, command: true, others: true, at: 0.22)
        #expect(!change(&shifted, command: false, at: 0.3))
    }

    @Test("Both ⌘ keys together fire once, and releasing them does not fire again")
    func bothCommandKeys() {
        var recognizer = DoubleCommandTap()
        #expect(!change(&recognizer, command: true, at: 0))
        #expect(change(&recognizer, command: true, both: true, at: 0.05))
        #expect(!change(&recognizer, command: true, at: 0.1))
        #expect(!change(&recognizer, command: false, at: 0.12))
        #expect(!tap(&recognizer, at: 0.3))
        #expect(tap(&recognizer, at: 0.5))
    }
}

@Suite("Front-window reference for Claude")
struct WindowReferenceTests {
    @Test("The front app's topmost ordinary window is chosen")
    func choosesFrontAppWindow() {
        let windows = [
            window(id: 1, pid: 700, bundle: "com.other.App", stackingIndex: 0),
            window(id: 2, pid: 501, stackingIndex: 2),
            window(id: 3, pid: 501, stackingIndex: 1),
            window(id: 4, pid: 501, stackingIndex: 0, isOnScreen: false),
        ]
        let chosen = WindowReference.frontWindow(in: windows, frontmostProcessID: 501, ownBundleIdentifier: nil)
        #expect(chosen?.id == 3)
    }

    @Test("A floating badge above the document window is skipped (Feishu, 2026-11-13)")
    func skipsFloatingBadge() {
        // Window list Claude read from Feishu after a ⌘⌘ picked the 66×20 sharing button.
        let windows = [
            window(id: 125318, pid: 36399, title: "Window", frame: CGRect(x: 439, y: 114, width: 66, height: 20), stackingIndex: 0),
            window(id: 125133, pid: 36399, title: "预览", frame: CGRect(x: 435, y: 110, width: 1182, height: 925), stackingIndex: 1),
            window(id: 104991, pid: 36399, title: "飞书", frame: CGRect(x: 436, y: 245, width: 1262, height: 755), stackingIndex: 2),
        ]
        let chosen = WindowReference.frontWindow(in: windows, frontmostProcessID: 36399, ownBundleIdentifier: nil)
        #expect(chosen?.id == 125133)
    }

    @Test("An app whose only window is small still gets that window")
    func smallOnlyWindow() {
        let windows = [
            window(id: 7, pid: 501, frame: CGRect(x: 0, y: 0, width: 160, height: 90)),
            window(id: 8, pid: 700, bundle: "com.other.App"),
        ]
        let chosen = WindowReference.frontWindow(in: windows, frontmostProcessID: 501, ownBundleIdentifier: nil)
        #expect(chosen?.id == 7)
    }

    @Test("A front app with no window gives nothing rather than another app's window")
    func noFallbackToOtherApps() {
        let windows = [window(id: 1, pid: 700, bundle: "com.other.App")]
        #expect(WindowReference.frontWindow(in: windows, frontmostProcessID: 501, ownBundleIdentifier: nil) == nil)
    }

    @Test("With TriCap in front, its own windows are skipped for the topmost other window")
    func skipsTriCap() {
        let windows = [
            window(id: 1, pid: 900, bundle: "app.tricap.TriCap", stackingIndex: 0),
            window(id: 2, pid: 501, stackingIndex: 1),
        ]
        let chosen = WindowReference.frontWindow(in: windows, frontmostProcessID: nil, ownBundleIdentifier: "app.tricap.TriCap")
        #expect(chosen?.id == 2)
    }

    @Test("Windows without an app identity never produce a reference")
    func rejectsMissingIdentity() {
        #expect(WindowReference(window: WindowCandidate(id: 42, frame: CGRect(x: 0, y: 0, width: 100, height: 100))) == nil)
        #expect(WindowReference(window: window(id: 0)) == nil)
    }

    @Test("The clipboard text is one line of JSON with the window identity and nothing else")
    func clipboardIsBareJSON() throws {
        let reference = try #require(WindowReference(window: window()))
        #expect(try reference.json()
            == #"{"app":"Editor","bundleId":"com.example.Editor","pid":501,"title":"Report — Draft","windowId":42}"#)
        #expect(reference.displayName == "Report — Draft — Editor")
    }

    @Test("Invisible watermark characters are dropped from titles (Feishu in Chrome, 2026-11-13)")
    func dropsInvisibleCharacters() throws {
        let watermark = "\u{200C}\u{200D}\u{FEFF}\u{2062}\u{200D}\u{200B}\u{2061}\u{FEFF}\u{2064}\u{202C}\u{2060}"
        let reference = try #require(WindowReference(window: window(title: watermark + "芯界光核-资产台账 - 飞书云文档")))
        #expect(reference.windowTitle == "芯界光核-资产台账 - 飞书云文档")
        #expect(!(try reference.json()).unicodeScalars.contains { $0.properties.generalCategory == .format })

        let onlyInvisible = try #require(WindowReference(window: window(title: watermark)))
        #expect(onlyInvisible.windowTitle == nil && onlyInvisible.displayName == "Editor")

        let emoji = try #require(WindowReference(window: window(title: "⭐️ Notes")))
        #expect(emoji.windowTitle == "⭐️ Notes")
    }

    @Test("Window titles are data: quotes, newlines and code fences stay inside the JSON string")
    func titleIsEscapedData() throws {
        let title = "报价 ' \"\n```sh\n$(printf unexpected)\n```"
        let reference = try #require(WindowReference(window: window(title: title)))
        let json = try reference.json()
        #expect(!json.contains("```") && !json.contains("\n"))
        let decoded = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(decoded["title"] as? String == title)
    }

    @Test("Settings saved by the earlier ⌥⇧6 build still load")
    func ignoresRetiredShortcutSetting() throws {
        let data = Data(#"{"hotKey":{"keyCode":17,"carbonModifiers":256},"windowReferenceHotKey":{"keyCode":22,"carbonModifiers":2560},"lastCaptureFlow":"recording"}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(settings.hotKey.keyCode == 17 && settings.lastCaptureFlow == .recording)
    }
}

@Suite("Several windows in one clipboard")
struct WindowReferenceBatchTests {
    private let start = Date(timeIntervalSince1970: 1_794_500_000)

    private func reference(id: UInt32, pid: Int32 = 501, title: String = "Doc") throws -> WindowReference {
        try #require(WindowReference(window: window(id: id, pid: pid, title: title)))
    }

    @Test("Presses within a minute, with nothing else copied, add one line per window")
    func appendsLines() throws {
        var batch = WindowReferenceBatch()
        let outcome1 = batch.add(try reference(id: 1), at: start, changeCount: 10)
        #expect(outcome1 == .started)
        batch.didWrite(changeCount: 11)
        let outcome2 = batch.add(try reference(id: 2, pid: 700), at: start.addingTimeInterval(30), changeCount: 11)
        #expect(outcome2 == .appended)
        batch.didWrite(changeCount: 12)
        let lines = try batch.text().components(separatedBy: "\n")
        #expect(lines.count == 2)
        #expect(lines[0].hasPrefix("{") && lines[0].contains(#""windowId":1"#))
        #expect(lines[1].hasSuffix("}") && lines[1].contains(#""windowId":2"#))
    }

    @Test("A late press, or anything copied in between, starts a fresh clipboard")
    func startsOver() throws {
        var late = WindowReferenceBatch()
        late.add(try reference(id: 1), at: start, changeCount: 10)
        late.didWrite(changeCount: 11)
        let afterLimit = start.addingTimeInterval(WindowReferenceBatch.continuationWindow + 1)
        let outcome3 = late.add(try reference(id: 2), at: afterLimit, changeCount: 11)
        #expect(outcome3 == .started)
        #expect(late.references.map(\.windowID) == [2])

        var copiedElsewhere = WindowReferenceBatch()
        copiedElsewhere.add(try reference(id: 1), at: start, changeCount: 10)
        copiedElsewhere.didWrite(changeCount: 11)
        let outcome4 = copiedElsewhere.add(try reference(id: 2), at: start.addingTimeInterval(5), changeCount: 12)
        #expect(outcome4 == .started)
        #expect(copiedElsewhere.references.map(\.windowID) == [2])
    }

    @Test("Referencing the same window again keeps one line and refreshes its title")
    func deduplicates() throws {
        var batch = WindowReferenceBatch()
        batch.add(try reference(id: 1), at: start, changeCount: 10)
        batch.didWrite(changeCount: 11)
        batch.add(try reference(id: 2, pid: 700), at: start.addingTimeInterval(5), changeCount: 11)
        batch.didWrite(changeCount: 12)
        let outcome5 = batch.add(try reference(id: 1, title: "Doc — Saved"), at: start.addingTimeInterval(9), changeCount: 12)
        #expect(outcome5 == .alreadyIncluded)
        #expect(batch.references.map(\.windowID) == [1, 2])
        #expect(batch.references.first?.windowTitle == "Doc — Saved")
    }
}
