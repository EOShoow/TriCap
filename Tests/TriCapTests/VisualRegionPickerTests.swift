import CoreGraphics
import Foundation
import Testing
@testable import TriCapKit

private let ownBundle = "app.tricap.TriCap"

/// A 1512×982-point Retina laptop display at the AppKit origin.
private let retina = DisplayGeometry(
    displayID: 1,
    appKitBounds: CGRect(x: 0, y: 0, width: 1512, height: 982),
    quartzBounds: CGRect(x: 0, y: 0, width: 1512, height: 982),
    pointPixelScale: 2,
    primaryHeightInPoints: 982
)

/// A 1× monitor sitting **above and to the left** of the primary one, which is where AppKit
/// coordinates go negative and a naive flip falls apart.
private let secondary = DisplayGeometry(
    displayID: 2,
    appKitBounds: CGRect(x: -1600, y: 982, width: 1600, height: 1200),
    quartzBounds: CGRect(x: -1600, y: -1200, width: 1600, height: 1200),
    pointPixelScale: 1,
    primaryHeightInPoints: 982
)

private func window(
    _ id: UInt32,
    _ frame: CGRect,
    bundle: String? = "com.example.App",
    stacking: Int = 0
) -> WindowCandidate {
    WindowCandidate(
        id: id, frame: frame, level: 0, isOnScreen: true,
        bundleIdentifier: bundle, title: nil, stackingIndex: stacking
    )
}

private func region(_ id: Int, _ frame: CGRect, confidence: Double = 0.9) -> VisualRegionCandidate {
    VisualRegionCandidate(id: id, displayID: 1, frame: frame, confidence: confidence)
}

@Suite("Visual region coordinate mapping")
struct VisualRegionMappingTests {

    @Test("A Retina display's point grid maps one sample to one point")
    func retinaPointGrid() {
        // The field is sampled at the display's point size, so a rectangle at (100, 40) in field
        // samples is at (100, 40) in display-local points — and 200 × 80 native pixels.
        let mapped = VisualRegionMapping.appKitRect(
            fromFieldRect: CGRect(x: 100, y: 40, width: 300, height: 200),
            fieldSize: CGSize(width: 1512, height: 982),
            display: retina
        )
        // Quartz y = 40 from the top → AppKit y = 982 - 40 - 200 = 742.
        #expect(mapped == CGRect(x: 100, y: 742, width: 300, height: 200))
    }

    @Test("A field coarser than the display scales back up")
    func coarseFieldScales() {
        // Half-resolution field: every sample is two points across.
        let mapped = VisualRegionMapping.appKitRect(
            fromFieldRect: CGRect(x: 50, y: 20, width: 150, height: 100),
            fieldSize: CGSize(width: 756, height: 491),
            display: retina
        )
        #expect(mapped == CGRect(x: 100, y: 742, width: 300, height: 200))
    }

    @Test("A display at negative AppKit coordinates maps correctly")
    func negativeCoordinateDisplay() {
        // The second monitor is above and left of the primary: its AppKit origin is (-1600, 982)
        // while its Quartz origin is (-1600, -1200). Getting this wrong highlights a rectangle on
        // the wrong screen entirely, which no amount of detector accuracy would rescue.
        let mapped = VisualRegionMapping.appKitRect(
            fromFieldRect: CGRect(x: 200, y: 300, width: 400, height: 250),
            fieldSize: CGSize(width: 1600, height: 1200),
            display: secondary
        )
        // Quartz global: x = -1600 + 200 = -1400, y = -1200 + 300 = -900, height 250.
        // AppKit y = 982 - (-900) - 250 = 1632.
        #expect(mapped == CGRect(x: -1400, y: 1632, width: 400, height: 250))
    }

    @Test("A mapped rectangle lands back on the display it came from")
    func mappedRectangleResolvesToItsDisplay() {
        for display in [retina, secondary] {
            let size = display.quartzBounds.size
            let mapped = VisualRegionMapping.appKitRect(
                fromFieldRect: CGRect(x: 120, y: 90, width: 240, height: 180),
                fieldSize: size,
                display: display
            )
            let frame = try! #require(mapped)
            #expect(display.appKitBounds.contains(frame), "\(frame) escaped display \(display.displayID)")
            // And it survives the trip through the type every capture actually uses.
            let captured = try! #require(CaptureRegion(appKitGlobalRect: frame, display: display))
            #expect(captured.appKitGlobalRect == frame)
            #expect(captured.displayPixelRect.width == 240 * display.pointPixelScale)
        }
    }

