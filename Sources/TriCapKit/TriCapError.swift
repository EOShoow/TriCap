import Foundation

/// Every failure TriCap surfaces to the user. Deliberately explicit about the screen-recording
/// permission states, because "not determined", "denied" and "revoked after being granted" need
/// three different pieces of UI copy and only one of them can be fixed by asking again.
public enum TriCapError: Error, Equatable, Sendable {
    /// The user has never been asked for Screen & System Audio Recording.
    case screenRecordingPermissionNotDetermined
    /// The user was asked and said no (or revoked it later). Only System Settings can fix this.
    case screenRecordingPermissionDenied
    /// Permission looked fine but ScreenCaptureKit still refused; carries the underlying text.
    case screenCaptureUnavailable(String)
    case noDisplaysAvailable
    /// The user pressed Esc, right-clicked, or the overlay lost focus.
    case cancelled
    case selectionTooSmall
    case captureFailed(String)
    case encodingFailed(String)
    case writeFailed(String)
    /// A configured ceiling from ``RecordingLimits`` was hit.
    case limitExceeded(String)
    case noFramesCaptured
    /// HDR / wide-gamut content we refuse to silently mangle.
    case unsupportedColorSpace(String)
}

extension TriCapError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .screenRecordingPermissionNotDetermined:
            return "TriCap needs Screen & System Audio Recording permission."
        case .screenRecordingPermissionDenied:
            return "Screen Recording permission is turned off for TriCap."
        case .screenCaptureUnavailable(let detail):
            return "ScreenCaptureKit is unavailable: \(detail)"
        case .noDisplaysAvailable:
            return "No capturable display was found."
        case .cancelled:
            return "Capture cancelled."
        case .selectionTooSmall:
            return "The selected region is smaller than one pixel."
        case .captureFailed(let detail):
            return "Capture failed: \(detail)"
        case .encodingFailed(let detail):
            return "Encoding failed: \(detail)"
        case .writeFailed(let detail):
            return "Could not write the file: \(detail)"
        case .limitExceeded(let detail):
            return "Recording limit reached: \(detail)"
        case .noFramesCaptured:
            return "No frames were captured."
        case .unsupportedColorSpace(let detail):
            return "Unsupported colour space: \(detail)"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .screenRecordingPermissionNotDetermined:
            return "Choose “Open System Settings”, enable TriCap under Privacy & Security → Screen & System Audio Recording, then try again."
        case .screenRecordingPermissionDenied:
            return "Enable TriCap under System Settings → Privacy & Security → Screen & System Audio Recording. macOS does not allow an app to re-ask once permission has been denied."
        case .limitExceeded:
            return "Shorten the recording, lower the frame rate, or reduce the long-edge limit in TriCap settings."
        case .unsupportedColorSpace:
            return "TriCap always writes sRGB. Capture from an SDR display, or accept the sRGB conversion."
        default:
            return nil
        }
    }
}
