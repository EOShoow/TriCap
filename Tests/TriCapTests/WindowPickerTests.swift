import CoreGraphics
import Foundation
import Testing
@testable import TriCapKit

private let ownBundle = "app.tricap.TriCap"

private func window(
    _ id: UInt32,
    _ frame: CGRect,
    level: Int = 0,
    onScreen: Bool = true,
    bundle: String? = "com.example.App",
    stacking: Int = 0
) -> WindowCandidate {
    WindowCandidate(
        id: id, frame: frame, level: level, isOnScreen: onScreen,
        bundleIdentifier: bundle, title: nil, stackingIndex: stacking
    )
}

@Suite("Window picking")
struct WindowPickerTests {

    @Test("The frontmost window under the pointer wins, not the smallest")
    func stackingOrderDecidesOverlap() {
        // A small back window fully inside a large front one: pointing at the overlap must give
        // the window actually visible there.
        let back = window(1, CGRect(x: 100, y: 100, width: 200, height: 200), stacking: 5)
        let front = window(2, CGRect(x: 0, y: 0, width: 800, height: 600), stacking: 0)

        let picked = WindowPicker.window(at: CGPoint(x: 150, y: 150), in: [back, front])
        #expect(picked?.id == 2)
    }

    @Test("A point outside every window picks nothing")
    func emptySpace() {
        let only = window(1, CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(WindowPicker.window(at: CGPoint(x: 500, y: 500), in: [only]) == nil)
    }

    @Test("TriCap's own windows are never offered")
    func excludesSelf() {
        // Otherwise the selection overlay itself — which covers the whole screen — would be the
        // answer for every point.
        let overlay = window(1, CGRect(x: 0, y: 0, width: 2000, height: 2000), bundle: ownBundle, stacking: 0)
        let other = window(2, CGRect(x: 100, y: 100, width: 200, height: 200), stacking: 1)

        let picked = WindowPicker.window(
            at: CGPoint(x: 150, y: 150), in: [overlay, other], ownBundleIdentifier: ownBundle
        )
        #expect(picked?.id == 2)
    }

    @Test("Off-screen, minimised and hidden windows are excluded")
    func excludesOffScreen() {
        let hidden = window(1, CGRect(x: 0, y: 0, width: 400, height: 400), onScreen: false)
        #expect(WindowPicker.window(at: CGPoint(x: 10, y: 10), in: [hidden]) == nil)
    }

    @Test("Windows above the ordinary application layer are excluded", arguments: [1, 3, 25, 1000])
    func excludesSystemLayers(level: Int) {
        // The menu bar, the Dock, status items and security windows all live above layer 0.
        let systemWindow = window(1, CGRect(x: 0, y: 0, width: 400, height: 400), level: level)
        #expect(WindowPicker.window(at: CGPoint(x: 10, y: 10), in: [systemWindow]) == nil)
    }

    @Test("Windows below the application layer are excluded too", arguments: [
        -1,             // just below
        -2147483603,    // the Finder desktop / Dock wallpaper window
        -2147483628,    // "Display Backstop"
        -25,
    ])
    func excludesBelowApplicationLayer(level: Int) {
        // A live `SCShareableContent` probe on this machine listed Notification Centre widgets,
        // `underbelly`, the Finder desktop, the Dock's wallpaper window and "Display Backstop" at
        // negative layers. They are full-screen or nearly so, which made the desktop itself a
        // hover target. Nothing public says what lives down there, so only layer 0 qualifies.
        let furniture = window(1, CGRect(x: 0, y: 0, width: 2000, height: 1200), level: level)
        #expect(WindowPicker.window(at: CGPoint(x: 10, y: 10), in: [furniture]) == nil)
        #expect(!WindowPicker.isSelectable(furniture, ownBundleIdentifier: nil))
    }

    @Test("Only the ordinary application layer is selectable")
    func onlyLayerZero() {
        let ordinary = window(1, CGRect(x: 0, y: 0, width: 400, height: 400), level: 0)
        #expect(WindowPicker.isSelectable(ordinary, ownBundleIdentifier: nil))
        #expect(WindowPicker.ordinaryApplicationLayer == 0)
    }

    @Test("System furniture does not shadow a real window underneath the pointer")
    func desktopDoesNotWinOverARealWindow() {
        // The desktop is frontmost in stacking terms for this test on purpose: even so, the real
        // window must be the answer.
        let desktop = window(1, CGRect(x: 0, y: 0, width: 2000, height: 1200), level: -2147483603, stacking: 0)
        let real = window(2, CGRect(x: 100, y: 100, width: 400, height: 300), level: 0, stacking: 5)
        #expect(WindowPicker.window(at: CGPoint(x: 200, y: 200), in: [desktop, real])?.id == 2)
    }

    @Test("Degenerate and tiny windows are excluded")
    func excludesTinyWindows() {
        for size in [CGSize(width: 0, height: 0), CGSize(width: 1, height: 1), CGSize(width: 400, height: 2)] {
            let tiny = window(1, CGRect(origin: .zero, size: size))
            #expect(
                WindowPicker.window(at: CGPoint(x: 0.5, y: 0.5), in: [tiny]) == nil,
                "\(size) should not be selectable"
            )
        }
    }

