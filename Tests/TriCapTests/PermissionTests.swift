import Foundation
import Testing
@testable import CaptureCore
@testable import TriCapKit

/// macOS exposes no API that distinguishes "never asked for Screen Recording" from "asked and
/// denied" — `CGPreflightScreenCaptureAccess()` returns `false` for both. TriCap therefore
/// remembers whether it has ever issued the request. These tests pin that heuristic, because the
/// three states drive three different pieces of UI copy and only one of them can be fixed by
/// asking again.
@Suite("Screen recording permission state")
struct ScreenRecordingPermissionTests {

    private func freshDefaults() -> UserDefaults {
        let name = "app.tricap.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("Before any request the status is notDetermined (when the system says no)")
    func notDeterminedBeforeFirstRequest() {
        let defaults = freshDefaults()
        let status = ScreenRecordingPermission.authorizationStatus(defaults: defaults)
        // On a machine where the host process already has permission the preflight wins and the
        // answer is `.authorized`; otherwise a never-asked app must read as `.notDetermined`.
        #expect(status == .authorized || status == .notDetermined)
    }

    @Test("After a request has been made, a failing preflight means denied — never notDetermined")
    func deniedAfterRequest() {
        let defaults = freshDefaults()
        defaults.set(true, forKey: ScreenRecordingPermission.hasRequestedDefaultsKey)
        let status = ScreenRecordingPermission.authorizationStatus(defaults: defaults)
        #expect(status == .authorized || status == .denied)
        #expect(status != .notDetermined)
    }

    @Test("The three states map to distinct, actionable error copy")
    func errorCopyIsDistinct() {
        let notDetermined = TriCapError.screenRecordingPermissionNotDetermined
        let denied = TriCapError.screenRecordingPermissionDenied

        #expect(notDetermined.errorDescription != denied.errorDescription)
        #expect(notDetermined.recoverySuggestion != nil)
        // The denied copy must say macOS will not ask again — that is the whole difference.
        #expect(denied.recoverySuggestion?.contains("does not allow an app to re-ask") == true)
    }

    @Test("Cancellation is not reported as an error to the user")
    func cancellationIsQuiet() {
        #expect(TriCapError.cancelled.errorDescription == "Capture cancelled.")
        #expect(TriCapError.cancelled.recoverySuggestion == nil)
    }

    @Test("Limit and colour-space errors carry actionable recovery text")
    func limitCopy() {
        #expect(TriCapError.limitExceeded("x").recoverySuggestion?.isEmpty == false)
        #expect(TriCapError.unsupportedColorSpace("x").recoverySuggestion?.contains("sRGB") == true)
    }
}
