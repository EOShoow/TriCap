import CoreGraphics
import Foundation
import Testing
@testable import TriCapKit

// MARK: - Fixtures
//
// Every fixture here is synthesised in code. Nothing in this file loads a screenshot: the whole
// point of `PixelField` being a plain value type is that the detector's decisions can be argued
// about in numbers a reader can check, on content a reader can see the source of.

/// Grey with a deterministic dither, so "uniform" fixtures still exercise the noise tolerance
/// rather than testing against an unrealistically perfect field.
private func noise(_ x: Int, _ y: Int, amplitude: Float = 0) -> Float {
    guard amplitude > 0 else { return 0 }
    var h = UInt32(truncatingIfNeeded: x &* 73_856_093 ^ y &* 19_349_663)
    h ^= h >> 13
    h = h &* 1_274_126_177
    h ^= h >> 16
    return (Float(h % 2048) / 2047 - 0.5) * 2 * amplitude
}

private struct Panel {
    let rect: CGRect
    let level: Float
}

/// A field of flat `background` with flat panels painted on it, plus optional noise.
private func field(
    width: Int = 320,
    height: Int = 220,
    background: Float = 0.16,
    panels: [Panel],
    noiseAmplitude: Float = 0,
    decorate: ((Int, Int) -> Float?)? = nil
) -> PixelField {
    PixelField(width: width, height: height) { x, y in
        if let decorate, let value = decorate(x, y) {
            return (value, value, value)
        }
        var level = background
        for panel in panels where panel.rect.contains(CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)) {
            level = panel.level
        }
        let v = min(1, max(0, level + noise(x, y, amplitude: noiseAmplitude)))
        return (v, v, v)
    }
}

private let canvasRect = CGRect(x: 60, y: 40, width: 180, height: 130)

private func canvasField(
    background: Float = 0.16,
    canvas: Float = 0.97,
    noiseAmplitude: Float = 0
) -> PixelField {
    field(
        background: background,
        panels: [Panel(rect: canvasRect, level: canvas)],
        noiseAmplitude: noiseAmplitude
    )
}

/// The best candidate whose rect is within `tolerance` samples of `expected` on every side.
private func candidate(
    matching expected: CGRect,
    in candidates: [VisualRegionDetector.Candidate],
    tolerance: CGFloat = 1
) -> VisualRegionDetector.Candidate? {
    candidates.first { found in
        abs(found.rect.minX - expected.minX) <= tolerance
            && abs(found.rect.minY - expected.minY) <= tolerance
            && abs(found.rect.maxX - expected.maxX) <= tolerance
            && abs(found.rect.maxY - expected.maxY) <= tolerance
    }
}

private func describe(_ candidates: [VisualRegionDetector.Candidate]) -> String {
    guard !candidates.isEmpty else { return "no candidates" }
    return candidates
        .map { String(format: "%@ conf=%.3f support=%.2f contrast=%.3f", "\($0.rect)", $0.confidence, $0.edgeSupport, $0.contrast) }
        .joined(separator: "\n")
}

/// `#expect` takes a `Comment`, which is string-literal only. A failing detector test is useless
/// without the numbers it actually produced, so every diagnostic here goes through this.
private func note(_ message: String) -> Comment { Comment(rawValue: message) }

// MARK: - The case this exists for

@Suite("Visual region detection")
struct VisualRegionDetectorTests {

    @Test("A white canvas on a dark desktop is found, on its exact edges")
    func whiteCanvasOnDarkGrey() {
        let found = VisualRegionDetector.detect(in: canvasField())
        let match = candidate(matching: canvasRect, in: found)

        #expect(match != nil, note("expected \(canvasRect), got:\n\(describe(found))"))
        #expect((match?.confidence ?? 0) > 0.9)
        #expect(match?.interiorIsBrighter == true)
    }

    @Test("On a hard edge the boundary is exact, not merely close")
    func hardEdgeIsExact() {
        // The banded step that discovers an edge reports the same full step at every line within
        // the guard gap of the truth, so discovery alone cannot do better than "within a sample
        // or two". This asserts the localisation pass actually runs: on a hard edge there is one
        // single-sample gradient peak and it is the answer, exactly.
        let found = VisualRegionDetector.detect(in: canvasField())
        #expect(candidate(matching: canvasRect, in: found, tolerance: 0) != nil, note(describe(found)))
    }

