import AppKit
import CoreGraphics
import Foundation

/// Snapshots the current display layout into pure ``DisplayGeometry`` values.
///
/// This is the one place in TriCap that reads `NSScreen`. Everything downstream works on the
/// resulting value types, which is what makes the coordinate math unit-testable without a
/// window server. It lives in `TriCapKit` (rather than `CaptureCore`) because both
/// `SelectionUI` and `CaptureCore` need it and neither should depend on the other.
@MainActor
public enum DisplaySurvey {

    /// All active displays, in `NSScreen.screens` order (index 0 is the AppKit origin screen).
    public static func currentDisplays() -> [DisplayGeometry] {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return [] }
        let primaryHeight = primary.frame.height

        return screens.compactMap { screen -> DisplayGeometry? in
            guard let displayID = screen.displayID else { return nil }
            let quartzBounds = CGDisplayBounds(displayID)
            let sourceColorSpace = screen.colorSpace?.cgColorSpace
            return DisplayGeometry(
                displayID: displayID,
                appKitBounds: screen.frame,
                quartzBounds: quartzBounds,
                pointPixelScale: screen.backingScaleFactor,
                primaryHeightInPoints: primaryHeight,
                colorSpaceName: sourceColorSpace?.name as String?,
                colorProfileData: sourceColorSpace?.copyICCData() as Data?,
                colorProfileIsWideGamut: sourceColorSpace?.isWideGamutRGB ?? false,
                usesExtendedDynamicRange: screen.maximumExtendedDynamicRangeColorComponentValue > 1
            )
        }
    }

    /// The display containing `point` (AppKit global points), falling back to the primary screen.
    public static func display(containing point: CGPoint, in displays: [DisplayGeometry]) -> DisplayGeometry? {
        displays.first { $0.appKitBounds.contains(point) } ?? displays.first
    }

    /// The display that holds the largest share of `rect` (AppKit global points).
    ///
    /// A drag that spans two monitors has to resolve to a single ScreenCaptureKit display;
    /// picking the one with the most overlap matches what the user visually intended, and
    /// `CaptureRegion` then clips the selection to that display's bounds.
    public static func displayWithLargestOverlap(of rect: CGRect, in displays: [DisplayGeometry]) -> DisplayGeometry? {
        var best: (display: DisplayGeometry, area: CGFloat)?
        for display in displays {
            let intersection = rect.standardized.intersection(display.appKitBounds)
            guard !intersection.isNull else { continue }
            let area = intersection.width * intersection.height
            if best == nil || area > best!.area {
                best = (display, area)
            }
        }
        return best?.display ?? displays.first
    }
}

extension NSScreen {
    /// `CGDirectDisplayID` for this screen, or `nil` if the device description is missing it.
    public var displayID: CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (deviceDescription[key] as? NSNumber)?.uint32Value
    }
}
