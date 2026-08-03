import CoreGraphics
import Foundation

/// Everything TriCap knows about one display, expressed in every space we need.
///
/// Built once per capture session from `NSScreen` + `CGDisplayBounds` (see
/// `SelectionUI.ScreenSurvey`) so that the geometry math below stays testable without
/// a window server.
public struct DisplayGeometry: Sendable, Equatable {
    public let displayID: CGDirectDisplayID
    /// Display bounds in AppKit global points (bottom-left origin, +y up).
    public let appKitBounds: CGRect
    /// Display bounds in Quartz global points (top-left origin, +y down).
    public let quartzBounds: CGRect
    /// Point→pixel scale for this display (2.0 on Retina).
    public let pointPixelScale: CGFloat
    /// Height of the AppKit primary screen, needed for every y flip.
    public let primaryHeightInPoints: CGFloat
    /// Display profile metadata used only to interpret an untagged capture buffer. It is never
    /// assigned to ScreenCaptureKit's non-retaining `colorSpaceName` property.
    public let colorSpaceName: String?
    public let colorProfileData: Data?
    /// `true` for display profiles whose gamut exceeds ordinary sRGB. This remains useful when a
    /// custom ICC profile has no Core Graphics name.
    public let colorProfileIsWideGamut: Bool
    /// Whether the source display can present extended-dynamic-range values. The BGRA8 capture
    /// path cannot preserve those highlights, so this bit is carried into the editor notice.
    public let usesExtendedDynamicRange: Bool

    public init(
        displayID: CGDirectDisplayID,
        appKitBounds: CGRect,
        quartzBounds: CGRect,
        pointPixelScale: CGFloat,
        primaryHeightInPoints: CGFloat,
        colorSpaceName: String? = CGColorSpace.sRGB as String,
        colorProfileData: Data? = nil,
        colorProfileIsWideGamut: Bool = false,
        usesExtendedDynamicRange: Bool = false
    ) {
        self.displayID = displayID
        self.appKitBounds = appKitBounds
        self.quartzBounds = quartzBounds
        self.pointPixelScale = pointPixelScale
        self.primaryHeightInPoints = primaryHeightInPoints
        self.colorSpaceName = colorSpaceName
        self.colorProfileData = colorProfileData
        self.colorProfileIsWideGamut = colorProfileIsWideGamut
        self.usesExtendedDynamicRange = usesExtendedDynamicRange
    }

    /// Whether converting this display's capture into 8-bit sRGB requires an editor notice.
    public var needsColorConversionNotice: Bool {
        colorProfileIsWideGamut || usesExtendedDynamicRange
    }

    /// Reconstruct the public display profile for capture buffers that arrive without a colour
    /// attachment. A standard name preserves useful provenance; ICC data covers unnamed profiles.
    public var displayColorSpace: CGColorSpace {
        if let colorSpaceName,
           let named = CGColorSpace(name: colorSpaceName as CFString) {
            return named
        }
        if let colorProfileData,
           let profile = CGColorSpace(iccData: colorProfileData as CFData) {
            return profile
        }
        return CGColorSpace(name: CGColorSpace.sRGB)!
    }

    /// Native pixel size of the display.
    public var pixelSize: CGSize {
        CGSize(
            width: (quartzBounds.width * pointPixelScale).rounded(),
            height: (quartzBounds.height * pointPixelScale).rounded()
        )
    }
}

/// A user selection resolved against exactly one display, carrying every representation
/// downstream code needs. Constructing this is the *only* supported way to turn a drag
/// into capture parameters.
public struct CaptureRegion: Sendable, Equatable {
    public let display: DisplayGeometry
    /// The rect the user actually dragged, in AppKit global points.
    public let appKitGlobalRect: CGRect
    /// Pixel-snapped rect on the display's native pixel grid (top-left origin).
    public let displayPixelRect: CGRect
    /// The point rect corresponding exactly to `displayPixelRect`; this is what
    /// `SCStreamConfiguration.sourceRect` receives.
    public let sourceRectInDisplayPoints: CGRect

    /// Native pixel size of the selection before any long-edge downscale.
    public var nativePixelSize: CGSize {
        CGSize(width: displayPixelRect.width, height: displayPixelRect.height)
    }

    /// Resolve an AppKit-global selection against a display.
    ///
    /// Returns `nil` when the selection does not overlap the display or collapses to
    /// less than a pixel — callers treat that as "user cancelled with a stray click".
    public init?(appKitGlobalRect rect: CGRect, display: DisplayGeometry) {
        let standardized = rect.standardized
        guard standardized.width > 0, standardized.height > 0 else { return nil }

        // Clip to the display first, in AppKit space, so a drag that spills onto a
        // neighbouring monitor captures the part that belongs to *this* display.
        let clippedAppKit = standardized.intersection(display.appKitBounds)
        guard !clippedAppKit.isNull, clippedAppKit.width > 0, clippedAppKit.height > 0 else { return nil }

        let quartz = CoordinateConverter.quartzRect(
            fromAppKitRect: clippedAppKit,
            primaryHeightInPoints: display.primaryHeightInPoints
        )
        let local = CoordinateConverter.displayLocalRect(
            fromQuartzGlobalRect: quartz,
            displayBoundsInQuartzPoints: display.quartzBounds
        )
        guard let pixels = CoordinateConverter.pixelRect(
            fromDisplayLocalPointRect: local,
            scale: display.pointPixelScale,
            displaySizeInPoints: display.quartzBounds.size
        ) else { return nil }

        self.display = display
        self.appKitGlobalRect = clippedAppKit
        self.displayPixelRect = pixels
        self.sourceRectInDisplayPoints = CoordinateConverter.displayLocalPointRect(
            fromPixelRect: pixels,
            scale: display.pointPixelScale
        )
    }

    /// Memberwise initializer used by tests and by callers that already did the math.
    public init(
        display: DisplayGeometry,
        appKitGlobalRect: CGRect,
        displayPixelRect: CGRect,
        sourceRectInDisplayPoints: CGRect
    ) {
        self.display = display
        self.appKitGlobalRect = appKitGlobalRect
        self.displayPixelRect = displayPixelRect
        self.sourceRectInDisplayPoints = sourceRectInDisplayPoints
    }
}
