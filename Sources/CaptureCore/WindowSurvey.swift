import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit
import TriCapKit

/// Turns ScreenCaptureKit's window list into the pure ``WindowCandidate`` values the selection
/// overlay hit-tests against.
///
/// The conversion is the interesting part: `SCWindow.frame` is in **Quartz global points**
/// (top-left origin, +y down) while everything in the selection path works in **AppKit global
/// points** (bottom-left origin, +y up). Getting that flip wrong highlights a rectangle nowhere
/// near the window the pointer is over — and on a multi-display desktop with a display above or
/// left of the primary one, the coordinates are negative, which is exactly where a naive flip
/// falls apart.
public enum WindowSurvey {

    /// Snapshot the current window list, front to back.
    ///
    /// Called once when the selection overlay opens. Returns an empty array rather than throwing
    /// when the window list is unavailable: the overlay then degrades to free-form dragging only,
    /// which still works.
    @MainActor
    public static func currentWindows() async -> [WindowCandidate] {
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return [] }

        let content: SCShareableContent
        do {
            content = try await ScreenRecordingPermission.shareableContent()
        } catch {
            TriCapLog.selection.error(
                "window list unavailable: \(error.localizedDescription, privacy: .public) — free-form selection only"
            )
            return []
        }

        // SCK returns windows front to back; preserve that as the stacking order.
        return content.windows.enumerated().map { index, window in
            candidate(from: window, stackingIndex: index, primaryHeightInPoints: primaryHeight)
        }
    }

    /// Convert one `SCWindow`. Exposed for the self-test, which prints the conversion.
    @MainActor
    public static func candidate(
        from window: SCWindow,
        stackingIndex: Int,
        primaryHeightInPoints: CGFloat
    ) -> WindowCandidate {
        WindowCandidate(
            id: window.windowID,
            frame: CoordinateConverter.appKitRect(
                fromQuartzRect: window.frame,
                primaryHeightInPoints: primaryHeightInPoints
            ),
            level: window.windowLayer,
            isOnScreen: window.isOnScreen,
            bundleIdentifier: window.owningApplication?.bundleIdentifier,
            title: window.title,
            stackingIndex: stackingIndex
        )
    }
}
