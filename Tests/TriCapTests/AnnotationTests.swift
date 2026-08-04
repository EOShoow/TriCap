import CoreGraphics
import Foundation
import Testing
@testable import AnnotationCore
@testable import TriCapKit

private func rectItem(_ rect: CGRect = CGRect(x: 10, y: 10, width: 50, height: 40)) -> AnnotationItem {
    AnnotationItem(shape: .rectangle(rect))
}

@Suite("Annotation document")
struct AnnotationDocumentTests {

    @Test("A new document is empty and has no history")
    func emptyDocument() {
        let doc = AnnotationDocument()
        #expect(doc.isEmpty)
        #expect(!doc.canUndo)
        #expect(!doc.canRedo)
    }

    // `#expect` wraps its argument in an autoclosure, so a mutating call cannot appear inside it;
    // every mutation below is performed first and its result checked afterwards.

    @Test("Adding an item enables undo but not redo")
    func addEnablesUndo() {
        var doc = AnnotationDocument()
        let added = doc.add(rectItem())
        #expect(added)
        #expect(doc.items.count == 1)
        #expect(doc.canUndo)
        #expect(!doc.canRedo)
    }

    @Test("Undo restores the previous state and enables redo")
    func undoRedoRoundTrip() {
        var doc = AnnotationDocument()
        let a = rectItem(CGRect(x: 0, y: 0, width: 10, height: 10))
        let b = rectItem(CGRect(x: 20, y: 20, width: 10, height: 10))
        doc.add(a)
        doc.add(b)

        let undone = doc.undo()
        #expect(undone)
        #expect(doc.items == [a])
        #expect(doc.canRedo)

        let redone = doc.redo()
        #expect(redone)
        #expect(doc.items == [a, b])
        #expect(!doc.canRedo)
    }

    @Test("Undoing all the way back reaches the empty document")
    func undoToEmpty() {
        var doc = AnnotationDocument()
        doc.add(rectItem())
        doc.add(rectItem(CGRect(x: 100, y: 100, width: 20, height: 20)))
        let first = doc.undo()
        let second = doc.undo()
        let third = doc.undo()
        #expect(first)
        #expect(second)
        #expect(third == false)
        #expect(doc.items.isEmpty)
        #expect(!doc.canUndo)
    }

    @Test("A new edit after undo discards the redo branch")
    func newEditClearsRedo() {
        var doc = AnnotationDocument()
        doc.add(rectItem())
        doc.add(rectItem(CGRect(x: 50, y: 50, width: 10, height: 10)))
        let undone = doc.undo()
        #expect(undone)
        #expect(doc.canRedo)

        doc.add(rectItem(CGRect(x: 80, y: 80, width: 10, height: 10)))
        #expect(!doc.canRedo)
        #expect(doc.items.count == 2)
    }

    @Test("Redo without a prior undo is a no-op")
    func redoWithoutUndo() {
        var doc = AnnotationDocument()
        doc.add(rectItem())
        let redone = doc.redo()
        #expect(redone == false)
    }

    @Test("Degenerate shapes are rejected and do not consume an undo step")
    func rejectsDegenerateShapes() {
        var doc = AnnotationDocument()
        let tinyRect = doc.add(AnnotationItem(shape: .rectangle(CGRect(x: 5, y: 5, width: 1, height: 1))))
        let blankText = doc.add(AnnotationItem(shape: .text(origin: .zero, string: "   ")))
        let onePoint = doc.add(AnnotationItem(shape: .freehand(points: [.zero])))
        let shortArrow = doc.add(AnnotationItem(shape: .arrow(from: .zero, to: CGPoint(x: 1, y: 0))))
        #expect(tinyRect == false)
        #expect(blankText == false)
        #expect(onePoint == false)
        #expect(shortArrow == false)
        #expect(doc.isEmpty)
        #expect(!doc.canUndo)
    }

    @Test("Removing by id is undoable")
    func removeIsUndoable() {
        var doc = AnnotationDocument()
        let item = rectItem()
        doc.add(item)
        let removed = doc.remove(id: item.id)
        #expect(removed)
        #expect(doc.isEmpty)
        let undone = doc.undo()
        #expect(undone)
        #expect(doc.items == [item])
    }

    @Test("Removing an unknown id changes nothing")
    func removeUnknownId() {
        var doc = AnnotationDocument()
        doc.add(rectItem())
        let before = doc
        let removed = doc.remove(id: UUID())
        #expect(removed == false)
        #expect(doc == before)
    }

    @Test("Updating an item replaces it in place and is undoable")
    func updateIsUndoable() {
        var doc = AnnotationDocument()
        var item = AnnotationItem(shape: .text(origin: .zero, string: "before"))
        doc.add(item)
        item.shape = .text(origin: .zero, string: "after")
        let updated = doc.update(item)
        #expect(updated)
        #expect(doc.items[0].shape == .text(origin: .zero, string: "after"))
        let undone = doc.undo()
        #expect(undone)
        #expect(doc.items[0].shape == .text(origin: .zero, string: "before"))
    }