    @Test("A boundary survives a 2× downscale to within two source pixels")
    func downscaleErrorBound() {
        // Production detects on a field roughly half the display's pixel resolution, so one field
        // sample is about two source pixels and a boundary can only ever be localised to that.
        // This measures the claim rather than asserting it in a comment: build the fixture at
        // source resolution, put it through the same box filter the capture path applies, detect,
        // and scale the answer back up.
        let factor = 2
        let source = CGRect(x: 120, y: 80, width: 360, height: 260)
        let full = PixelField(width: 640, height: 440) { x, y in
            source.contains(CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5))
                ? (0.97, 0.97, 0.97)
                : (0.16, 0.16, 0.16)
        }

        let reduced = try! #require(full.downsampled(by: factor))
        #expect(reduced.width == 320 && reduced.height == 220)

        let found = VisualRegionDetector.detect(in: reduced)
        let best = try! #require(found.first, note(describe(found)))

        let scaled = CGRect(
            x: best.rect.minX * CGFloat(factor), y: best.rect.minY * CGFloat(factor),
            width: best.rect.width * CGFloat(factor), height: best.rect.height * CGFloat(factor)
        )
        for (found, truth) in [
            (scaled.minX, source.minX), (scaled.minY, source.minY),
            (scaled.maxX, source.maxX), (scaled.maxY, source.maxY),
        ] {
            #expect(
                abs(found - truth) <= CGFloat(factor),
                note("edge \(found) is more than \(factor) source pixels from \(truth); rect \(scaled)")
            )
        }
    }

    @Test("Off-white on light grey is found too, with less confidence than the obvious case")
    func offWhiteOnLightGrey() {
        // 0.93 against 0.85 is a step of 0.08 — the case a threshold tuned for white-on-black
        // would throw away, and the one that shows up in every light-mode screenshot.
        let subtle = VisualRegionDetector.detect(in: canvasField(background: 0.85, canvas: 0.93))
        let obvious = VisualRegionDetector.detect(in: canvasField())

        let subtleMatch = candidate(matching: canvasRect, in: subtle)
        #expect(subtleMatch != nil, note("expected \(canvasRect), got:\n\(describe(subtle))"))
        #expect((subtleMatch?.confidence ?? 0) >= VisualRegionPicker.Options.default.minConfidence)
        #expect(
            (subtleMatch?.confidence ?? 1) < (candidate(matching: canvasRect, in: obvious)?.confidence ?? 0),
            "a fainter edge must not read as more certain than an unmistakable one"
        )
    }

    @Test("A step under the contrast floor is not a boundary")
    func contrastBelowTheFloor() {
        // 0.015 apart: a gradient in a wallpaper, a banding artefact, a hover state. Offering
        // this as a click target would be worse than offering nothing.
        let found = VisualRegionDetector.detect(in: canvasField(background: 0.885, canvas: 0.90))
        #expect(candidate(matching: canvasRect, in: found) == nil, note(describe(found)))
    }

    @Test("Colour alone is enough — a step needs no brightness difference")
    func hueOnlyStep() {
        // Rust on mid-grey: near-identical luma, obviously different colour. A luminance-only
        // detector is blind to this, which is why the step is measured as a colour distance.
        let coloured = PixelField(width: 320, height: 220) { x, y in
            canvasRect.contains(CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5))
                ? (0.80, 0.42, 0.20)
                : (0.50, 0.50, 0.50)
        }
        let found = VisualRegionDetector.detect(in: coloured)
        #expect(candidate(matching: canvasRect, in: found) != nil, note(describe(found)))
    }

    @Test("A drop shadow does not drag the edge off the canvas")
    func dropShadowKeepsTheEdge() {
        // The shadow is a second, opposite-polarity boundary a few samples outside the real one.
        // The canvas edge must still be the one reported.
        let shadowed = PixelField(width: 320, height: 220) { x, y in
            let point = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)
            if canvasRect.contains(point) { return (0.97, 0.97, 0.97) }

            // Falls off over 7 samples around the canvas, darkest against it.
            let dx = max(canvasRect.minX - point.x, point.x - canvasRect.maxX, 0)
            let dy = max(canvasRect.minY - point.y, point.y - canvasRect.maxY, 0)
            let distance = max(dx, dy)
            let background: Float = 0.16
            guard distance < 7 else { return (background, background, background) }
            let level = background * (0.45 + 0.55 * Float(distance) / 7)
            return (level, level, level)
        }

        let found = VisualRegionDetector.detect(in: shadowed)
        let match = candidate(matching: canvasRect, in: found, tolerance: 2)
        #expect(match != nil, note("expected \(canvasRect), got:\n\(describe(found))"))
        #expect(match?.interiorIsBrighter == true)
    }

    @Test("Anti-aliasing and compression noise do not break the edge")
    func softEdgesAndNoise() {
        let soft = PixelField(width: 320, height: 220) { x, y in
            let point = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)
            let inset = canvasRect.insetBy(dx: -1, dy: -1)
            var level: Float = 0.16
            if canvasRect.contains(point) {
                level = 0.97
            } else if inset.contains(point) {
                level = 0.56   // the one blended sample every rendered edge has
            }
            let v = min(1, max(0, level + noise(x, y, amplitude: 0.02)))
            return (v, v, v)
        }

        let found = VisualRegionDetector.detect(in: soft)
        #expect(candidate(matching: canvasRect, in: found, tolerance: 1) != nil, note(describe(found)))
    }

    @Test("Text rows, table rules and a dashed border are not regions")
    func thinInteriorDetailIsIgnored() {
        // Everything painted here is one or two samples wide. A gradient-based edge finder would
        // report dozens of rectangles; the guard gap either side of a boundary means none of it
        // is even visible as a step.
        let busy = field(
            background: 0.16,
            panels: [Panel(rect: canvasRect, level: 0.97)],
            decorate: { x, y in
                let point = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)
                let page = canvasRect.insetBy(dx: 10, dy: 10)
                guard page.contains(point) else { return nil }

                // Body text: 2-sample rows every 8.
                if (y - Int(page.minY)) % 8 < 2 && x < Int(page.maxX) - 20 { return 0.18 }
                // Table rules: 1-sample columns every 30.
                if (x - Int(page.minX)) % 30 == 0 { return 0.35 }
                // A dashed box border, 1 sample thick.
                let box = CGRect(x: 90, y: 90, width: 100, height: 50)
                let onBox = (abs(point.x - box.minX) < 1 || abs(point.x - box.maxX) < 1
                             || abs(point.y - box.minY) < 1 || abs(point.y - box.maxY) < 1)
                    && box.insetBy(dx: -1, dy: -1).contains(point)
                if onBox && (x + y) % 6 < 3 { return 0.30 }
                return nil
            }
        )

        let found = VisualRegionDetector.detect(in: busy)
        #expect(candidate(matching: canvasRect, in: found, tolerance: 1) != nil, note(describe(found)))

        // Nothing else may be offered: the interior detail is content, not structure.
        let others = found.filter { VisualRegionDetector.intersectionOverUnion($0.rect, canvasRect) < 0.85 }
        #expect(others.isEmpty, note("interior detail produced regions:\n\(describe(others))"))
    }

    @Test("A panel inside a canvas is offered as well as the canvas")
    func nestedRegions() {
        let inner = CGRect(x: 100, y: 70, width: 90, height: 60)
        let nested = field(panels: [
            Panel(rect: canvasRect, level: 0.97),
            Panel(rect: inner, level: 0.62),
        ])

        let found = VisualRegionDetector.detect(in: nested)
        #expect(candidate(matching: canvasRect, in: found) != nil, note(describe(found)))
        let innerMatch = candidate(matching: inner, in: found)
        #expect(innerMatch != nil, note(describe(found)))
        #expect(innerMatch?.interiorIsBrighter == false, "the inner panel is the darker side")
    }

    @Test("A field with nothing rectangular in it yields nothing")
    func noRegions() {
        // A diagonal gradient with noise: plenty of gradient everywhere, no step anywhere.
        let gradient = PixelField(width: 320, height: 220) { x, y in
            let v = 0.20 + 0.5 * Float(x + y) / Float(320 + 220) + noise(x, y, amplitude: 0.01)
            return (v, v, v)
        }
        let found = VisualRegionDetector.detect(in: gradient)
        #expect(found.isEmpty, note(describe(found)))
    }

    @Test("A flat field is not one enormous region")
    func flatFieldIsNotARegion() {
        let flat = field(panels: [], noiseAmplitude: 0.01)
        #expect(VisualRegionDetector.detect(in: flat).isEmpty)
    }

    @Test("A region flush with the edge of the field is deliberately not offered")
    func edgeFlushRegionIsNotOffered() {
        // Its left side has no outside to compare against. Accepting "the screen edge counts as a
        // boundary" is what would let a full-screen wallpaper or a maximised window's background
        // masquerade as a region and take window selection away, so the rule is: boundaries are
        // interior or they are not boundaries.
        let flush = field(panels: [Panel(rect: CGRect(x: 0, y: 40, width: 200, height: 130), level: 0.97)])
        let found = VisualRegionDetector.detect(in: flush)
        let reach = CGFloat(VisualRegionDetector.Options.default.reach)
        #expect(found.allSatisfy { $0.rect.minX >= reach }, note(describe(found)))
    }

    @Test("A region covering nearly the whole field is refused")
    func nearFullFieldIsRefused() {
        // 96% of the field. This is the flat backdrop case: without the area bound it would be
        // offered with high confidence and would shadow every window on the display.
        let huge = CGRect(x: 5, y: 4, width: 310, height: 212)
        let found = VisualRegionDetector.detect(in: field(panels: [Panel(rect: huge, level: 0.97)]))
        #expect(candidate(matching: huge, in: found) == nil, note(describe(found)))
    }

    @Test("Confidence tapers as a region approaches the size of the whole field")
    func confidenceTapersWithSize() {
        let modest = VisualRegionDetector.detect(in: field(panels: [
            Panel(rect: CGRect(x: 60, y: 40, width: 120, height: 90), level: 0.97),
        ]))
        let sprawling = VisualRegionDetector.detect(in: field(panels: [
            Panel(rect: CGRect(x: 8, y: 6, width: 300, height: 202), level: 0.97),
        ]))

        let modestBest = modest.first?.confidence ?? 0
        let sprawlingBest = sprawling.first?.confidence ?? 0
        #expect(modestBest > sprawlingBest)
    }

    @Test("Both axes behave identically: a transposed field yields transposed regions")
    func transposeSymmetry() {
        let upright = VisualRegionDetector.detect(in: canvasField())
        let sideways = VisualRegionDetector.detect(in: canvasField().transposed())

        #expect(candidate(matching: canvasRect, in: upright) != nil)
        let mirrored = CGRect(
            x: canvasRect.minY, y: canvasRect.minX, width: canvasRect.height, height: canvasRect.width
        )
        let sidewaysMatch = candidate(matching: mirrored, in: sideways)
        #expect(sidewaysMatch != nil, note(describe(sideways)))
        #expect(
            abs((upright.first?.confidence ?? 0) - (sidewaysMatch?.confidence ?? 0)) < 0.02,
            "the same rectangle must score the same either way up"
        )
    }

    @Test("Transposing twice is the identity")
    func transposeRoundTrip() {
        let original = canvasField()
        #expect(original.transposed().transposed() == original)
    }

    @Test("A degenerate field is handled rather than trapped")
    func degenerateFields() {
        #expect(PixelField(width: 0, height: 10, bytes: []) == nil)
        #expect(PixelField(width: 4, height: 4, bytes: [0, 0, 0]) == nil)
        // Smaller than the measurement bands can reach into.
        let tiny = PixelField(width: 6, height: 6) { _, _ in (0.5, 0.5, 0.5) }
        #expect(VisualRegionDetector.detect(in: tiny).isEmpty)
    }
}
