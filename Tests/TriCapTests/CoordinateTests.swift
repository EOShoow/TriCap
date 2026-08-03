import CoreGraphics
import Testing
@testable import TriCapKit

/// The coordinate layer is the highest-risk pure code in TriCap: a wrong flip or a wrong scale
/// produces a capture that is offset but still plausible-looking, so these tests pin the exact
/// numbers rather than just checking for "reasonable" values.
@Suite("Coordinate conversion")
struct CoordinateTests {

    // A 1512x982 built-in Retina display (scale 2) as the AppKit primary screen.
    let primaryHeight: CGFloat = 982

    @Test("AppKit→Quartz rect flip moves the origin from the bottom-left to the top-left corner")
    func appKitToQuartzRect() {
        // A 100x50 rect whose bottom edge sits 200 pt above the bottom of the primary screen.
        let appKit = CGRect(x: 30, y: 200, width: 100, height: 50)
        let quartz = CoordinateConverter.quartzRect(fromAppKitRect: appKit, primaryHeightInPoints: primaryHeight)

        // Top edge in Quartz space = 982 - (200 + 50) = 732.
        #expect(quartz == CGRect(x: 30, y: 732, width: 100, height: 50))
    }

    @Test("The rect flip is its own inverse")
    func flipRoundTrip() {
        let appKit = CGRect(x: 12.5, y: 340.25, width: 640, height: 360)
        let quartz = CoordinateConverter.quartzRect(fromAppKitRect: appKit, primaryHeightInPoints: primaryHeight)
        let back = CoordinateConverter.appKitRect(fromQuartzRect: quartz, primaryHeightInPoints: primaryHeight)
        #expect(back == appKit)
    }

    @Test("Point flip is its own inverse")
    func pointFlipRoundTrip() {
        let p = CGPoint(x: 42, y: 100)
        let flipped = CoordinateConverter.flipY(point: p, primaryHeightInPoints: primaryHeight)
        #expect(flipped == CGPoint(x: 42, y: 882))
        #expect(CoordinateConverter.flipY(point: flipped, primaryHeightInPoints: primaryHeight) == p)
    }

    @Test("A rect at the very top of the primary screen maps to Quartz y = 0")
    func topEdge() {
        let appKit = CGRect(x: 0, y: primaryHeight - 40, width: 200, height: 40)
        let quartz = CoordinateConverter.quartzRect(fromAppKitRect: appKit, primaryHeightInPoints: primaryHeight)
        #expect(quartz.origin.y == 0)
    }

    @Test("Display-local translation subtracts the display's Quartz origin")
    func displayLocal() {
        // A second display placed to the right of the primary one.
        let secondaryBounds = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
        let quartz = CGRect(x: 1612, y: 100, width: 300, height: 200)
        let local = CoordinateConverter.displayLocalRect(
            fromQuartzGlobalRect: quartz,
            displayBoundsInQuartzPoints: secondaryBounds
        )
        #expect(local == CGRect(x: 100, y: 100, width: 300, height: 200))

        let back = CoordinateConverter.quartzGlobalRect(
            fromDisplayLocalRect: local,
            displayBoundsInQuartzPoints: secondaryBounds
        )
        #expect(back == quartz)
    }

    @Test("Retina scaling doubles point coordinates and snaps outward to whole pixels")
    func retinaScaling() {
        let local = CGRect(x: 10.3, y: 20.7, width: 100.2, height: 50.4)
        let pixels = CoordinateConverter.pixelRect(
            fromDisplayLocalPointRect: local,
            scale: 2.0,
            displaySizeInPoints: CGSize(width: 1512, height: 982)
        )
        // 10.3*2 = 20.6 -> floor 20 ; far edge (10.3+100.2)*2 = 221.0 -> ceil 221
        // 20.7*2 = 41.4 -> floor 41 ; far edge (20.7+50.4)*2 = 142.2 -> ceil 143
        #expect(pixels == CGRect(x: 20, y: 41, width: 201, height: 102))
    }