    @Test("Updating a text item to an empty string removes it")
    func updateToEmptyTextRemoves() {
        var doc = AnnotationDocument()
        var item = AnnotationItem(shape: .text(origin: .zero, string: "hello"))
        doc.add(item)
        item.shape = .text(origin: .zero, string: "")
        let updated = doc.update(item)
        #expect(updated)
        #expect(doc.isEmpty)
    }

    @Test("Updating with identical content is a no-op that does not pollute the undo stack")
    func updateNoOp() {
        var doc = AnnotationDocument()
        let item = rectItem()
        doc.add(item)
        let depth = doc.undoDepth
        let updated = doc.update(item)
        #expect(updated == false)
        #expect(doc.undoDepth == depth)
    }

    @Test("Clear removes everything in one undoable step")
    func clearIsOneStep() {
        var doc = AnnotationDocument()
        doc.add(rectItem())
        doc.add(rectItem(CGRect(x: 200, y: 200, width: 30, height: 30)))
        let cleared = doc.clear()
        #expect(cleared)
        #expect(doc.isEmpty)
        let undone = doc.undo()
        #expect(undone)
        #expect(doc.items.count == 2)
    }

    @Test("The undo history is bounded")
    func historyIsBounded() {
        var doc = AnnotationDocument(historyLimit: 5)
        for i in 0..<20 {
            doc.add(rectItem(CGRect(x: CGFloat(i) * 10, y: 0, width: 20, height: 20)))
        }
        #expect(doc.undoDepth == 5)

        var undone = 0
        while doc.undo() { undone += 1 }
        #expect(undone == 5)
        // The oldest 15 edits fell out of history, so their items are still present.
        #expect(doc.items.count == 15)
    }

    @Test("The model round-trips through Codable")
    func codableRoundTrip() throws {
        let items = [
            AnnotationItem(shape: .arrow(from: .zero, to: CGPoint(x: 100, y: 80))),
            AnnotationItem(shape: .rectangle(CGRect(x: 1, y: 2, width: 30, height: 40))),
            AnnotationItem(shape: .text(origin: CGPoint(x: 5, y: 6), string: "hello 世界")),
            AnnotationItem(shape: .freehand(points: [.zero, CGPoint(x: 3, y: 4)])),
            AnnotationItem(shape: .mosaic(CGRect(x: 0, y: 0, width: 20, height: 20))),
        ]
        let data = try JSONEncoder().encode(items)
        let decoded = try JSONDecoder().decode([AnnotationItem].self, from: data)
        #expect(decoded == items)
    }
}

@Suite("Annotation rendering")
struct AnnotationRendererTests {

