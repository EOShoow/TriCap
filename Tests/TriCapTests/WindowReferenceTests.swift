import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import ExportCore
@testable import SelectionUI
@testable import TriCapKit

private func referenceWindow(
    id: UInt32 = 42, pid: Int32 = 501, bundle: String = "com.example.Editor",
    title: String = "Report — Draft", frame: CGRect = CGRect(x: 100, y: 200, width: 800, height: 500),
    isOnScreen: Bool = true
) -> WindowCandidate {
    WindowCandidate(
        id: id, frame: frame, isOnScreen: isOnScreen,
        bundleIdentifier: bundle, title: title, applicationName: "Editor", processID: pid
    )
}

@Suite("Window locator identity and migration")
struct WindowReferenceTests {
    @Test("Existing settings gain the reference shortcut and retain their other choices")
    func migratesSettings() throws {
        let data = Data(#"{"hotKey":{"keyCode":17,"carbonModifiers":256},"pinHotKey":{"keyCode":118,"carbonModifiers":0},"lastCaptureFlow":"recording"}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(settings.windowReferenceHotKey == .defaultWindowReference)
        #expect(settings.hotKey.keyCode == 17 && settings.pinHotKey.keyCode == 118)
        #expect(settings.lastCaptureFlow == .recording)
        #expect(Set([HotKeyCombo.default, .defaultPin, .defaultWindowReference]).count == 3)
        #expect(HotKeyCombo.defaultWindowReference.isValid)
        #expect(HotKeyCombo.defaultWindowReference.displayString == "⌥⇧6")
    }

    @Test("A custom locator shortcut survives reopening settings")
    func roundTripsShortcut() throws {
        var settings = AppSettings()
        settings.windowReferenceHotKey = HotKeyCombo(keyCode: 118, carbonModifiers: 0)
        #expect(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)) == settings)
    }

    @Test("A failed reference shortcut change rolls back to its own previous binding")
    func shortcutRollsBack() {
        let original = HotKeyCombo.defaultWindowReference
        let outcome = HotKeyRegistrationPolicy.apply(desired: .default, previous: original) { $0 == original }
        #expect(outcome.rolledBack && outcome.active == original)
    }

    @Test("Coordinates are explicitly Quartz points, including a window above and left of the main screen")
    func coordinateSpace() throws {
        let window = referenceWindow(frame: CGRect(x: -1000, y: 1000, width: 600, height: 500))
        let reference = try #require(WindowReference(window: window, primaryHeightInPoints: 900))
        #expect(reference.boundsInQuartzPoints.x == -1000)
        #expect(reference.boundsInQuartzPoints.y == -600)
        #expect(reference.boundsInQuartzPoints.width == 600 && reference.boundsInQuartzPoints.height == 500)
        #expect(reference.applicationName == "Editor" && reference.processID == 501 && reference.windowID == 42)
    }

    @Test("Window titles are data: Unicode, quotes, newlines and code fences survive safely")
    func titleIsEscapedData() throws {
        let window = referenceWindow(title: "报价 ' \"\n```sh\n$(printf unexpected)\n```")
        let date = Date(timeIntervalSince1970: 1_793_000_000.125)
        let reference = try #require(WindowReference(window: window, primaryHeightInPoints: 900, capturedAt: date))
        let json = try reference.json()
        #expect(!json.contains("```"))
        #expect(try WindowReference.decode(json: json) == reference)
        let prompt = try reference.prompt()
        #expect(prompt.components(separatedBy: "```").count == 3)
        #expect(prompt.contains("Cowork") && prompt.contains("CGWindowID"))
        #expect(prompt.contains("重新枚举") && prompt.contains("授权"))
    }

    @Test("Unidentifiable windows never produce a misleading locator")
    func rejectsMissingIdentity() {
        let window = WindowCandidate(id: 42, frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(WindowReference(window: window, primaryHeightInPoints: 900) == nil)
    }

    @Test("A moved or renamed window is resolved by its live application and window IDs")
    func resolvesLiveIdentity() throws {
        let reference = try #require(WindowReference(window: referenceWindow(), primaryHeightInPoints: 900))
        let moved = referenceWindow(title: "Report — Saved", frame: CGRect(x: 300, y: 50, width: 800, height: 500))
        #expect(reference.resolve(in: [referenceWindow(id: 99), moved]) == .matched(moved))
    }

    @Test("A closed, hidden, replaced or restarted window never falls back to a matching title")
    func rejectsStaleReference() throws {
        let date = Date(timeIntervalSince1970: 1_793_000_000)
        let reference = try #require(WindowReference(window: referenceWindow(), primaryHeightInPoints: 900, capturedAt: date))
        for replacement in [
            referenceWindow(id: 99), referenceWindow(pid: 502),
            referenceWindow(bundle: "com.other.Editor"), referenceWindow(isOnScreen: false),
        ] {
            #expect(reference.resolve(in: [replacement]) == .unavailable)
        }
        #expect(reference.resolve(in: []) == .unavailable)
        #expect(reference.resolve(in: [referenceWindow()], processLaunchDate: date.addingTimeInterval(1)) == .unavailable)
        #expect(reference.resolve(in: [referenceWindow(), referenceWindow()]) == .ambiguous)
    }
}

@MainActor
@Suite("Cowork window locator clipboard and picker")
struct WindowReferenceClipboardTests {
    @Test("Escape cancels window picking before closing a pin, then returns to the pin")
    func escapePriority() {
        let claim = PriorityHotKeyClaim(combo: .bareEscape, register: { _, _ in true }, unregister: {})
        var actions: [String] = []
        let pin = claim.push(priority: .pin) { actions.append("pin") }
        let selection = claim.push(priority: .selection) { actions.append("selection") }
        claim.simulateFire()
        claim.pop(selection)
        claim.simulateFire()
        claim.pop(pin)
        #expect(actions == ["selection", "pin"])
        #expect(claim.depth == 0 && !claim.isClaimed)
    }

    @Test("Clipboard carries self-contained text and JSON, with no screenshot or file representation")
    func copiesLocator() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("old clipboard", forType: .string)
        let reference = try #require(WindowReference(window: referenceWindow(), primaryHeightInPoints: 900))
        #expect(try PasteboardWindowReference.write(reference, to: board))
        let text = try #require(board.string(forType: .string))
        let json = try #require(board.string(forType: PasteboardWindowReference.referenceType))
        #expect(text.contains("com.example.Editor") && text.contains("Report — Draft") && text.contains("Cowork"))
        let decoded = try WindowReference.decode(json: json)
        #expect(decoded.windowID == 42 && decoded.processID == 501)
        #expect(board.data(forType: .png) == nil && board.data(forType: .tiff) == nil)
        #expect(board.string(forType: .fileURL) == nil)
    }

    private final class Delegate: SelectionOverlayDelegate {
        var modeChanges = 0
        var cancellations = 0
        func overlayDidBeginDrag(at point: CGPoint) {}
        func overlayDidDrag(to point: CGPoint, snapping: Bool) {}
        func overlayDidHover(at point: CGPoint) {}
        func overlayDidEndDrag(at point: CGPoint) {}
        func overlayDidCancel() { cancellations += 1 }
        func overlayDidRequestMode(_ requested: CaptureFlow?) { modeChanges += 1 }
    }

    @Test("Reference picking keeps its purpose when R/S/Space/Tab are pressed, and Escape still cancels")
    func locksPickerPurpose() throws {
        let view = SelectionOverlayView(frame: CGRect(x: 0, y: 0, width: 900, height: 560))
        let delegate = Delegate()
        view.delegate = delegate
        view.isWindowReference = true
        for (key, code) in [("r", UInt16(15)), ("s", 1), (" ", 49), ("\t", 48), ("\u{1b}", 53)] {
            let event = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: code
            ))
            view.keyDown(with: event)
        }
        #expect(delegate.modeChanges == 0 && delegate.cancellations == 1)
    }
}