    @Test("Non-Retina scaling is a pass-through apart from the outward snap")
    func nonRetinaScaling() {
        let local = CGRect(x: 5.5, y: 5.5, width: 10, height: 10)
        let pixels = CoordinateConverter.pixelRect(
            fromDisplayLocalPointRect: local,
            scale: 1.0,
            displaySizeInPoints: CGSize(width: 1920, height: 1080)
        )
        #expect(pixels == CGRect(x: 5, y: 5, width: 11, height: 11))
    }

    @Test("A selection running past the right/bottom edge is clamped to the display")
    func clampsToDisplay() {
        let local = CGRect(x: 1500, y: 970, width: 100, height: 100)
        let pixels = CoordinateConverter.pixelRect(
            fromDisplayLocalPointRect: local,
            scale: 2.0,
            displaySizeInPoints: CGSize(width: 1512, height: 982)
        )
        #expect(pixels == CGRect(x: 3000, y: 1940, width: 24, height: 24))
    }

    @Test("A sub-pixel selection is rejected rather than rounded to zero")
    func subPixelSelectionIsRejected() {
        let pixels = CoordinateConverter.pixelRect(
            fromDisplayLocalPointRect: CGRect(x: 10, y: 10, width: 0, height: 0),
            scale: 2.0,
            displaySizeInPoints: CGSize(width: 1512, height: 982)
        )
        #expect(pixels == nil)
    }

    @Test("A selection entirely outside the display is rejected")
    func offDisplaySelectionIsRejected() {
        let pixels = CoordinateConverter.pixelRect(
            fromDisplayLocalPointRect: CGRect(x: 5000, y: 5000, width: 10, height: 10),
            scale: 2.0,
            displaySizeInPoints: CGSize(width: 1512, height: 982)
        )
        #expect(pixels == nil)
    }

    @Test("Pixel rect converts back to the point rect ScreenCaptureKit receives")
    func pixelsBackToPoints() {
        let pixels = CGRect(x: 20, y: 41, width: 201, height: 102)
        let points = CoordinateConverter.displayLocalPointRect(fromPixelRect: pixels, scale: 2.0)
        #expect(points == CGRect(x: 10, y: 20.5, width: 100.5, height: 51))
    }

    @Test("integralOutward standardises a backwards drag before snapping")
    func integralOutwardHandlesBackwardsDrag() {
        let backwards = CGRect(x: 100.5, y: 200.5, width: -50.5, height: -30.25)
        #expect(backwards.integralOutward == CGRect(x: 50, y: 170, width: 51, height: 31))
    }
}

@Suite("Output sizing")
struct OutputSizingTests {

    @Test("A frame already inside the cap is untouched")
    func noUpscale() {
        let size = OutputSizing.fit(pixelSize: CGSize(width: 800, height: 600), maxLongEdge: 1440)
        #expect(size == CGSize(width: 800, height: 600))
    }

    @Test("Landscape frames are capped on width and keep their aspect ratio")
    func landscapeDownscale() {
        let size = OutputSizing.fit(pixelSize: CGSize(width: 2880, height: 1800), maxLongEdge: 1440)
        #expect(size == CGSize(width: 1440, height: 900))
    }

    @Test("Portrait frames are capped on height")
    func portraitDownscale() {
        let size = OutputSizing.fit(pixelSize: CGSize(width: 1000, height: 4000), maxLongEdge: 1440)
        #expect(size == CGSize(width: 360, height: 1440))
    }

    @Test("An extreme aspect ratio still yields at least one pixel on the short edge")
    func neverCollapsesToZero() {
        let size = OutputSizing.fit(pixelSize: CGSize(width: 10000, height: 3), maxLongEdge: 1440)
        #expect(size.width == 1440)
        #expect(size.height >= 1)
    }

    @Test("Zero input is clamped to 1x1 rather than producing an invalid canvas")
    func zeroInput() {
        let size = OutputSizing.fit(pixelSize: .zero, maxLongEdge: 1440)
        #expect(size == CGSize(width: 1, height: 1))
    }
}