    @Test("Windows on a display at negative coordinates are picked correctly")
    func negativeCoordinates() {
        // A second display above/left of the primary one produces negative AppKit coordinates.
        let onSecondDisplay = window(7, CGRect(x: -1600, y: 900, width: 800, height: 600))
        let picked = WindowPicker.window(at: CGPoint(x: -1200, y: 1200), in: [onSecondDisplay])
        #expect(picked?.id == 7)
    }

    @Test("selectableWindows returns front to back with exclusions applied")
    func selectableOrdering() {
        let candidates = [
            window(1, CGRect(x: 0, y: 0, width: 300, height: 300), stacking: 2),
            window(2, CGRect(x: 0, y: 0, width: 300, height: 300), bundle: ownBundle, stacking: 0),
            window(3, CGRect(x: 0, y: 0, width: 300, height: 300), stacking: 1),
        ]
        let result = WindowPicker.selectableWindows(in: candidates, ownBundleIdentifier: ownBundle)
        #expect(result.map(\.id) == [3, 1])
    }

    @Test("A window exactly under the pointer edge still counts")
    func boundaryPoint() {
        let candidate = window(1, CGRect(x: 100, y: 100, width: 200, height: 200))
        #expect(WindowPicker.window(at: CGPoint(x: 100, y: 100), in: [candidate])?.id == 1)
        // `CGRect.contains` is half-open at the far edge, which is the behaviour we want: two
        // abutting windows must not both claim the shared boundary.
        #expect(WindowPicker.window(at: CGPoint(x: 300, y: 300), in: [candidate]) == nil)
    }
}

@Suite("Snap edges come from the same filtered list as highlighting")
struct SnapEdgeSourceTests {

    let display = CGRect(x: 0, y: 0, width: 1440, height: 900)

    /// Every kind of window that must be invisible to *both* hover and snapping.
    private var excluded: [WindowCandidate] {
        [
            window(10, CGRect(x: 0, y: 0, width: 1440, height: 900), level: -2147483603, stacking: 1),
            window(11, CGRect(x: 200, y: 200, width: 300, height: 300), level: 25, stacking: 2),
            window(12, CGRect(x: 300, y: 300, width: 300, height: 300), bundle: ownBundle, stacking: 3),
            window(13, CGRect(x: 400, y: 400, width: 300, height: 300), onScreen: false, stacking: 4),
            window(14, CGRect(x: 500, y: 500, width: 2, height: 2), stacking: 5),
        ]
    }

    @Test("An excluded window contributes no snap edge")
    func excludedWindowsAreNotSnapTargets() {
        // The bug: `candidates` was filtered but `snapEdges` was built from the raw list, so the
        // desktop and the Dock's wallpaper window supplied full-screen snap lines that nothing
        // could be hovered onto.
        let edges = WindowPicker.snapEdges(
            in: excluded, displayBounds: [display], ownBundleIdentifier: ownBundle
        )
        #expect(edges == [display], "only the display survives")
    }

    @Test("Nothing excluded can be hovered either")
    func excludedWindowsAreNotHoverTargets() {
        for candidate in excluded {
            let midpoint = CGPoint(x: candidate.frame.midX, y: candidate.frame.midY)
            #expect(
                WindowPicker.window(at: midpoint, in: excluded, ownBundleIdentifier: ownBundle) == nil,
                "window \(candidate.id) at level \(candidate.level) must not be selectable"
            )
        }
    }

    @Test("A real window contributes a snap edge, and so does the display")
    func realWindowsSnap() {
        let real = window(1, CGRect(x: 100, y: 100, width: 400, height: 300))
        let edges = WindowPicker.snapEdges(
            in: excluded + [real], displayBounds: [display], ownBundleIdentifier: ownBundle
        )
        #expect(edges.contains(real.frame))
        #expect(edges.contains(display), "the screen edge is always a legitimate target")
        #expect(edges.count == 2)
    }

    @Test("Snapping against a desktop-sized excluded window leaves the drag alone")
    func desktopDoesNotPullTheSelection() {
        // A selection dragged near the middle of the screen used to be tugged by the desktop
        // window's edges, which happen to coincide with the display's.
        let insideEdge = window(9, CGRect(x: 300, y: 300, width: 500, height: 400), level: -3)
        let edges = WindowPicker.snapEdges(
            in: [insideEdge], displayBounds: [display], ownBundleIdentifier: ownBundle
        )
        let dragged = CGRect(x: 303, y: 302, width: 200, height: 150)
        #expect(SnapEngine.snap(rect: dragged, to: edges) == dragged)
    }

    @Test("With no windows at all, the display is still a snap target")
    func displayOnly() {
        let edges = WindowPicker.snapEdges(in: [], displayBounds: [display])
        #expect(edges == [display])
        let dragged = CGRect(x: 5, y: 100, width: 200, height: 300)
        #expect(SnapEngine.snap(rect: dragged, to: edges).minX == 0)
    }
}

@Suite("Click versus drag")
struct SelectionGestureTests {

