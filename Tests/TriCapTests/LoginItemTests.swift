import Foundation
import Testing
@testable import TriCapKit

/// "Launch at login" has no state of its own: `SMAppService.mainApp.status` is the single source
/// of truth, and these are the pure rules that turn that status into UI and into actions.
@Suite("Login item status mapping")
struct LoginItemPresentationTests {

    @Test("Every status maps to an honest presentation", arguments: [
        LoginItemStatus.notRegistered, .enabled, .requiresApproval, .notFound,
    ])
    func allStatusesPresentable(status: LoginItemStatus) {
        let presentation = LoginItemPresentation.presentation(for: status)
        // A warning without text would be styling with nothing to style.
        if presentation.isWarning { #expect(presentation.statusText != nil) }
        if presentation.offersSystemSettings { #expect(presentation.statusText != nil) }
    }

    @Test("Off by default: notRegistered shows a plain off toggle")
    func notRegistered() {
        let presentation = LoginItemPresentation.presentation(for: .notRegistered)
        #expect(!presentation.toggleIsOn)
        #expect(presentation.statusText == nil)
        #expect(!presentation.offersSystemSettings)
    }

    @Test("Enabled shows a plain on toggle")
    func enabled() {
        let presentation = LoginItemPresentation.presentation(for: .enabled)
        #expect(presentation.toggleIsOn)
        #expect(presentation.statusText == nil)
        #expect(!presentation.isWarning)
    }

    @Test("requiresApproval reads as on, warns, and offers System Settings")
    func requiresApproval() {
        // TriCap has asked; the block lives in System Settings. Showing "off" would invite a
        // pointless re-register, and hiding the settings entry would leave the user stranded.
        let presentation = LoginItemPresentation.presentation(for: .requiresApproval)
        #expect(presentation.toggleIsOn)
        #expect(presentation.isWarning)
        #expect(presentation.offersSystemSettings)
        #expect(presentation.statusText?.contains("Login Items") == true)
    }

    @Test("notFound reads as off with an actionable explanation")
    func notFound() {
        let presentation = LoginItemPresentation.presentation(for: .notFound)
        #expect(!presentation.toggleIsOn)
        #expect(presentation.isWarning)
        #expect(presentation.statusText?.contains("Applications") == true,
                "the fix — a stable install location — must be named")
    }
}

@Suite("Login item toggle decisions")
struct LoginItemActionTests {

    @Test("Turning on registers only from the off states")
    func turningOn() {
        #expect(LoginItemAction.action(forDesired: true, current: .notRegistered) == .register)
        #expect(LoginItemAction.action(forDesired: true, current: .notFound) == .register)
        #expect(LoginItemAction.action(forDesired: true, current: .enabled) == .none)
        #expect(LoginItemAction.action(forDesired: true, current: .requiresApproval) == .none)
    }

    @Test("Turning off unregisters only from the registered states")
    func turningOff() {
        #expect(LoginItemAction.action(forDesired: false, current: .enabled) == .unregister)
        #expect(LoginItemAction.action(forDesired: false, current: .requiresApproval) == .unregister)
        #expect(LoginItemAction.action(forDesired: false, current: .notRegistered) == .none)
        #expect(LoginItemAction.action(forDesired: false, current: .notFound) == .none)
    }

    @Test("Repeating a request is a no-op, not a stacked registration", arguments: [
        (true, LoginItemStatus.enabled),
        (false, LoginItemStatus.notRegistered),
    ])
    func idempotent(desired: Bool, settled: LoginItemStatus) {
        // The status after a successful action is the settled state; asking again must do nothing.
        #expect(LoginItemAction.action(forDesired: desired, current: settled) == .none)
    }
}
