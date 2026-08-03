import CoreGraphics
import Foundation
import Testing
@testable import TriCapKit

/// The recording HUD is the only way to stop a recording with a click. If it lands off screen the
/// user is stuck until the duration limit runs out, so "is it fully on screen" is the property
/// every one of these asserts.
///
/// The scenarios come from `scripts/diagnostics/hud-placement-probe.swift`, which ran the previous
/// algorithm over the same shapes and put 8 of 12 outside the visible frame.
@Suite("HUD placement")
struct HUDPlacementTests {

    let hud = CGSize(width: 300, height: 74)
    let countdown = CGSize(width: 180, height: 176)

    /// A 1470×956 display with a 43 pt menu bar and a Dock — this machine's built-in screen.
    let visible = CGRect(x: 0, y: 43, width: 1470, height: 880)
    let bounds = CGRect(x: 0, y: 0, width: 1470, height: 956)

    /// A second display above and to the left, so every coordinate is negative.
    let secondaryVisible = CGRect(x: -1280, y: 156, width: 1280, height: 762)
    let secondaryBounds = CGRect(x: -1280, y: 156, width: 1280, height: 800)

    // MARK: - The regressions

    @Test("A full-screen selection still gets a visible HUD")
    func fullScreen() {
        // The old code put this at y = 968 on a screen whose visible frame ends at 923.
        let placement = HUDPlacement.place(size: hud, over: bounds, in: visible)
        #expect(HUDPlacement.isFullyVisible(placement.frame, in: visible))
        #expect(placement.strategy != .below, "there is no room below a full-screen selection")
    }