    @Test("Degenerate inputs map to nothing rather than trapping")
    func degenerateMapping() {
        #expect(VisualRegionMapping.appKitRect(
            fromFieldRect: CGRect(x: 0, y: 0, width: 10, height: 10),
            fieldSize: .zero, display: retina
        ) == nil)
        #expect(VisualRegionMapping.appKitRect(
            fromFieldRect: .zero,
            fieldSize: CGSize(width: 1512, height: 982), display: retina
        ) == nil)
    }

    @Test("Rectangles too small to mean anything are dropped")
    func tinyRegionsDropped() {
        let detected = [
            VisualRegionDetector.Candidate(
                rect: CGRect(x: 10, y: 10, width: 8, height: 8),
                confidence: 0.9, interiorIsBrighter: true, edgeSupport: 1, contrast: 0.5
            ),
            VisualRegionDetector.Candidate(
                rect: CGRect(x: 100, y: 100, width: 300, height: 200),
                confidence: 0.9, interiorIsBrighter: true, edgeSupport: 1, contrast: 0.5
            ),
        ]
        let candidates = VisualRegionMapping.candidates(
            from: detected, fieldSize: CGSize(width: 1512, height: 982), display: retina
        )
        #expect(candidates.count == 1)
        #expect(candidates[0].frame.width == 300)
    }

    @Test("Visual capture frames exclude a physical-pixel rim on Retina")
    func captureProtectionInsetsSourcePixels() {
        let detected = [
            VisualRegionDetector.Candidate(
                rect: CGRect(x: 100, y: 40, width: 300, height: 200),
                confidence: 0.9, interiorIsBrighter: true, edgeSupport: 1, contrast: 0.5
            ),
        ]
        let candidates = VisualRegionMapping.candidates(
            from: detected,
            fieldSize: CGSize(width: 1512, height: 982),
            display: retina,
            captureInsetInPixels: 3
        )
        let protected = try! #require(candidates.first)

        // Three source pixels on each side equals 1.5 points on this 2× display. The CaptureRegion
        // path must see six fewer source pixels in each dimension — the same frame hover/click/snap
        // will use in production.
        #expect(protected.frame == CGRect(x: 101.5, y: 743.5, width: 297, height: 197))
        let capture = try! #require(CaptureRegion(appKitGlobalRect: protected.frame, display: retina))
        #expect(capture.nativePixelSize == CGSize(width: 594, height: 394))
        #expect(capture.displayPixelRect == CGRect(x: 203, y: 83, width: 594, height: 394))
    }

    @Test("Visual protection stays display-local on a secondary monitor")
    func captureProtectionUsesSecondaryDisplayOrigin() {
        let detected = [
            VisualRegionDetector.Candidate(
                rect: CGRect(x: 200, y: 300, width: 400, height: 250),
                confidence: 0.9, interiorIsBrighter: true, edgeSupport: 1, contrast: 0.5
            ),
        ]
        let candidates = VisualRegionMapping.candidates(
            from: detected,
            fieldSize: secondary.quartzBounds.size,
            display: secondary,
            captureInsetInPixels: 3
        )

        #expect(candidates.first?.frame == CGRect(x: -1397, y: 1635, width: 394, height: 244))
    }

    @Test("Protection never collapses a small candidate")
    func captureProtectionIsCappedBeforeCollapse() {
        let protected = VisualRegionMapping.protectedFrame(
            CGRect(x: 10, y: 10, width: 1, height: 1), insetInPixels: 3, display: retina
        )
        #expect(protected == CGRect(x: 10, y: 10, width: 1, height: 1))
    }

    @Test("Identifiers stay unique across displays")
    func identifiersAreUnique() {
        let detected = [
            VisualRegionDetector.Candidate(
                rect: CGRect(x: 100, y: 100, width: 300, height: 200),
                confidence: 0.9, interiorIsBrighter: true, edgeSupport: 1, contrast: 0.5
            ),
        ]
        let first = VisualRegionMapping.candidates(
            from: detected, fieldSize: CGSize(width: 1512, height: 982), display: retina
        )
        let second = VisualRegionMapping.candidates(
            from: detected, fieldSize: CGSize(width: 1600, height: 1200), display: secondary,
            startingID: first.count
        )
        #expect(Set((first + second).map(\.id)).count == first.count + second.count)
        #expect(second.first?.displayID == 2)
    }
}

