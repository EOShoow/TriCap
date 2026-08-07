import AppKit
import Foundation
import Testing
@testable import SelectionUI

/// The black mode banner at the top of the selection overlay must survive everything drawn after
/// it. The original `draw(_:)` painted the banner *first* and then punched the selection (and the
/// window highlight) out of the dimming layer with `.copy` blending — which replaces pixels, so
/// any highlight or selection overlapping the banner erased it. A full-screen window hover, the
/// most ordinary case on a near-empty desktop, blanked the banner entirely.
///
/// These tests render the real view through AppKit's display path and read pixels back.
@MainActor
@Suite("Selection mode banner stays on top")
struct SelectionBannerTests {

    private let size = CGSize(width: 900, height: 560)

    /// Render the overlay exactly as AppKit would, at `scale`× backing.
    private func render(
        _ configure: (SelectionOverlayView) -> Void,
        scale: Int = 1
    ) -> NSBitmapImageRep {
        let view = SelectionOverlayView(frame: NSRect(origin: .zero, size: size))
        configure(view)

        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width) * scale,
            pixelsHigh: Int(size.height) * scale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        rep.size = NSSize(width: size.width, height: size.height)
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// The banner's fill is 72% black over the 35% dim layer, so anywhere inside it the combined
    /// alpha is ≥ 0.8. A `.copy` erase leaves 0.12 (highlight) or 0.0 (selection punch), so alpha
    /// at the banner's centre is a clean discriminator.
    private func bannerCentreAlpha(_ rep: NSBitmapImageRep, scale: Int = 1) -> CGFloat {
        let x = rep.pixelsWide / 2
        let y = 30 * scale   // rows count from the top; the banner spans roughly rows 16–52
        return rep.colorAt(x: x, y: y)?.alphaComponent ?? 0
    }

    /// The banner title is white; look for any bright pixel in the banner strip.
    private func bannerHasBrightText(_ rep: NSBitmapImageRep, scale: Int = 1) -> Bool {
        for y in stride(from: 18 * scale, to: 50 * scale, by: 2) {
            for x in stride(from: rep.pixelsWide / 2 - 220 * scale, to: rep.pixelsWide / 2 + 220 * scale, by: 4) {
                if let color = rep.colorAt(x: x, y: y),
                   color.alphaComponent > 0.5,
                   color.brightnessComponent > 0.8 {
                    return true
                }
            }
        }
        return false
    }

    @Test("Baseline: with nothing else on screen, the banner is drawn")
    func bannerDrawsAtAll() {
        let rep = render { _ in }
        #expect(bannerCentreAlpha(rep) > 0.5)
        #expect(bannerHasBrightText(rep))
    }

    @Test("A window highlight covering the whole display does not erase the banner")
    func fullScreenWindowHighlight() {
        // The regression. Hovering a full-screen window lifted the dim layer with a `.copy` fill
        // across the entire view — banner included, which dropped its pixels to 12% black.
        let rep = render { view in
            view.highlightedWindow = CGRect(origin: .zero, size: size)
            view.highlightedWindowPixelSize = CGSize(width: 1800, height: 1120)
        }
        #expect(bannerCentreAlpha(rep) > 0.5, "the banner must be repainted over the highlight")
        #expect(bannerHasBrightText(rep), "the banner text must still be legible")
    }

    @Test("A window highlight that crosses only the banner region still loses to the banner")
    func partialHighlightThroughBanner() {
        let rep = render { view in
            // A window occupying the top third of the screen, straight through the banner.
            view.highlightedWindow = CGRect(x: 0, y: size.height * 0.66, width: size.width, height: size.height * 0.34)
            view.highlightedWindowPixelSize = CGSize(width: 900, height: 190)
        }
        #expect(bannerCentreAlpha(rep) > 0.5)
        #expect(bannerHasBrightText(rep))
    }

    @Test("A manual selection dragged through the banner does not punch it out")
    func selectionThroughBanner() {
        // The selection punch-out uses `.copy` with clear — alpha 0 — so before the fix the
        // banner became a fully transparent hole.
        let rep = render { view in
            view.globalSelection = CGRect(x: 200, y: size.height - 200, width: 500, height: 200)
            view.selectionPixelSize = CGSize(width: 1000, height: 400)
        }
        #expect(bannerCentreAlpha(rep) > 0.5)
        #expect(bannerHasBrightText(rep))
    }

    @Test("A full-screen selection keeps the banner visible")
    func fullScreenSelection() {
        let rep = render { view in
            view.globalSelection = CGRect(origin: .zero, size: size)
            view.selectionPixelSize = CGSize(width: 1800, height: 1120)
        }
        #expect(bannerCentreAlpha(rep) > 0.5)
        #expect(bannerHasBrightText(rep))
    }

    @Test("A selection flush against the top edge keeps the banner visible")
    func topEdgeSelection() {
        let rep = render { view in
            view.globalSelection = CGRect(x: 0, y: size.height - 120, width: size.width, height: 120)
            view.selectionPixelSize = CGSize(width: 1800, height: 240)
        }
        #expect(bannerCentreAlpha(rep) > 0.5)
        #expect(bannerHasBrightText(rep))
    }

    @Test("The same holds at Retina scale")
    func retinaScale() {
        let rep = render({ view in
            view.highlightedWindow = CGRect(origin: .zero, size: size)
            view.highlightedWindowPixelSize = CGSize(width: 1800, height: 1120)
        }, scale: 2)
        #expect(rep.pixelsWide == Int(size.width) * 2)
        #expect(bannerCentreAlpha(rep, scale: 2) > 0.5)
        #expect(bannerHasBrightText(rep, scale: 2))
    }

    @Test("Recording mode is unaffected: red-accent banner also survives a full overlap")
    func recordingModeBanner() {
        let rep = render { view in
            view.mode = .recording
            view.globalSelection = CGRect(origin: .zero, size: size)
            view.selectionPixelSize = CGSize(width: 1800, height: 1120)
        }
        #expect(bannerCentreAlpha(rep) > 0.5)
        #expect(bannerHasBrightText(rep))
    }

    @Test("The selection punch-out still works: interior stays transparent below the banner")
    func punchOutStillPunches() {
        // Repainting the banner last must not accidentally restore the dim layer inside the
        // selection. Sample the selection's centre, well away from the banner.
        let rep = render { view in
            view.globalSelection = CGRect(x: 200, y: 100, width: 500, height: 250)
            view.selectionPixelSize = CGSize(width: 1000, height: 500)
        }
        // View y ∈ [100, 350] → bitmap rows [560-350, 560-100] = [210, 460]. Sample the middle.
        let inside = rep.colorAt(x: 450, y: 335)?.alphaComponent ?? 1
        #expect(inside < 0.05, "the selection interior must stay punched out (got alpha \(inside))")
        // And the dim layer outside the selection is intact.
        let outside = rep.colorAt(x: 60, y: 335)?.alphaComponent ?? 0
        #expect(outside > 0.3)
    }

    @Test("The window-highlight lift still lifts: highlighted area is lighter than the dim layer")
    func highlightStillLifts() {
        let rep = render { view in
            view.highlightedWindow = CGRect(x: 200, y: 100, width: 500, height: 250)
            view.highlightedWindowPixelSize = CGSize(width: 1000, height: 500)
        }
        let inside = rep.colorAt(x: 450, y: 335)?.alphaComponent ?? 1
        let outside = rep.colorAt(x: 60, y: 335)?.alphaComponent ?? 0
        #expect(inside < outside, "the highlighted window must stay lifted out of the dim layer")
    }
}
