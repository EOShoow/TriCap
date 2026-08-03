import CoreGraphics
import Testing
@testable import TriCapKit

@Suite("CaptureRegion resolution")
struct CaptureRegionTests {

    /// Built-in Retina display: AppKit origin (0,0), Quartz origin (0,0), scale 2.
    let builtIn = DisplayGeometry(
        displayID: 1,
        appKitBounds: CGRect(x: 0, y: 0, width: 1512, height: 982),
        quartzBounds: CGRect(x: 0, y: 0, width: 1512, height: 982),
        pointPixelScale: 2.0,
        primaryHeightInPoints: 982
    )

    /// A 1080p monitor to the right of the built-in display, non-Retina.
    /// AppKit places it at x = 1512 with its *bottom* aligned to the primary screen's bottom;
    /// Quartz places it at x = 1512 with its *top* aligned to the primary screen's top.
    let external = DisplayGeometry(
        displayID: 2,
        appKitBounds: CGRect(x: 1512, y: 0, width: 1920, height: 1080),
        quartzBounds: CGRect(x: 1512, y: -98, width: 1920, height: 1080),
        pointPixelScale: 1.0,
        primaryHeightInPoints: 982
    )

    @Test("A selection on the primary Retina display resolves to doubled pixels")
    func primaryDisplaySelection() throws {
        let region = try #require(
            CaptureRegion(appKitGlobalRect: CGRect(x: 100, y: 100, width: 200, height: 150), display: builtIn)
        )
        // AppKit y=100..250 -> Quartz top edge = 982 - 250 = 732 -> pixels y = 1464
        #expect(region.displayPixelRect == CGRect(x: 200, y: 1464, width: 400, height: 300))
        #expect(region.sourceRectInDisplayPoints == CGRect(x: 100, y: 732, width: 200, height: 150))
        #expect(region.nativePixelSize == CGSize(width: 400, height: 300))
    }

    @Test("A selection on a secondary display is local to that display, not to the desktop")
    func secondaryDisplaySelection() throws {
        // 50 pt in from the external monitor's left edge, 60 pt up from its bottom.
        let region = try #require(
            CaptureRegion(appKitGlobalRect: CGRect(x: 1562, y: 60, width: 320, height: 240), display: external)
        )
        // Quartz y of the rect's top = 982 - (60 + 240) = 682. Display's Quartz top is -98,
        // so display-local y = 682 - (-98) = 780. Scale 1 -> pixels are the same numbers.
        #expect(region.displayPixelRect == CGRect(x: 50, y: 780, width: 320, height: 240))
        #expect(region.sourceRectInDisplayPoints == CGRect(x: 50, y: 780, width: 320, height: 240))
    }

    @Test("A drag spilling past the display edge is clipped, not offset")
    func clipsToDisplay() throws {
        let region = try #require(
            CaptureRegion(appKitGlobalRect: CGRect(x: 1400, y: 900, width: 400, height: 400), display: builtIn)
        )
        // Clipped in AppKit space to x 1400..1512, y 900..982.
        #expect(region.appKitGlobalRect == CGRect(x: 1400, y: 900, width: 112, height: 82))
        #expect(region.displayPixelRect == CGRect(x: 2800, y: 0, width: 224, height: 164))
    }

    @Test("A one-pixel selection at the top-left corner of a Retina display survives")
    func retinaCornerSelection() throws {
        // Half a point = exactly one physical pixel on a 2x display.
        let region = try #require(
            CaptureRegion(
                appKitGlobalRect: CGRect(x: 0, y: 981.5, width: 0.5, height: 0.5),
                display: builtIn
            )
        )
        #expect(region.displayPixelRect == CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    @Test("A selection that misses the display entirely returns nil")
    func missingDisplayReturnsNil() {
        let region = CaptureRegion(
            appKitGlobalRect: CGRect(x: 5000, y: 5000, width: 100, height: 100),
            display: builtIn
        )
        #expect(region == nil)
    }

    @Test("A zero-size drag returns nil")
    func zeroSizeReturnsNil() {
        #expect(CaptureRegion(appKitGlobalRect: CGRect(x: 10, y: 10, width: 0, height: 0), display: builtIn) == nil)
    }

    @Test("A backwards drag is standardised before resolution")
    func backwardsDrag() throws {
        let forward = try #require(
            CaptureRegion(appKitGlobalRect: CGRect(x: 100, y: 100, width: 200, height: 150), display: builtIn)
        )
        let backward = try #require(
            CaptureRegion(appKitGlobalRect: CGRect(x: 300, y: 250, width: -200, height: -150), display: builtIn)
        )
        #expect(forward.displayPixelRect == backward.displayPixelRect)
    }

    @Test("Display pixel size accounts for the scale factor")
    func displayPixelSize() {
        #expect(builtIn.pixelSize == CGSize(width: 3024, height: 1964))
        #expect(external.pixelSize == CGSize(width: 1920, height: 1080))
    }
}
