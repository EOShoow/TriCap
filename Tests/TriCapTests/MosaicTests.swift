import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import AnnotationCore
@testable import TriCapKit

/// The mosaic must pixelate **the pixels it covers**. The hand-written implementation cropped its
/// sample band through a double flip — `CGImage.cropping(to:)` already works in row space, where
/// an annotation-space rect needs no conversion — so it sampled the *vertically mirrored* band.
/// On a mostly-light page that painted large white blocks bearing no relation to the covered
/// content, which is exactly what the user reported. `scripts/diagnostics/mosaic-mirror-probe.swift`
/// reproduces it standalone.
@Suite("Mosaic")
struct MosaicTests {

    // MARK: - Fixtures

    /// Top half red, bottom half blue, in annotation space (top-left origin).
    private func redOverBlue(width: Int = 80, height: Int = 80) -> CGImage {
        let ctx = ImageProcessing.makeContext(width: width, height: height)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: CGFloat(height) / 2, width: CGFloat(width), height: CGFloat(height) / 2))
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height) / 2))
        return ctx.makeImage()!
    }

    /// A horizontal sRGB gradient, so every column has a distinct colour.
    private func gradient(width: Int = 128, height: Int = 96) -> CGImage {
        let ctx = ImageProcessing.makeContext(width: width, height: height)!
        for x in 0..<width {
            ctx.setFillColor(CGColor(
                srgbRed: CGFloat(x) / CGFloat(width), green: 0.35, blue: 1 - CGFloat(x) / CGFloat(width), alpha: 1
            ))
            ctx.fill(CGRect(x: CGFloat(x), y: 0, width: 1, height: CGFloat(height)))
        }
        return ctx.makeImage()!
    }

    private func mosaic(_ rect: CGRect, block: CGFloat = 14) -> AnnotationItem {
        AnnotationItem(shape: .mosaic(rect), style: AnnotationStyle(mosaicBlockSize: block))
    }

    private func pixels(_ image: CGImage) -> (data: Data, bytesPerRow: Int) {
        (image.dataProvider!.data! as Data, image.bytesPerRow)
    }

    private func rgb(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
        let (data, bpr) = pixels(image)
        let offset = y * bpr + x * 4
        return (Int(data[offset]), Int(data[offset + 1]), Int(data[offset + 2]))
    }

    // MARK: - The regression

    @Test("The mosaic samples the band it covers, not the mirrored one")
    func samplesTheCoveredBand() throws {
        // Mosaic over the TOP (red) band. The old code produced pure blue here.
        let base = redOverBlue()
        let out = try #require(AnnotationRenderer.render(
            items: [mosaic(CGRect(x: 0, y: 0, width: 80, height: 40), block: 16)], onto: base
        ))
        let sample = rgb(out, x: 40, y: 10)
        #expect(sample.r > 200 && sample.b < 60,
                "the mosaic'd top band must stay red, got \(sample)")
        // The untouched bottom band stays blue.
        let untouched = rgb(out, x: 40, y: 70)
        #expect(untouched.b > 200 && untouched.r < 60)
    }

    @Test("A dark region does not turn into white blocks sourced from elsewhere")
    func noForeignWhiteBlocks() throws {
        // The reported symptom: mosaic over dark content near one edge, bright content at the
        // mirrored position. The mosaic must not import the bright pixels.
        let ctx = ImageProcessing.makeContext(width: 100, height: 100)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))      // white page
        ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        ctx.setFillColor(CGColor(srgbRed: 0.10, green: 0.12, blue: 0.15, alpha: 1))  // dark strip on top
        ctx.fill(CGRect(x: 0, y: 80, width: 100, height: 20))                   // context space: top
        let base = ctx.makeImage()!

        let out = try #require(AnnotationRenderer.render(
            items: [mosaic(CGRect(x: 10, y: 2, width: 80, height: 16), block: 8)], onto: base
        ))
        let sample = rgb(out, x: 50, y: 10)
        #expect(sample.r < 100, "the mosaic over the dark strip must stay dark, got \(sample)")
    }

    // MARK: - Boundaries

    @Test("Pixels outside the mosaic rect are untouched")
    func outsideUntouched() throws {
        let base = gradient()
        let rect = CGRect(x: 32, y: 24, width: 48, height: 40)
        let out = try #require(AnnotationRenderer.render(items: [mosaic(rect)], onto: base))

        for (x, y) in [(10, 10), (120, 90), (10, 90), (120, 10), (31, 44), (81, 44), (56, 22), (56, 65)] {
            let before = rgb(base, x: x, y: y)
            let after = rgb(out, x: x, y: y)
            #expect(before == after, "pixel (\(x),\(y)) changed from \(before) to \(after)")
        }
    }

    @Test("A rect hanging off each edge clips cleanly", arguments: [
        CGRect(x: -20, y: 30, width: 60, height: 30),    // off the left
        CGRect(x: 100, y: 30, width: 60, height: 30),    // off the right
        CGRect(x: 40, y: -15, width: 50, height: 30),    // off the top
        CGRect(x: 40, y: 80, width: 50, height: 30),     // off the bottom
        CGRect(x: -30, y: -30, width: 300, height: 300), // swallows the whole canvas
    ])
    func clipsAtEdges(rect: CGRect) throws {
        let base = gradient()
        let out = try #require(AnnotationRenderer.render(items: [mosaic(rect, block: 10)], onto: base))
        #expect(out.width == base.width && out.height == base.height)

        // A pixel far from the rect is untouched (skip for the canvas-swallowing case).
        let clamped = rect.intersection(CGRect(x: 0, y: 0, width: 128, height: 96))
        if !clamped.contains(CGPoint(x: 5, y: 5)) {
            #expect(rgb(out, x: 5, y: 5) == rgb(base, x: 5, y: 5))
        }
        // Alpha stays opaque everywhere — no transparent holes at the clipped edges.
        let (data, bpr) = pixels(out)
        for y in stride(from: 0, to: 96, by: 7) {
            for x in stride(from: 0, to: 128, by: 7) {
                #expect(data[y * bpr + x * 4 + 3] == 255, "hole at (\(x),\(y))")
            }
        }
    }

    @Test("Degenerate and tiny rects do not crash and still cover", arguments: [
        CGRect(x: 10, y: 10, width: 0, height: 0),
        CGRect(x: 10, y: 10, width: 1, height: 1),
        CGRect(x: 10, y: 10, width: 3, height: 3),
        CGRect(x: 10.3, y: 20.7, width: 55.5, height: 40.2),   // fractional, Retina-style coords
    ])
    func degenerateRects(rect: CGRect) throws {
        let base = gradient()
        let out = try #require(AnnotationRenderer.render(items: [mosaic(rect, block: 18)], onto: base))
        #expect(out.width == base.width)
        // Far corner untouched in every case.
        #expect(rgb(out, x: 126, y: 94) == rgb(base, x: 126, y: 94))
    }

    // MARK: - Block size and grid

    @Test("A larger block size produces fewer distinct colours")
    func blockSizeMatters() throws {
        let base = gradient()
        let rect = CGRect(x: 0, y: 0, width: 128, height: 96)

        func distinctColours(block: CGFloat) throws -> Int {
            let out = try #require(AnnotationRenderer.render(items: [mosaic(rect, block: block)], onto: base))
            var seen = Set<Int>()
            for x in stride(from: 2, to: 128, by: 1) {
                let c = rgb(out, x: x, y: 48)
                seen.insert(c.r << 16 | c.g << 8 | c.b)
            }
            return seen.count
        }

        let fine = try distinctColours(block: 4)
        let coarse = try distinctColours(block: 32)
        #expect(coarse < fine, "block 32 (\(coarse) colours) must be coarser than block 4 (\(fine))")
        #expect(coarse <= 6, "128 px at block 32 is at most 4 whole blocks + 2 edge blocks")
    }

    @Test("The pixel grid is anchored to the canvas, not the rect")
    func gridIsCanvasAnchored() throws {
        // Two renders of the same canvas: the mosaic rect moves, the grid must not. Sample the
        // region both rects cover — the pixelated colours there must be identical, because the
        // block boundaries are fixed to the canvas.
        let base = gradient()
        let block: CGFloat = 16
        let wide = try #require(AnnotationRenderer.render(
            items: [mosaic(CGRect(x: 0, y: 0, width: 128, height: 96), block: block)], onto: base
        ))
        let shifted = try #require(AnnotationRenderer.render(
            items: [mosaic(CGRect(x: 24, y: 8, width: 104, height: 88), block: block)], onto: base
        ))

        // Compare well inside both rects, away from either rect's edges.
        for y in stride(from: 32, to: 80, by: 5) {
            for x in stride(from: 48, to: 112, by: 5) {
                let a = rgb(wide, x: x, y: y)
                let b = rgb(shifted, x: x, y: y)
                #expect(a == b, "grid drifted at (\(x),\(y)): \(a) vs \(b)")
            }
        }
    }

    // MARK: - Ordering and compositing

    @Test("The mosaic hides annotations drawn before it")
    func hidesEarlierAnnotations() throws {
        let base = gradient()
        let secret = AnnotationItem(
            shape: .rectangle(CGRect(x: 40, y: 30, width: 40, height: 30)),
            style: AnnotationStyle(color: .green, filled: true)
        )
        let out = try #require(AnnotationRenderer.render(
            items: [secret, mosaic(CGRect(x: 20, y: 15, width: 90, height: 70), block: 24)], onto: base
        ))
        // The pure green fill must no longer exist at full strength anywhere in the mosaic'd area:
        // every block is a single sample, and sampling grid points rarely coincide exactly —
        // check the fill's crisp EDGES are gone by verifying neighbouring blocks differ from pure
        // green somewhere along the old boundary.
        var pureGreenRun = 0
        for x in 40..<80 {
            let c = rgb(out, x: x, y: 30)
            if c == rgb(base, x: 0, y: 0) { continue }
            let isPureGreen = c.g > 200 && c.r < 60 && c.b < 60
            pureGreenRun = isPureGreen ? pureGreenRun + 1 : 0
        }
        #expect(pureGreenRun < 40, "the filled rectangle survived the mosaic intact")
    }

    @Test("Annotations drawn after the mosaic stay crisp on top")
    func laterAnnotationsStayOnTop() throws {
        let base = gradient()
        let out = try #require(AnnotationRenderer.render(
            items: [
                mosaic(CGRect(x: 0, y: 0, width: 128, height: 96), block: 20),
                AnnotationItem(
                    shape: .rectangle(CGRect(x: 30, y: 30, width: 60, height: 40)),
                    style: AnnotationStyle(color: .red, filled: true)
                ),
            ], onto: base
        ))
        let inside = rgb(out, x: 60, y: 50)
        #expect(inside.r > 200 && inside.g < 80, "the later rectangle must be fully visible, got \(inside)")
    }

    // MARK: - Colour handling

    @Test("A Display P3 base renders through the same path without artefacts")
    func p3Input() throws {
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        let ctx = CGContext(
            data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
            space: p3, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        ctx.setFillColor(CGColor(colorSpace: p3, components: [1, 0.2, 0.1, 1])!)
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let base = ctx.makeImage()!

        let out = try #require(AnnotationRenderer.render(
            items: [mosaic(CGRect(x: 8, y: 8, width: 48, height: 48), block: 12)], onto: base
        ))
        #expect(out.colorSpace?.name == CGColorSpace.sRGB)
        let sample = rgb(out, x: 32, y: 32)
        #expect(sample.r > 180 && sample.b < 120, "a red-ish P3 base must stay red-ish, got \(sample)")
    }

    @Test("Output is fully opaque even for a transparent base")
    func alphaFlattened() throws {
        let ctx = CGContext(
            data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(srgbRed: 0.3, green: 0.6, blue: 0.9, alpha: 0.4))
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let base = ctx.makeImage()!

        let out = try #require(AnnotationRenderer.render(
            items: [mosaic(CGRect(x: 0, y: 0, width: 64, height: 64), block: 8)], onto: base
        ))
        let (data, bpr) = pixels(out)
        for y in stride(from: 0, to: 64, by: 5) {
            for x in stride(from: 0, to: 64, by: 5) {
                #expect(data[y * bpr + x * 4 + 3] == 255)
            }
        }
    }

    // MARK: - Determinism and concurrency

    @Test("Rendering is deterministic: the still and every animation frame get identical pixels")
    func deterministicAcrossCalls() throws {
        // The animated export composites the same item list per frame through this exact
        // function, so two calls returning different bytes would make frames shimmer.
        let base = gradient()
        let items = [mosaic(CGRect(x: 20, y: 10, width: 90, height: 70), block: 14)]
        let first = try #require(AnnotationRenderer.render(items: items, onto: base))
        let second = try #require(AnnotationRenderer.render(items: items, onto: base))
        #expect(pixels(first).data == pixels(second).data)
    }

    @Test("Concurrent renders are safe and agree with the serial result")
    func concurrentRenders() async throws {
        // Animated-frame compositing runs off the main thread while a still export can run on it;
        // the shared CIContext must survive that. CIContext is documented thread-safe — this
        // pins the assumption.
        let base = gradient()
        let items = [mosaic(CGRect(x: 20, y: 10, width: 90, height: 70), block: 14)]
        let reference = pixels(try #require(AnnotationRenderer.render(items: items, onto: base))).data

        try await withThrowingTaskGroup(of: Data.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    let out = AnnotationRenderer.render(items: items, onto: base)
                    guard let out else { throw TriCapError.encodingFailed("render returned nil") }
                    return (out.dataProvider!.data! as Data)
                }
            }
            for try await result in group {
                #expect(result == reference)
            }
        }
    }
}