    @Test("A press that barely moves stays a click")
    func tinyMovementIsAClick() {
        var gesture = SelectionGesture(origin: CGPoint(x: 100, y: 100))
        gesture.update(to: CGPoint(x: 102, y: 101))
        #expect(gesture.mode == .tentative)
    }

    @Test("Passing the threshold makes it a drag")
    func pastThresholdIsADrag() {
        var gesture = SelectionGesture(origin: CGPoint(x: 100, y: 100))
        gesture.update(to: CGPoint(x: 120, y: 100))
        #expect(gesture.mode == .dragging)
    }

    @Test("A drag never reverts to a click")
    func draggingIsSticky() {
        // Dragging out and back to the origin must not turn a region selection into a window
        // click on release.
        var gesture = SelectionGesture(origin: CGPoint(x: 100, y: 100))
        gesture.update(to: CGPoint(x: 200, y: 200))
        gesture.update(to: CGPoint(x: 100, y: 100))
        #expect(gesture.mode == .dragging)
    }

    @Test("The threshold is measured radially, not per axis")
    func thresholdIsRadial() {
        #expect(!SelectionGesture.exceedsThreshold(from: .zero, to: CGPoint(x: 4, y: 4)))
        #expect(SelectionGesture.exceedsThreshold(from: .zero, to: CGPoint(x: 5, y: 5)))
    }
}

@Suite("Edge snapping")
struct SnapEngineTests {

    let windowFrame = CGRect(x: 100, y: 100, width: 400, height: 300)
    let display = CGRect(x: 0, y: 0, width: 1440, height: 900)

    @Test("A selection near a window edge snaps to it")
    func snapsToWindowEdge() {
        let dragged = CGRect(x: 104, y: 103, width: 390, height: 295)
        let snapped = SnapEngine.snap(rect: dragged, to: [windowFrame, display])
        #expect(snapped == windowFrame)
    }

    @Test("A selection far from every edge is untouched")
    func farFromEdges() {
        let dragged = CGRect(x: 700, y: 600, width: 100, height: 80)
        #expect(SnapEngine.snap(rect: dragged, to: [windowFrame, display]) == dragged)
    }

    @Test("Holding Option disables snapping entirely")
    func optionDisablesSnapping() {
        let dragged = CGRect(x: 104, y: 103, width: 390, height: 295)
        #expect(SnapEngine.snap(rect: dragged, to: [windowFrame, display], enabled: false) == dragged)
    }

    @Test("Each side snaps independently, so a selection can span two windows")
    func sidesSnapIndependently() {
        let left = CGRect(x: 100, y: 100, width: 200, height: 200)
        let right = CGRect(x: 400, y: 100, width: 200, height: 200)
        let dragged = CGRect(x: 103, y: 150, width: 494, height: 20)  // left edge near `left`, right near `right`

        let snapped = SnapEngine.snap(rect: dragged, to: [left, right])
        #expect(snapped.minX == 100)
        #expect(snapped.maxX == 600)
    }

    @Test("Display bounds are snap targets too")
    func snapsToDisplayEdges() {
        let dragged = CGRect(x: 5, y: 100, width: 200, height: 300)
        let snapped = SnapEngine.snap(rect: dragged, to: [display])
        #expect(snapped.minX == 0)
        #expect(snapped.maxX == 205, "the far edge is nowhere near a display edge")
    }

    @Test("A collapsing snap on one axis does not cancel a valid snap on the other")
    func perAxisFallback() {
        // A 4 pt tall selection near the top of the display: both of its horizontal sides are
        // within the threshold of y = 900, so snapping them both would leave a zero-height rect.
        // That axis keeps its original span; the horizontal snap still applies.
        let dragged = CGRect(x: 5, y: 894, width: 200, height: 4)
        let snapped = SnapEngine.snap(rect: dragged, to: [display])

        #expect(snapped.minX == 0, "the x axis should still snap")
        #expect(snapped.minY == 894, "the y axis keeps its own span rather than collapsing")
        #expect(snapped.height == 4)
    }

    @Test("A snap that would invert or collapse the rect is refused")
    func refusesDegenerateSnap() {
        // Both edges within threshold of the same line would produce a zero-width rect.
        let line = CGRect(x: 200, y: 0, width: 0, height: 900)
        let dragged = CGRect(x: 198, y: 100, width: 4, height: 100)
        let snapped = SnapEngine.snap(rect: dragged, to: [line])
        #expect(snapped.width > 0)
        #expect(snapped.height > 0)
    }

    @Test("No candidate edges means no change")
    func noEdges() {
        let dragged = CGRect(x: 10, y: 10, width: 50, height: 50)
        #expect(SnapEngine.snap(rect: dragged, to: []) == dragged)
    }

    @Test("nearest() picks the closest line within the threshold")
    func nearestLine() {
        #expect(SnapEngine.nearest(103, in: [100, 140], threshold: 8) == 100)
        #expect(SnapEngine.nearest(120, in: [100, 140], threshold: 8) == 120)
        #expect(SnapEngine.nearest(136, in: [100, 140], threshold: 8) == 140)
    }
}