@Suite("Choosing between a window and what the pixels show")
struct VisualRegionPickerTests {

    let windowFrame = CGRect(x: 100, y: 100, width: 800, height: 600)

    @Test("A confident rectangle inside the window wins — that is the whole feature")
    func nestedRegionBeatsTheWindow() {
        let canvas = region(1, CGRect(x: 200, y: 200, width: 400, height: 300))
        let target = VisualRegionPicker.target(
            at: CGPoint(x: 300, y: 300), window: window(9, windowFrame), visualRegions: [canvas]
        )
        #expect(target == .visualRegion(canvas))
        #expect(target?.frame == canvas.frame)
        #expect(target?.isVisualRegion == true)
    }

    @Test("A low-confidence rectangle falls back to the window")
    func lowConfidenceFallsBackToTheWindow() {
        let unsure = region(1, CGRect(x: 200, y: 200, width: 400, height: 300), confidence: 0.4)
        let underneath = window(9, windowFrame)
        let target = VisualRegionPicker.target(
            at: CGPoint(x: 300, y: 300), window: underneath, visualRegions: [unsure]
        )
        #expect(target == .window(underneath))
    }

    @Test("A rectangle that is essentially the window loses to the window")
    func nearWindowSizedRegionLoses() {
        // A maximised window whose content area is a flat colour reads as a rectangle almost the
        // size of the window. The window server's frame is exact; an inferred edge is not, and
        // capturing "the window minus two points of chrome" is not what the user clicked for.
        let backdrop = region(1, windowFrame.insetBy(dx: 4, dy: 4))
        let underneath = window(9, windowFrame)
        let target = VisualRegionPicker.target(
            at: CGPoint(x: 300, y: 300), window: underneath, visualRegions: [backdrop]
        )
        #expect(target == .window(underneath))
    }

    @Test("A rectangle mostly outside the window loses to the window")
    func regionEscapingTheWindowLoses() {
        // Overlapping geometry that is not content *of* this window: believing it would capture
        // a rectangle spanning two unrelated things.
        let straddling = region(1, CGRect(x: 700, y: 200, width: 600, height: 200))
        let underneath = window(9, windowFrame)
        let target = VisualRegionPicker.target(
            at: CGPoint(x: 800, y: 300), window: underneath, visualRegions: [straddling]
        )
        #expect(target == .window(underneath))
    }

    @Test("With no window under the pointer a confident rectangle still wins")
    func regionOnTheDesktop() {
        let onDesktop = region(1, CGRect(x: 200, y: 200, width: 400, height: 300))
        let target = VisualRegionPicker.target(
            at: CGPoint(x: 300, y: 300), window: nil, visualRegions: [onDesktop]
        )
        #expect(target == .visualRegion(onDesktop))
    }

    @Test("No regions and no window means free-form dragging")
    func nothingAtAll() {
        #expect(VisualRegionPicker.target(at: .zero, window: nil, visualRegions: []) == nil)
    }

    @Test("The smallest confident rectangle containing the pointer wins")
    func smallestNestedRegionWins() {
        // A panel inside a canvas inside a window is three plausible targets. The innermost is
        // the one the pointer is most specifically on.
        let canvas = region(1, CGRect(x: 200, y: 200, width: 400, height: 300))
        let panel = region(2, CGRect(x: 250, y: 250, width: 150, height: 100))
        let target = VisualRegionPicker.target(
            at: CGPoint(x: 300, y: 300), window: window(9, windowFrame), visualRegions: [canvas, panel]
        )
        #expect(target == .visualRegion(panel))

        // A point inside the canvas but outside the panel gets the canvas.
        let outer = VisualRegionPicker.target(
            at: CGPoint(x: 550, y: 450), window: window(9, windowFrame), visualRegions: [canvas, panel]
        )
        #expect(outer == .visualRegion(canvas))
    }

