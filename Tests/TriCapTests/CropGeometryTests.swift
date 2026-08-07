import CoreGraphics
import Foundation
import Testing
@testable import TriCapKit

/// Crop rects are canvas-pixel, integral, inside the canvas — and a "crop" of the whole canvas
/// is not a crop. These rules keep the exported cut byte-identical to the editor preview.
@Suite("Crop geometry")
struct CropGeometryTests {

    private let canvas = CGSize(width: 200, height: 100)

    @Test("A drag normalises regardless of corner order")
    func cornerOrder() {
        let a = CGPoint(x: 150, y: 80)
        let b = CGPoint(x: 50, y: 20)
        let forward = CropGeometry.cropRect(dragFrom: a, to: b, canvasSize: canvas)
        let backward = CropGeometry.cropRect(dragFrom: b, to: a, canvasSize: canvas)
        #expect(forward == CGRect(x: 50, y: 20, width: 100, height: 60))
        #expect(forward == backward)
    }

    @Test("Fractional drag points land on whole pixels")
    func integralRounding() {
        let rect = CropGeometry.cropRect(
            dragFrom: CGPoint(x: 10.4, y: 20.6), to: CGPoint(x: 90.5, y: 60.2), canvasSize: canvas
        )
        // Each *edge* rounds to the nearest pixel boundary: 10.4→10, 90.5→91, 20.6→21, 60.2→60.
        #expect(rect == CGRect(x: 10, y: 21, width: 81, height: 39))
        #expect(rect.map { CropGeometry.isValid($0, canvasSize: canvas) } == true)
    }

    @Test("A drag beyond the canvas is clamped to it")
    func clampsToCanvas() {
        let rect = CropGeometry.cropRect(
            dragFrom: CGPoint(x: -40, y: -10), to: CGPoint(x: 500, y: 50), canvasSize: canvas
        )
        #expect(rect == CGRect(x: 0, y: 0, width: 200, height: 50))
    }

    @Test("A slip of the mouse is not a crop")
    func minimumEdge() {
        #expect(CropGeometry.cropRect(
            dragFrom: CGPoint(x: 10, y: 10), to: CGPoint(x: 14, y: 80), canvasSize: canvas
        ) == nil, "narrower than the minimum edge")
        #expect(CropGeometry.cropRect(
            dragFrom: CGPoint(x: 10, y: 10), to: CGPoint(x: 10, y: 10), canvasSize: canvas
        ) == nil, "a click is not a crop")
    }

    @Test("A drag entirely outside the canvas is nothing")
    func outsideCanvas() {
        #expect(CropGeometry.cropRect(
            dragFrom: CGPoint(x: 300, y: 200), to: CGPoint(x: 400, y: 300), canvasSize: canvas
        ) == nil)
    }

    @Test("Selecting the whole canvas clears the crop instead of storing a no-op")
    func fullCanvasIsNoCrop() {
        let full = CGRect(origin: .zero, size: canvas)
        #expect(CropGeometry.effectiveCrop(full, canvasSize: canvas) == nil)
        #expect(CropGeometry.effectiveCrop(nil, canvasSize: canvas) == nil)
        let partial = CGRect(x: 10, y: 10, width: 50, height: 40)
        #expect(CropGeometry.effectiveCrop(partial, canvasSize: canvas) == partial)
    }

    @Test("Validity: integral, non-empty, inside the canvas")
    func validity() {
        #expect(CropGeometry.isValid(CGRect(x: 0, y: 0, width: 200, height: 100), canvasSize: canvas))
        #expect(CropGeometry.isValid(CGRect(x: 10, y: 10, width: 1, height: 1), canvasSize: canvas))
        #expect(!CropGeometry.isValid(CGRect(x: 0.5, y: 0, width: 10, height: 10), canvasSize: canvas),
                "fractional origin")
        #expect(!CropGeometry.isValid(CGRect(x: 0, y: 0, width: 10.25, height: 10), canvasSize: canvas),
                "fractional width")
        #expect(!CropGeometry.isValid(CGRect(x: 190, y: 0, width: 20, height: 10), canvasSize: canvas),
                "spills past the right edge")
        #expect(!CropGeometry.isValid(CGRect(x: 0, y: 0, width: 0, height: 10), canvasSize: canvas),
                "empty")
    }
}
