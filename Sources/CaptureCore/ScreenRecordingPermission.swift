import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit
import TriCapKit

/// The three states TriCap has to tell apart to show correct copy.
public enum ScreenRecordingAuthorization: String, Sendable, Equatable {
    /// Never asked. A system prompt is still possible.
    case notDetermined
    /// Asked and refused, or granted then revoked. macOS will not prompt again.
    case denied
    case authorized
}

/// Screen & System Audio Recording permission handling.
///
/// macOS deliberately gives no API that distinguishes "never asked" from "asked and denied":
/// `CGPreflightScreenCaptureAccess()` returns `false` for both. TriCap therefore remembers
/// whether it has ever issued a request and combines that with the preflight result. The flag
/// lives in `UserDefaults`, so deleting the app's preferences resets TriCap to "not determined"
/// even though TCC still remembers — in that case the request below simply no-ops and the user
/// is sent to System Settings, which is the correct outcome either way.
public enum ScreenRecordingPermission {

    static let hasRequestedDefaultsKey = "app.tricap.hasRequestedScreenRecording"

    /// Cheap, synchronous, no side effects. Safe to call on every menu open.
    public static func authorizationStatus(defaults: UserDefaults = .standard) -> ScreenRecordingAuthorization {
        if CGPreflightScreenCaptureAccess() {
            return .authorized
        }
        return defaults.bool(forKey: hasRequestedDefaultsKey) ? .denied : .notDetermined
    }

    /// Trigger the one-time system prompt.
    ///
    /// Returns the status *after* the call. macOS only ever shows this prompt once per app
    /// identity; on every later call `CGRequestScreenCaptureAccess()` returns immediately with
    /// the stored answer. Note that newly granted permission does not always apply to an
    /// already-running process — callers should offer a relaunch when the status stays denied
    /// right after the user flips the switch.
    @discardableResult
    public static func request(defaults: UserDefaults = .standard) -> ScreenRecordingAuthorization {
        defaults.set(true, forKey: hasRequestedDefaultsKey)
        let granted = CGRequestScreenCaptureAccess()
        TriCapLog.capture.info("CGRequestScreenCaptureAccess -> \(granted, privacy: .public)")
        return granted ? .authorized : (CGPreflightScreenCaptureAccess() ? .authorized : .denied)
    }

    /// Authoritative check: actually ask ScreenCaptureKit for content.
    ///
    /// The preflight above can be stale (for example right after the user toggles the switch),
    /// so anything that is about to capture calls this instead and maps SCK's error to our
    /// permission states.
    public static func shareableContent() async throws -> SCShareableContent {
        do {
            return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            let nsError = error as NSError
            // SCStreamErrorDomain -3801 is "user declined TCC"; -3802 is "user stopped".
            if nsError.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain",
               nsError.code == -3801 || nsError.code == -3802 {
                throw currentDeniedError()
            }
            if CGPreflightScreenCaptureAccess() == false {
                throw currentDeniedError()
            }
            throw TriCapError.screenCaptureUnavailable(nsError.localizedDescription)
        }
    }

    private static func currentDeniedError() -> TriCapError {
        switch authorizationStatus() {
        case .notDetermined: return .screenRecordingPermissionNotDetermined
        default: return .screenRecordingPermissionDenied
        }
    }

    /// Opens the exact System Settings pane. The `x-apple.systempreferences` URL scheme is
    /// public and documented for privacy panes.
    @MainActor
    public static func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }
}