    /// Solid white 200x100 canvas.
    static func baseImage(width: Int = 200, height: Int = 100) -> CGImage {
        let ctx = ImageProcessing.makeContext(width: width, height: height)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    static func pixel(_ image: CGImage, x: Int, y: Int) -> (UInt8, UInt8, UInt8) {
        let raster = ImageProcessing.rgbxBytes(image)!
        let offset = y * raster.stride + x * 4
        return (raster.bytes[offset], raster.bytes[offset + 1], raster.bytes[offset + 2])
    }

    @Test("Rendering with no annotations preserves the base image size")
    func emptyRenderKeepsSize() throws {
        let base = Self.baseImage()
        let out = try #require(AnnotationRenderer.render(items: [], onto: base))
        #expect(out.width == base.width)
        #expect(out.height == base.height)
    }

    @Test("A filled rectangle lands in annotation coordinates (top-left origin, +y down)")
    func filledRectangleUsesTopLeftOrigin() throws {
        var style = AnnotationStyle(color: .red)
        style.filled = true
        // Top-left quadrant in annotation space.
        let item = AnnotationItem(shape: .rectangle(CGRect(x: 0, y: 0, width: 100, height: 50)), style: style)
        let out = try #require(AnnotationRenderer.render(items: [item], onto: Self.baseImage()))

        // (10, 10) is inside the rect in annotation space and must be red.
        let inside = Self.pixel(out, x: 10, y: 10)
        #expect(inside.0 > 200 && inside.1 < 100 && inside.2 < 100)

        // (10, 90) is below the rect and must still be white — this is the assertion that
        // would fail if the renderer's y-flip were wrong.
        let outside = Self.pixel(out, x: 10, y: 90)
        #expect(outside == (255, 255, 255))
    }

    @Test("An arrow draws ink somewhere along its path")
    func arrowDrawsInk() throws {
        let item = AnnotationItem(
            shape: .arrow(from: CGPoint(x: 10, y: 50), to: CGPoint(x: 190, y: 50)),
            style: AnnotationStyle(color: .blue, lineWidth: 6)
        )
        let out = try #require(AnnotationRenderer.render(items: [item], onto: Self.baseImage()))
        let mid = Self.pixel(out, x: 100, y: 50)
        #expect(mid != (255, 255, 255))
    }

    @Test("Freehand strokes connect their points")
    func freehandDrawsInk() throws {
        let points = (0..<20).map { CGPoint(x: CGFloat($0) * 10, y: 20) }
        let item = AnnotationItem(shape: .freehand(points: points), style: AnnotationStyle(color: .green, lineWidth: 5))
        let out = try #require(AnnotationRenderer.render(items: [item], onto: Self.baseImage()))
        #expect(Self.pixel(out, x: 100, y: 20) != (255, 255, 255))
    }

    @Test("Mosaic averages the region it covers")
    func mosaicPixelates() throws {
        // Base with a hard black/white vertical split inside the mosaic area.
        let ctx = ImageProcessing.makeContext(width: 200, height: 100)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        // Thin vertical stripes, 2 px wide.
        for x in stride(from: 0, to: 100, by: 4) {
            ctx.fill(CGRect(x: x, y: 0, width: 2, height: 100))
        }
        let base = ctx.makeImage()!

        var style = AnnotationStyle()
        style.mosaicBlockSize = 20
        let item = AnnotationItem(shape: .mosaic(CGRect(x: 0, y: 0, width: 100, height: 100)), style: style)
        let out = try #require(AnnotationRenderer.render(items: [item], onto: base))

        // After pixelating 2-px stripes with 20-px blocks nothing stays pure black or pure white.
        let sample = Self.pixel(out, x: 50, y: 50)
        #expect(sample.0 > 40 && sample.0 < 220)
    }

    @Test("Mosaic redacts an annotation drawn underneath it, not just the base image")
    func mosaicCoversEarlierAnnotations() throws {
        // `CIPixellate` *samples* one point per block (the hand-written predecessor averaged the
        // block, which is what this test originally relied on). So the proof is arranged around
        // sampling: one 100-px block spans the whole canvas and its sample point lands inside the
        // black stripe — which is an *annotation*, not part of the white base. The mosaic'd area
        // over the white half can therefore only come out black if the filter saw the composited
        // canvas, annotations included.
        var filled = AnnotationStyle(color: .black)
        filled.filled = true
        let stripe = AnnotationItem(shape: .rectangle(CGRect(x: 0, y: 0, width: 60, height: 100)), style: filled)

        var mosaicStyle = AnnotationStyle()
        mosaicStyle.mosaicBlockSize = 100
        let mosaic = AnnotationItem(shape: .mosaic(CGRect(x: 60, y: 0, width: 40, height: 100)), style: mosaicStyle)

        let withoutMosaic = try #require(AnnotationRenderer.render(items: [stripe], onto: Self.baseImage()))
        #expect(Self.pixel(withoutMosaic, x: 35, y: 50) == (0, 0, 0))
        #expect(Self.pixel(withoutMosaic, x: 80, y: 50) == (255, 255, 255))

        let out = try #require(AnnotationRenderer.render(items: [stripe, mosaic], onto: Self.baseImage()))
        // Outside the mosaic rect the stripe is untouched.
        #expect(Self.pixel(out, x: 35, y: 50) == (0, 0, 0))
        // Inside it, the formerly white pixels take the block's sampled colour: the black stripe.
        #expect(Self.pixel(out, x: 80, y: 50) != (255, 255, 255))
    }

    @Test("Text renders visible glyphs")
    func textDrawsInk() throws {
        let item = AnnotationItem(
            shape: .text(origin: CGPoint(x: 10, y: 10), string: "TriCap"),
            style: AnnotationStyle(color: .black, fontSize: 40)
        )
        let out = try #require(AnnotationRenderer.render(items: [item], onto: Self.baseImage(width: 300, height: 100)))

        let raster = ImageProcessing.rgbxBytes(out)!
        var darkPixels = 0
        for y in 0..<out.height {
            for x in 0..<out.width where raster.bytes[y * raster.stride + x * 4] < 128 {
                darkPixels += 1
            }
        }
        #expect(darkPixels > 50)
    }

    @Test("The same annotation list renders identically onto every frame")
    func overlayIsStableAcrossFrames() throws {
        var style = AnnotationStyle(color: .red)
        style.filled = true
        let items = [AnnotationItem(shape: .rectangle(CGRect(x: 20, y: 20, width: 40, height: 30)), style: style)]

        // Two visually different frames.
        let frameA = Self.baseImage()
        let ctxB = ImageProcessing.makeContext(width: 200, height: 100)!
        ctxB.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1))
        ctxB.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        let frameB = ctxB.makeImage()!

        let outA = try #require(AnnotationRenderer.render(items: items, onto: frameA))
        let outB = try #require(AnnotationRenderer.render(items: items, onto: frameB))

        // The overlay pixels are identical even though the frames underneath differ.
        #expect(Self.pixel(outA, x: 30, y: 30) == Self.pixel(outB, x: 30, y: 30))
        #expect(Self.pixel(outA, x: 5, y: 5) != Self.pixel(outB, x: 5, y: 5))
    }
}