    @Test("Selections that fill most of the display keep the HUD on screen", arguments: [
        0.90, 0.92, 0.95, 0.98, 1.0,
    ])
    func tallSelections(fraction: Double) {
        let height = bounds.height * fraction
        let region = CGRect(
            x: bounds.minX,
            y: bounds.midY - height / 2,
            width: bounds.width,
            height: height
        )
        let placement = HUDPlacement.place(size: hud, over: region, in: visible)
        #expect(
            HUDPlacement.isFullyVisible(placement.frame, in: visible),
            "\(Int(fraction * 100))% tall → \(placement.frame) outside \(visible)"
        )
    }

    @Test("A tall selection flush with the bottom of the display")
    func flushToBottom() {
        // No room below at all; the old fallback went above and overshot the top by 23 pt.
        let region = CGRect(x: 0, y: 0, width: 1470, height: bounds.height * 0.90)
        let placement = HUDPlacement.place(size: hud, over: region, in: visible)
        #expect(HUDPlacement.isFullyVisible(placement.frame, in: visible))
    }

    @Test("A tall selection flush with the top of the display")
    func flushToTop() {
        // The old code chose "below" and landed 33 pt under the visible frame.
        let region = CGRect(x: 0, y: bounds.maxY - bounds.height * 0.90,
                            width: 1470, height: bounds.height * 0.90)
        let placement = HUDPlacement.place(size: hud, over: region, in: visible)
        #expect(HUDPlacement.isFullyVisible(placement.frame, in: visible))
    }

    @Test("A full-screen selection on a negative-coordinate display stays on that display")
    func secondaryDisplay() {
        let placement = HUDPlacement.place(size: hud, over: secondaryBounds, in: secondaryVisible)
        #expect(HUDPlacement.isFullyVisible(placement.frame, in: secondaryVisible))
        #expect(placement.frame.maxX <= 0, "must not drift onto the primary display")
    }

    @Test("A small selection in the top-left corner keeps the countdown clear of the menu bar")
    func countdownNearTheMenuBar() {
        // The countdown was centred with no clamping at all: this put it 17 pt under the menu bar.
        let region = CGRect(x: 4, y: bounds.maxY - 204, width: 300, height: 200)
        let placement = HUDPlacement.placeCentred(size: countdown, over: region, in: visible)
        #expect(HUDPlacement.isFullyVisible(placement.frame, in: visible))
        #expect(placement.strategy == .clamped)
    }

    // MARK: - The ordinary cases still behave

    @Test("A small selection in the middle puts the HUD just below it")
    func prefersBelow() {
        let region = CGRect(x: 500, y: 400, width: 400, height: 300)
        let placement = HUDPlacement.place(size: hud, over: region, in: visible)
        #expect(placement.strategy == .below)
        #expect(placement.frame.maxY == region.minY - HUDPlacement.gap)
        #expect(placement.frame.midX == region.midX)
        #expect(HUDPlacement.isFullyVisible(placement.frame, in: visible))
    }

    @Test("With no room below, the HUD goes above")
    func fallsBackToAbove() {
        let region = CGRect(x: 500, y: visible.minY, width: 400, height: 300)
        let placement = HUDPlacement.place(size: hud, over: region, in: visible)
        #expect(placement.strategy == .above)
        #expect(placement.frame.minY == region.maxY + HUDPlacement.gap)
        #expect(HUDPlacement.isFullyVisible(placement.frame, in: visible))
    }

    @Test("With no room outside, the HUD moves inside the selection")
    func fallsBackToInside() {
        // Tall enough to leave nothing above or below, short enough that inside works.
        let region = CGRect(x: 100, y: visible.minY, width: 1200, height: visible.height)
        let placement = HUDPlacement.place(size: hud, over: region, in: visible)
        #expect(placement.strategy == .insideBottom)
        #expect(HUDPlacement.isFullyVisible(placement.frame, in: visible))
        #expect(region.intersects(placement.frame), "inside means overlapping the selection")
    }

    @Test("A selection at the far left does not push the HUD off the edge")
    func clampsHorizontallyAtTheLeft() {
        let region = CGRect(x: visible.minX, y: 400, width: 60, height: 200)
        let placement = HUDPlacement.place(size: hud, over: region, in: visible)
        #expect(placement.frame.minX >= visible.minX + HUDPlacement.edgeInset)
        #expect(HUDPlacement.isFullyVisible(placement.frame, in: visible))
    }

    @Test("A selection at the far right does not push the HUD off the edge")
    func clampsHorizontallyAtTheRight() {
        let region = CGRect(x: visible.maxX - 60, y: 400, width: 60, height: 200)
        let placement = HUDPlacement.place(size: hud, over: region, in: visible)
        #expect(placement.frame.maxX <= visible.maxX - HUDPlacement.edgeInset)
        #expect(HUDPlacement.isFullyVisible(placement.frame, in: visible))
    }

    // MARK: - Exhaustive sweep

    @Test("Every selection on every display shape keeps the HUD on screen")
    func exhaustiveSweep() {
        let displays: [(String, CGRect)] = [
            ("built-in", visible),
            ("secondary", secondaryVisible),
            ("small 1280×720", CGRect(x: 0, y: 38, width: 1280, height: 657)),
            ("very short", CGRect(x: 0, y: 0, width: 1440, height: 200)),
        ]

        var checked = 0
        for (name, screen) in displays {
            // A grid of selections: every corner, every edge, the middle, and sizes from tiny to
            // larger than the screen.
            for widthFraction in [0.05, 0.3, 0.6, 0.95, 1.2] {
                for heightFraction in [0.05, 0.3, 0.6, 0.95, 1.2] {
                    for anchor in ["bottom-left", "top-right", "centre"] {
                        let size = CGSize(
                            width: screen.width * widthFraction,
                            height: screen.height * heightFraction
                        )
                        let origin: CGPoint
                        switch anchor {
                        case "bottom-left": origin = CGPoint(x: screen.minX, y: screen.minY)
                        case "top-right":
                            origin = CGPoint(x: screen.maxX - size.width, y: screen.maxY - size.height)
                        default:
                            origin = CGPoint(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2)
                        }
                        let region = CGRect(origin: origin, size: size)
                        let placement = HUDPlacement.place(size: hud, over: region, in: screen)
                        checked += 1

                        // On a screen too small to hold the HUD with its margins there is nothing
                        // correct to do; everywhere else it must be fully visible.
                        let fits = screen.insetBy(dx: HUDPlacement.edgeInset, dy: HUDPlacement.edgeInset)
                        guard fits.width >= self.hud.width, fits.height >= self.hud.height else { continue }
                        #expect(
                            HUDPlacement.isFullyVisible(placement.frame, in: screen),
                            "\(name) \(anchor) \(region) → \(placement.frame) (\(placement.strategy))"
                        )
                    }
                }
            }
        }
        #expect(checked == 300, "4 displays × 5 widths × 5 heights × 3 anchors")
    }

    @Test("The countdown survives the same sweep")
    func countdownSweep() {
        for screen in [visible, secondaryVisible, CGRect(x: 0, y: 38, width: 1280, height: 657)] {
            for fraction in [0.05, 0.5, 1.0, 1.3] {
                let size = CGSize(width: screen.width * fraction, height: screen.height * fraction)
                for origin in [
                    CGPoint(x: screen.minX, y: screen.minY),
                    CGPoint(x: screen.maxX - size.width, y: screen.maxY - size.height),
                ] {
                    let region = CGRect(origin: origin, size: size)
                    let placement = HUDPlacement.placeCentred(size: countdown, over: region, in: screen)
                    #expect(
                        HUDPlacement.isFullyVisible(placement.frame, in: screen),
                        "\(region) → \(placement.frame)"
                    )
                }
            }
        }
    }

    @Test("A screen too small for the HUD produces a frame rather than nonsense")
    func absurdlySmallScreen() {
        let tiny = CGRect(x: 0, y: 0, width: 100, height: 40)
        let placement = HUDPlacement.place(size: hud, over: tiny, in: tiny)
        #expect(placement.strategy == .clamped)
        #expect(placement.frame.width == hud.width)
        #expect(placement.frame.midX == tiny.midX, "centred is the least-bad answer")
        #expect(!placement.frame.origin.x.isNaN)
        #expect(!placement.frame.origin.y.isNaN)
    }

    @Test("A zero-size region does not produce NaN")
    func degenerateRegion() {
        let placement = HUDPlacement.place(size: hud, over: .zero, in: visible)
        #expect(HUDPlacement.isFullyVisible(placement.frame, in: visible))
    }
}