    @Test("A smaller but unconvincing rectangle does not shadow a confident larger one")
    func smallestOnlyAmongTheConfident() {
        let canvas = region(1, CGRect(x: 200, y: 200, width: 400, height: 300))
        let doubtful = region(2, CGRect(x: 250, y: 250, width: 150, height: 100), confidence: 0.3)
        let target = VisualRegionPicker.target(
            at: CGPoint(x: 300, y: 300), window: window(9, windowFrame), visualRegions: [canvas, doubtful]
        )
        #expect(target == .visualRegion(canvas))
    }

    @Test("Hover, click and the pixel readout all read one rectangle")
    func oneRectangleDrivesEverything() {
        // The guarantee the overlay depends on: whatever `target` reports is what gets
        // highlighted, measured, captured and snapped to. There is no second source of truth.
        let canvas = region(1, CGRect(x: 200, y: 200, width: 400, height: 300))
        let point = CGPoint(x: 300, y: 300)
        let target = try! #require(VisualRegionPicker.target(
            at: point, window: window(9, windowFrame), visualRegions: [canvas]
        ))
        let edges = VisualRegionPicker.snapEdges(
            windows: [window(9, windowFrame)], displayBounds: [], visualRegions: [canvas]
        )
        #expect(edges.contains(target.frame))
        #expect(VisualRegionPicker.visualRegion(at: point, in: [canvas])?.frame == target.frame)
    }
}

@Suite("Snapping to visual regions")
struct VisualRegionSnapTests {

    let display = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let windowFrame = CGRect(x: 100, y: 100, width: 800, height: 600)

    @Test("A confident rectangle contributes snap edges; windows and displays still do too")
    func regionsJoinTheSnapSet() {
        let canvas = region(1, CGRect(x: 200, y: 200, width: 400, height: 300))
        let edges = VisualRegionPicker.snapEdges(
            windows: [window(9, windowFrame)], displayBounds: [display], visualRegions: [canvas]
        )
        #expect(edges.contains(canvas.frame))
        #expect(edges.contains(windowFrame))
        #expect(edges.contains(display))

        let dragged = CGRect(x: 203, y: 202, width: 395, height: 297)
        #expect(SnapEngine.snap(rect: dragged, to: edges) == canvas.frame)
    }

    @Test("A rectangle too unconvincing to click cannot tug a drag either")
    func unconvincingRegionsAreNotSnapTargets() {
        // Same rule the window path already follows: anything the user cannot click must not
        // silently move their selection.
        let doubtful = region(1, CGRect(x: 200, y: 200, width: 400, height: 300), confidence: 0.3)
        let edges = VisualRegionPicker.snapEdges(
            windows: [], displayBounds: [display], visualRegions: [doubtful]
        )
        #expect(edges == [display])

        let dragged = CGRect(x: 203, y: 202, width: 395, height: 297)
        #expect(SnapEngine.snap(rect: dragged, to: edges) == dragged)
    }

    @Test("Holding Option still disables snapping, visual regions included")
    func optionDisablesSnappingToRegions() {
        let canvas = region(1, CGRect(x: 200, y: 200, width: 400, height: 300))
        let edges = VisualRegionPicker.snapEdges(
            windows: [], displayBounds: [display], visualRegions: [canvas]
        )
        let dragged = CGRect(x: 203, y: 202, width: 395, height: 297)
        #expect(SnapEngine.snap(rect: dragged, to: edges, enabled: false) == dragged)
    }

    @Test("TriCap's own windows stay excluded when regions are in play")
    func ownWindowsStillExcluded() {
        let overlay = window(1, CGRect(x: 0, y: 0, width: 1440, height: 900), bundle: ownBundle)
        let edges = VisualRegionPicker.snapEdges(
            windows: [overlay], displayBounds: [display], visualRegions: [],
            ownBundleIdentifier: ownBundle
        )
        #expect(edges == [display])
    }
}
