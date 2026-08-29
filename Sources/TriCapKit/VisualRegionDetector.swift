import CoreGraphics
import Foundation

/// Finds axis-aligned rectangles that the *pixels* make obvious but the window server knows
/// nothing about — the white image canvas inside a dark-grey viewer, a document page, a panel.
///
/// The window list stops at window frames. A user pointing at "that picture" is pointing at a
/// rectangle inside a window, and no public API will name it, so TriCap reads it off the screen
/// content instead. This file is the whole decision, and it is deliberately pure: it takes a
/// ``PixelField`` and returns rectangles in field samples. Nothing here touches AppKit, Screen-
/// CaptureKit or a display, which is what lets the fixtures run in a headless test process.
///
/// ## Three measurements, three different jobs
///
/// **The banded step — discovery.** The mean colour of a short band on one side of a candidate
/// line against the mean on the other, with a guard gap between them so anti-aliasing does not
/// blunt it. Averaging is what makes this survive noise and shadows. It is deliberately blunt
/// about *where* the edge is: a band of width `b` with a gap of `g` reports the same full step at
/// every line within `g` of the truth, so this stage answers "there is an edge near here", never
/// "the edge is exactly here".
///
/// **The fine gradient — localisation.** Single-sample colour difference, averaged along the
/// whole length of the edge. Averaging along the edge cancels noise (a hundred rows of it) while
/// keeping the one-sample sharpness across the edge, so the peak lands on the true boundary even
/// when the step itself is faint. This is the stage that turns "near here" into a number, and
/// without it every reported rectangle is off by an arbitrary amount up to the guard gap.
///
/// **Profile separation — rejection.** Ten samples marching away from the boundary on each side.
/// The two runs have to be *separated*, third-from-the-end against third-from-the-end, not merely
/// different on average. This is what tells a region boundary from texture: body text, table
/// rules, striped lists and the far side of a nearby edge all produce genuine band steps, because
/// a band a few samples wide cannot tell "a different region starts here" from "a dark row
/// happens to fall in this band". Interleaved profiles cannot pass, however large the mean
/// difference is.
///
/// **What is deliberately not detected.** A side flush with the edge of the field has no outside
/// to compare against, so it is not a boundary and the rectangle is not offered. That rules out
/// the desktop wallpaper, a maximised window's uniform background, and every other "rectangle"
/// whose only edges are the edges of the screen — exactly the candidates that would otherwise
/// swallow window selection.
public enum VisualRegionDetector {

    // MARK: - Tuning

    public struct Options: Sendable, Equatable {

        /// Samples averaged on each side of a boundary during discovery.
        public var bandWidth: Int

        /// Samples skipped either side of the boundary line itself — the anti-aliasing guard.
        ///
        /// It is also why a hairline is invisible: a rule thinner than `2 * guardGap + 1` sits
        /// entirely in the skipped strip. And it is why discovery cannot localise: every line
        /// within this distance of the truth reports the same step.
        public var guardGap: Int

        /// Samples walked outwards from a boundary for the separation test.
        public var profileDepth: Int

        /// Smallest colour step, in `0...1` distance, that counts as a boundary at all.
        ///
        /// Deliberately low. Off-white on light grey is a real, common case — 0.93 against 0.85
        /// is a step of 0.08 — and a threshold tuned for white-on-black would refuse it. False
        /// positives are held back by separation, continuity and size instead, which is where the
        /// evidence actually is. Nothing in this file tests for "white": polarity is measured,
        /// never assumed.
        public var minContrast: Float

        /// Fraction of a side that must show the step *and* pass separation.
        public var minEdgeSupport: Float

        /// Fraction averaged over all four sides. One weak side is tolerable; four are not.
        public var minMeanEdgeSupport: Float

        /// Shortest side, in samples, that can form a rectangle. Must leave room for a full
        /// profile on both sides of the region, which is what ``resolvedMinEdgeSamples`` enforces.
        public var minEdgeSamples: Int

        /// Area bounds as a fraction of the whole field.
        ///
        /// `maxAreaFraction` is the guard against a near-full-screen flat backdrop being offered
        /// as "a region": it is rejected outright above the bound, and its confidence tapers off
        /// as it approaches it, so a window underneath keeps its claim.
        public var minAreaFraction: Double
        public var maxAreaFraction: Double

        /// Beyond this, a "rectangle" is a bar or a rule, not a region.
        public var maxAspectRatio: Double

        /// Bounds on the combinatorial work, so a busy screen cannot make detection quadratic in
        /// something unbounded.
        public var maxSegmentsPerPolarity: Int
        public var maxCandidates: Int

        public init(
            bandWidth: Int = 3,
            guardGap: Int = 1,
            profileDepth: Int = 10,
            minContrast: Float = 0.05,
            minEdgeSupport: Float = 0.72,
            minMeanEdgeSupport: Float = 0.85,
            minEdgeSamples: Int = 24,
            minAreaFraction: Double = 0.003,
            maxAreaFraction: Double = 0.92,
            maxAspectRatio: Double = 14,
            maxSegmentsPerPolarity: Int = 32,
            maxCandidates: Int = 24
        ) {
            self.bandWidth = max(1, bandWidth)
            self.guardGap = max(0, guardGap)
            self.profileDepth = max(2, profileDepth)
            self.minContrast = minContrast
            self.minEdgeSupport = minEdgeSupport
            self.minMeanEdgeSupport = minMeanEdgeSupport
            self.minEdgeSamples = max(4, minEdgeSamples)
            self.minAreaFraction = minAreaFraction
            self.maxAreaFraction = maxAreaFraction
            self.maxAspectRatio = maxAspectRatio
            self.maxSegmentsPerPolarity = max(1, maxSegmentsPerPolarity)
            self.maxCandidates = max(1, maxCandidates)
        }

        public static let `default` = Options()

        /// How far outside a boundary the measurements reach. Boundaries closer than this to the
        /// edge of the field cannot be measured, and are therefore not boundaries.
        public var reach: Int { guardGap + max(bandWidth, profileDepth) }

        /// A region has to be wide enough for both of its sides to see a full profile of its
        /// interior without the two overlapping.
        var resolvedMinEdgeSamples: Int { max(minEdgeSamples, 2 * (guardGap + profileDepth)) }

        /// Margin the separation test has to clear. A fraction of the contrast floor rather than
        /// the whole of it: separation is a structural claim ("these two runs do not interleave"),
        /// and the size of the step is already scored elsewhere.
        var separationMargin: Float { 0.4 * minContrast }

        /// Shortest run, along a boundary, worth proposing a rectangle from.
        func minRunLength(across extent: Int) -> Int {
            max(resolvedMinEdgeSamples, Int(Double(extent) * 0.04))
        }
    }

    // MARK: - Output

    /// One rectangle the pixels make a case for, in **field samples**, top-left origin.
    ///
    /// Field samples — not points and not display pixels. Mapping into AppKit global points is
    /// ``VisualRegionMapping``'s job and is tested separately, because a detector that is right
    /// about the rectangle and wrong about the display is the bug that has bitten this codebase
    /// before.
    public struct Candidate: Equatable, Sendable {
        /// Integral rect in field samples.
        public let rect: CGRect
        /// `0...1`. ``VisualRegionPicker`` owns the bar this has to clear.
        public let confidence: Double
        /// `true` when the interior is the brighter side — the white-canvas case. Measured, and
        /// recorded so callers and tests can see which way the step went.
        public let interiorIsBrighter: Bool
        /// Continuity of the *weakest* of the four sides, `0...1`.
        public let edgeSupport: Double
        /// Mean colour step across the four sides, `0...1`.
        public let contrast: Double

        public init(
            rect: CGRect,
            confidence: Double,
            interiorIsBrighter: Bool,
            edgeSupport: Double,
            contrast: Double
        ) {
            self.rect = rect
            self.confidence = confidence
            self.interiorIsBrighter = interiorIsBrighter
            self.edgeSupport = edgeSupport
            self.contrast = contrast
        }
    }

    // MARK: - Entry point

    /// Every rectangle the field supports, most confident first.
    ///
    /// Runs the single-axis pass twice — once over `field`, once over its transpose — and merges
    /// the results. A rectangle whose vertical sides are crisp but whose horizontal sides are
    /// broken by overlapping content is found by the first pass; the mirror case is found by the
    /// second. One implementation, two orientations, so neither axis can quietly behave
    /// differently from the other.
    public static func detect(in field: PixelField, options: Options = .default) -> [Candidate] {
        let transposed = field.transposed()

        var found = proposals(in: field, cross: transposed, options: options)
        found += proposals(in: transposed, cross: field, options: options).map(\.swappingAxes)

        return merged(found, options: options)
    }

    // MARK: - One axis

    /// Rectangles proposed from the vertical boundaries of `field`.
    ///
    /// `cross` must be `field.transposed()`: probing a vertical boundary in the transpose at
    /// column `y`, row `x`, *is* probing a horizontal boundary in `field` at row `y`, column `x`.
    /// Reusing one probe for both axes is why there is no second, subtly different copy of the
    /// step arithmetic in this file.
    private static func proposals(
        in field: PixelField,
        cross: PixelField,
        options: Options
    ) -> [Candidate] {
        let minEdge = options.resolvedMinEdgeSamples
        guard field.width > 2 * options.reach + minEdge,
              field.height > 2 * options.reach + minEdge
        else { return [] }

        return field.bytes.withUnsafeBufferPointer { fieldBytes in
            cross.bytes.withUnsafeBufferPointer { crossBytes in
                let down = Probe(bytes: fieldBytes, width: field.width, height: field.height, options: options)
                let across = Probe(bytes: crossBytes, width: cross.width, height: cross.height, options: options)

                let segments = boundarySegments(probe: down, options: options)
                guard !segments.isEmpty else { return [] }

                let rising = segments.filter { $0.risesTowardsHigh }
                let falling = segments.filter { !$0.risesTowardsHigh }

                var seen = Set<IntRect>()
                var results: [Candidate] = []

                // A bright interior steps up at its low-side boundary and down at its high-side
                // one; a dark interior does the reverse. Both are ordinary — a dark panel on a
                // light page is as real as a white canvas on a dark desktop — so both are tried.
                for (lows, highs, interiorIsBrighter) in [(rising, falling, true), (falling, rising, false)] {
                    for low in lows {
                        for high in highs where high.position - low.position >= minEdge {
                            guard let span = low.overlap(with: high),
                                  span.length >= minEdge,
                                  // A pair of edges that barely share a stretch is a coincidence,
                                  // not two sides of one thing.
                                  span.length * 2 >= max(low.length, high.length)
                            else { continue }

                            guard let rows = refinedRows(
                                columns: low.position..<high.position,
                                around: span,
                                interiorIsBrighter: interiorIsBrighter,
                                probe: across,
                                options: options
                            ) else { continue }

                            let rect = IntRect(
                                x0: low.position, x1: high.position, y0: rows.lowerBound, y1: rows.upperBound
                            )
                            guard rect.height >= minEdge, seen.insert(rect).inserted else { continue }

                            if let candidate = evaluate(
                                rect,
                                interiorIsBrighter: interiorIsBrighter,
                                down: down,
                                across: across,
                                options: options
                            ) {
                                results.append(candidate)
                            }
                        }
                    }
                }
                return results
            }
        }
    }

    // MARK: - Boundary segments

    /// A run of rows along one column that all show the same step.
    private struct Segment {
        /// Boundary index: the split between column `position - 1` and column `position`.
        let position: Int
        /// Inclusive row range.
        let start: Int
        let end: Int
        let meanMagnitude: Float
        /// `true` when the high side (larger coordinates) is the brighter one.
        let risesTowardsHigh: Bool

        var length: Int { end - start + 1 }
        var strength: Float { Float(length) * meanMagnitude }

        func overlap(with other: Segment) -> (lowerBound: Int, upperBound: Int, length: Int)? {
            let lower = max(start, other.start)
            let upper = min(end, other.end)
            guard upper >= lower else { return nil }
            return (lower, upper, upper - lower + 1)
        }

        func moved(to newPosition: Int) -> Segment {
            Segment(
                position: newPosition, start: start, end: end,
                meanMagnitude: meanMagnitude, risesTowardsHigh: risesTowardsHigh
            )
        }
    }

    private static func boundarySegments(probe: Probe, options: Options) -> [Segment] {
        let reach = options.reach
        let height = probe.height
        let minRun = options.minRunLength(across: height)
        // Anti-aliasing, a scroll bar overlapping an edge or a rounded corner all break a run for
        // a few samples. Bridging short gaps keeps one edge from being reported as three.
        let gapTolerance = max(3, height / 64)

        var magnitudes = [Float](repeating: 0, count: height)
        var rises = [Bool](repeating: false, count: height)
        var segments: [Segment] = []

        for x in reach...(probe.width - reach) {
            for y in 0..<height {
                let step = probe.bandStep(boundary: x, along: y)
                magnitudes[y] = step.magnitude
                rises[y] = step.signedLuma >= 0
            }

            for risesTowardsHigh in [true, false] {
                var runStart = -1
                var lastGood = -1
                var sum: Float = 0
                var count = 0

                func close() {
                    if runStart >= 0, lastGood - runStart + 1 >= minRun, count > 0 {
                        segments.append(Segment(
                            position: x,
                            start: runStart,
                            end: lastGood,
                            meanMagnitude: sum / Float(count),
                            risesTowardsHigh: risesTowardsHigh
                        ))
                    }
                    runStart = -1
                    sum = 0
                    count = 0
                }

                for y in 0..<height {
                    if magnitudes[y] >= options.minContrast, rises[y] == risesTowardsHigh {
                        if runStart < 0 { runStart = y }
                        lastGood = y
                        sum += magnitudes[y]
                        count += 1
                    } else if runStart >= 0, y - lastGood > gapTolerance {
                        close()
                    }
                }
                close()
            }
        }

        // Localise *before* suppressing. Discovery reports the same edge from several nearby
        // lines and from partial bands further out; once every one of them has been pulled onto
        // the same true boundary, suppression is just de-duplication and cannot pick a loser.
        let onTheirEdges = segments.compactMap { localised($0, probe: probe, options: options) }
        return suppressed(onTheirEdges, options: options)
    }

    /// Pull a discovered segment onto the boundary it is actually near.
    ///
    /// The banded step saturates over a plateau `guardGap` wide either side of the truth, and
    /// partial-band positions further out still clear the contrast floor, so discovery routinely
    /// reports an edge several samples from where it is. The single-sample colour difference has
    /// no such plateau — but on its own it is noisy, so it is averaged along the whole length of
    /// the edge first. Hundreds of rows of noise cancel; the edge does not.
    private static func localised(_ segment: Segment, probe: Probe, options: Options) -> Segment? {
        let reach = options.reach
        let lowest = max(reach, segment.position - reach)
        let highest = min(probe.width - reach, segment.position + reach)
        guard lowest <= highest else { return nil }

        var bestPosition = segment.position
        var bestGradient: Float = -1

        for position in lowest...highest {
            let gradient = meanFineGradient(
                boundary: position, from: segment.start, through: segment.end, probe: probe
            )
            if gradient > bestGradient {
                bestGradient = gradient
                bestPosition = position
            }
        }

        // The step has to survive at the localised line, in the same direction. A peak that
        // cannot be confirmed as the same edge is not the same edge.
        let confirmation = probe.bandStep(boundary: bestPosition, along: (segment.start + segment.end) / 2)
        guard bestGradient >= options.minContrast * 0.5,
              (confirmation.signedLuma >= 0) == segment.risesTowardsHigh
        else { return nil }

        return segment.moved(to: bestPosition)
    }

    /// Mean single-sample colour difference across `boundary`, averaged along the edge.
    ///
    /// Unsigned on purpose: a panel that differs in hue but barely in brightness has a real edge
    /// and a near-zero luma gradient, and averaging signed luma would put its peak in the noise.
    /// Direction is already fixed by the segment that asked.
    private static func meanFineGradient(
        boundary: Int,
        from start: Int,
        through end: Int,
        probe: Probe
    ) -> Float {
        let inset = cornerInset(of: end - start + 1)
        let first = start + inset
        let last = end - inset
        guard last > first else { return 0 }

        let count = min(96, last - first + 1)
        var sum: Float = 0
        for index in 0..<count {
            let along = first + (last - first) * index / max(1, count - 1)
            sum += probe.fineStep(boundary: boundary, along: along)
        }
        return sum / Float(count)
    }

    /// Keep one segment per boundary neighbourhood.
    ///
    /// After localisation the copies of an edge share a position exactly, so this is mostly
    /// de-duplication; the radius of one absorbs the residual jitter of a soft edge whose peak
    /// straddles two samples.
    private static func suppressed(_ segments: [Segment], options: Options) -> [Segment] {
        var kept: [Segment] = []

        for segment in segments.sorted(by: { $0.strength > $1.strength }) {
            let shadowed = kept.contains { other in
                other.risesTowardsHigh == segment.risesTowardsHigh
                    && abs(other.position - segment.position) <= 1
                    && (segment.overlap(with: other)?.length ?? 0) * 2 >= min(segment.length, other.length)
            }
            if !shadowed { kept.append(segment) }
        }

        // Two polarities, each capped: the cap has to be per-polarity or a screen full of one
        // kind of edge would starve the other and no rectangle could ever be paired.
        let rising = kept.filter(\.risesTowardsHigh).prefix(options.maxSegmentsPerPolarity)
        let falling = kept.filter { !$0.risesTowardsHigh }.prefix(options.maxSegmentsPerPolarity)
        return Array(rising) + Array(falling)
    }

    // MARK: - Closing the rectangle

    /// Find the top and bottom boundaries that close a pair of vertical edges.
    ///
    /// The shared stretch of the two vertical runs says roughly where the rectangle starts and
    /// ends, but a run often overshoots — a canvas edge that happens to line up with something
    /// below it reads as one long run. So the vertical extent is *searched* near the proposal
    /// rather than trusted, by the same fine gradient that localises the vertical edges.
    private static func refinedRows(
        columns: Range<Int>,
        around span: (lowerBound: Int, upperBound: Int, length: Int),
        interiorIsBrighter: Bool,
        probe: Probe,
        options: Options
    ) -> Range<Int>? {
        let radius = max(2, min(12, span.length / 20))

        guard let top = bestBoundary(
            near: span.lowerBound, radius: radius, across: columns,
            expectingRise: interiorIsBrighter, probe: probe, options: options
        ) else { return nil }

        guard let bottom = bestBoundary(
            near: span.upperBound + 1, radius: radius, across: columns,
            expectingRise: !interiorIsBrighter, probe: probe, options: options
        ) else { return nil }

        // Half-open: `bottom` is the boundary the rectangle stops at, i.e. the first row outside.
        guard bottom - top >= options.resolvedMinEdgeSamples else { return nil }
        return top..<bottom
    }

    /// The strongest boundary within `radius` of `centre`, localised the same way edges are.
    private static func bestBoundary(
        near centre: Int,
        radius: Int,
        across columns: Range<Int>,
        expectingRise: Bool,
        probe: Probe,
        options: Options
    ) -> Int? {
        // In the transposed probe, a boundary index is a row of the original field.
        let lowest = max(options.reach, centre - radius)
        let highest = min(probe.width - options.reach, centre + radius)
        guard lowest <= highest else { return nil }

        var best: (position: Int, gradient: Float)?
        for position in lowest...highest {
            let gradient = meanFineGradient(
                boundary: position, from: columns.lowerBound, through: columns.upperBound - 1, probe: probe
            )
            if best == nil || gradient > best!.gradient {
                best = (position, gradient)
            }
        }
        guard let best, best.gradient >= options.minContrast * 0.5 else { return nil }

        // Half a side is not a rectangle; refuse rather than close it on nothing.
        let support = coarseSupport(
            boundary: best.position, across: columns,
            expectingRise: expectingRise, probe: probe, options: options
        )
        guard support >= 0.5 else { return nil }
        return best.position
    }

    /// Cheap support estimate: two dozen samples, no separation test. Used only to reject a
    /// hopeless closure before the full measurement runs.
    private static func coarseSupport(
        boundary: Int,
        across range: Range<Int>,
        expectingRise: Bool,
        probe: Probe,
        options: Options
    ) -> Float {
        let inset = cornerInset(of: range.count)
        let usable = (range.lowerBound + inset)..<(range.upperBound - inset)
        guard usable.count >= 4 else { return 0 }

        let count = min(24, usable.count)
        var hits = 0
        for index in 0..<count {
            let along = usable.lowerBound + (usable.count - 1) * index / max(1, count - 1)
            guard along >= 0, along < probe.height else { continue }
            let step = probe.bandStep(boundary: boundary, along: along)
            if step.magnitude >= options.minContrast, (step.signedLuma >= 0) == expectingRise {
                hits += 1
            }
        }
        return Float(hits) / Float(count)
    }

    /// Rounded corners are the norm, not the exception. Skipping a little of each end keeps a
    /// 10 pt radius from being reported as a broken edge.
    private static func cornerInset(of length: Int) -> Int {
        max(2, min(12, length / 25))
    }

    // MARK: - Measuring and scoring

    private struct SideMeasurement {
        let support: Float
        let meanMagnitude: Float
        let innerColour: SIMD3<Float>
        let outerColour: SIMD3<Float>
    }

    private static func evaluate(
        _ rect: IntRect,
        interiorIsBrighter: Bool,
        down: Probe,
        across: Probe,
        options: Options
    ) -> Candidate? {
        let fieldArea = Double(down.width) * Double(down.height)
        let area = Double(rect.width) * Double(rect.height)
        let areaFraction = area / fieldArea

        guard areaFraction >= options.minAreaFraction, areaFraction <= options.maxAreaFraction else {
            return nil
        }
        let aspect = max(Double(rect.width) / Double(rect.height), Double(rect.height) / Double(rect.width))
        guard aspect <= options.maxAspectRatio else { return nil }

        // Left and right come from the field itself; top and bottom from its transpose, where
        // they are left and right again. Same probe, same arithmetic, four sides.
        let sides = [
            measure(boundary: rect.x0, across: rect.y0..<rect.y1, expectingRise: interiorIsBrighter,
                    probe: down, options: options),
            measure(boundary: rect.x1, across: rect.y0..<rect.y1, expectingRise: !interiorIsBrighter,
                    probe: down, options: options),
            measure(boundary: rect.y0, across: rect.x0..<rect.x1, expectingRise: interiorIsBrighter,
                    probe: across, options: options),
            measure(boundary: rect.y1, across: rect.x0..<rect.x1, expectingRise: !interiorIsBrighter,
                    probe: across, options: options),
        ]
        guard sides.allSatisfy({ $0 != nil }) else { return nil }
        let measured = sides.compactMap { $0 }

        let supports = measured.map(\.support)
        let minSupport = supports.min() ?? 0
        let meanSupport = supports.reduce(0, +) / Float(supports.count)
        guard minSupport >= options.minEdgeSupport, meanSupport >= options.minMeanEdgeSupport else {
            return nil
        }

        let meanMagnitude = measured.map(\.meanMagnitude).reduce(0, +) / Float(measured.count)

        // A step of 0.25 is already unmistakable, so the curve saturates there rather than
        // rewarding black-on-white over the off-white cases this exists to handle.
        let contrast = min(1.0, Double((meanMagnitude / 0.25).squareRoot()))

        let remap = { (value: Float) -> Double in
            let span = max(0.01, 1 - options.minEdgeSupport)
            return min(1, max(0, Double((value - options.minEdgeSupport) / span)))
        }
        let continuity = 0.4 * remap(minSupport) + 0.6 * remap(meanSupport)

        // Four sides of one object usually share an inner colour — a white canvas is white on all
        // four rims — *and* sit in one surrounding — a canvas on a desktop has desktop on all four
        // sides. Four unrelated edges that happen to form a rectangle usually agree on neither.
        // The outer term is the one that catches a rectangle assembled from a real vertical edge
        // and a line of text: its vertical outsides are page, its horizontal outsides are ink.
        let innerAgreement = agreement(of: measured.map(\.innerColour))
        let outerAgreement = agreement(of: measured.map(\.outerColour))

        // Weak on purpose: a photograph inside the canvas is not a reason to doubt the canvas.
        let interiorSpread = interiorDeviation(of: rect, probe: down, options: options)
        let interiorConsistency = max(0, 1 - Double(interiorSpread) / 0.35)

        let base = 0.30 * contrast
            + 0.34 * continuity
            + 0.14 * innerAgreement
            + 0.14 * outerAgreement
            + 0.08 * interiorConsistency
        let confidence = min(1, max(0, base * sizePlausibility(
            areaFraction: areaFraction, aspect: aspect, options: options
        )))

        return Candidate(
            rect: rect.cgRect,
            confidence: confidence,
            interiorIsBrighter: interiorIsBrighter,
            edgeSupport: Double(minSupport),
            contrast: Double(meanMagnitude)
        )
    }

    /// How closely a set of colours agree, `0...1`, by their widest pairwise distance.
    private static func agreement(of colours: [SIMD3<Float>]) -> Double {
        var spread: Float = 0
        for i in colours.indices {
            for j in (i + 1)..<colours.count {
                spread = max(spread, distance(colours[i], colours[j]))
            }
        }
        return max(0, 1 - Double(spread) / 0.35)
    }

    private static func measure(
        boundary: Int,
        across range: Range<Int>,
        expectingRise: Bool,
        probe: Probe,
        options: Options
    ) -> SideMeasurement? {
        guard boundary >= options.reach, boundary <= probe.width - options.reach else { return nil }

        let inset = cornerInset(of: range.count)
        let usable = (range.lowerBound + inset)..<(range.upperBound - inset)
        guard usable.count >= 4 else { return nil }

        let count = min(192, usable.count)
        var hits = 0
        var magnitudeSum: Float = 0
        var innerSum = SIMD3<Float>(repeating: 0)
        var outerSum = SIMD3<Float>(repeating: 0)
        var taken = 0

        for index in 0..<count {
            let along = usable.lowerBound + (usable.count - 1) * index / max(1, count - 1)
            guard along >= 0, along < probe.height else { continue }
            taken += 1

            let step = probe.bandStep(boundary: boundary, along: along)
            innerSum += expectingRise ? step.high : step.low
            outerSum += expectingRise ? step.low : step.high

            guard step.magnitude >= options.minContrast,
                  (step.signedLuma >= 0) == expectingRise,
                  probe.profilesSeparate(boundary: boundary, along: along, low: step.low, high: step.high)
            else { continue }
            hits += 1
            magnitudeSum += step.magnitude
        }
        guard taken > 0 else { return nil }

        return SideMeasurement(
            support: Float(hits) / Float(taken),
            meanMagnitude: hits > 0 ? magnitudeSum / Float(hits) : 0,
            innerColour: innerSum / Float(taken),
            outerColour: outerSum / Float(taken)
        )
    }

    /// Standard deviation of luma over a coarse grid strictly inside the rectangle.
    private static func interiorDeviation(of rect: IntRect, probe: Probe, options: Options) -> Float {
        let inset = options.guardGap + options.bandWidth + 1
        let xs = (rect.x0 + inset)..<(rect.x1 - inset)
        let ys = (rect.y0 + inset)..<(rect.y1 - inset)
        guard xs.count >= 2, ys.count >= 2 else { return 0 }

        let columns = min(20, xs.count)
        let rows = min(20, ys.count)
        var sum: Float = 0
        var sumOfSquares: Float = 0
        var count: Float = 0

        for row in 0..<rows {
            let y = ys.lowerBound + (ys.count - 1) * row / max(1, rows - 1)
            for column in 0..<columns {
                let x = xs.lowerBound + (xs.count - 1) * column / max(1, columns - 1)
                let luma = probe.luma(x: x, y: y)
                sum += luma
                sumOfSquares += luma * luma
                count += 1
            }
        }
        guard count > 1 else { return 0 }
        let mean = sum / count
        return max(0, sumOfSquares / count - mean * mean).squareRoot()
    }

    /// Taper towards the bounds rather than falling off a cliff at them.
    ///
    /// The upper taper is the important one: it is what stops a nearly-full-screen flat backdrop
    /// from arriving with the same confidence as a canvas that plainly *is* a canvas.
    private static func sizePlausibility(areaFraction: Double, aspect: Double, options: Options) -> Double {
        let head = min(1, (options.maxAreaFraction - areaFraction) / 0.12)
        let toe = min(1, (areaFraction - options.minAreaFraction) / 0.01)
        let slenderness = aspect <= 8 ? 1 : max(0, 1 - (aspect - 8) / (options.maxAspectRatio - 8))
        return max(0, min(1, head)) * max(0, min(1, toe)) * slenderness
    }

    // MARK: - Merging

    /// Most confident first, near-duplicates dropped.
    ///
    /// Both passes find the same obvious rectangle. Overlap is measured rather than compared for
    /// equality so those collapse into one, while genuinely nested rectangles — a panel inside a
    /// canvas — both survive, which is what the picker's "smallest wins" rule needs.
    private static func merged(_ candidates: [Candidate], options: Options) -> [Candidate] {
        var kept: [Candidate] = []
        for candidate in candidates.sorted(by: { $0.confidence > $1.confidence }) {
            let duplicate = kept.contains { intersectionOverUnion($0.rect, candidate.rect) >= 0.85 }
            if !duplicate { kept.append(candidate) }
            if kept.count >= options.maxCandidates { break }
        }
        return kept
    }

    static func intersectionOverUnion(_ a: CGRect, _ b: CGRect) -> Double {
        let intersection = a.intersection(b)
        guard !intersection.isNull else { return 0 }
        let overlap = Double(intersection.width * intersection.height)
        let union = Double(a.width * a.height) + Double(b.width * b.height) - overlap
        guard union > 0 else { return 0 }
        return overlap / union
    }

    private static func distance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        let d = a - b
        return (d.x * d.x + d.y * d.y + d.z * d.z).squareRoot() * 0.577_350_3
    }
}

// MARK: - Probe

/// Reads steps, gradients and profiles out of one field.
///
/// Lives here rather than on ``PixelField`` because it holds a buffer pointer: it is valid only
/// inside the `withUnsafeBufferPointer` scope that made it, and nothing outside this file should
/// be able to get one.
private struct Probe {
    let bytes: UnsafeBufferPointer<UInt8>
    let width: Int
    let height: Int
    let options: VisualRegionDetector.Options

    /// The two band means either side of the boundary that splits `boundary - 1` from `boundary`,
    /// measured on one row, plus the difference between them.
    ///
    /// `low` is the smaller-coordinate side. `signedLuma` is high minus low, so its sign says
    /// which side is brighter, and `magnitude` is the colour distance regardless of direction —
    /// a panel that differs in hue but not in brightness still registers.
    @inline(__always)
    func bandStep(boundary: Int, along: Int) -> (low: SIMD3<Float>, high: SIMD3<Float>, magnitude: Float, signedLuma: Float) {
        let band = options.bandWidth
        let gap = options.guardGap
        let low = bandMean(row: along, from: boundary - gap - band, count: band)
        let high = bandMean(row: along, from: boundary + gap, count: band)
        let d = high - low
        let magnitude = (d.x * d.x + d.y * d.y + d.z * d.z).squareRoot() * 0.577_350_3
        let signedLuma = 0.2126 * d.x + 0.7152 * d.y + 0.0722 * d.z
        return (low, high, magnitude, signedLuma)
    }

    /// Single-sample colour difference across the boundary — the sharp, unaveraged measurement
    /// that says *where* rather than *whether*.
    @inline(__always)
    func fineStep(boundary: Int, along: Int) -> Float {
        let d = sample(x: boundary, y: along) - sample(x: boundary - 1, y: along)
        return (d.x * d.x + d.y * d.y + d.z * d.z).squareRoot() * 0.577_350_3
    }

    /// Do the two sides stay apart as we walk away from the boundary?
    ///
    /// Samples are ranked along the *step's own colour axis* — the direction from the outer band
    /// mean to the inner one — rather than by brightness. Ordering by luma would work for a white
    /// canvas and fail completely for a rust-coloured panel on mid-grey, where the two sides are
    /// obviously different colours and almost exactly as bright; projecting onto the measured
    /// direction makes the comparison meaningful whichever way the step actually points, and by
    /// construction the high side ranks above the low side.
    ///
    /// The comparison is third-from-the-end against third-from-the-end rather than min against
    /// max, so a hairline, a text baseline or two noisy samples on either run cannot veto a real
    /// boundary — but a run that genuinely interleaves with the other, which is what every
    /// periodic texture produces, cannot pass at all.
    @inline(__always)
    func profilesSeparate(boundary: Int, along: Int, low: SIMD3<Float>, high: SIMD3<Float>) -> Bool {
        let d = high - low
        let norm = (d.x * d.x + d.y * d.y + d.z * d.z).squareRoot()
        guard norm > 1e-6 else { return false }
        // Scaled so a projected difference is on the same 0...1 scale as `bandStep.magnitude`.
        let axis = d / norm * 0.577_350_3

        let gap = options.guardGap
        var lowSide = Extremes()
        var highSide = Extremes()
        for offset in 0..<options.profileDepth {
            lowSide.add(projection(x: boundary - 1 - gap - offset, y: along, onto: axis))
            highSide.add(projection(x: boundary + gap + offset, y: along, onto: axis))
        }
        return highSide.thirdSmallest - lowSide.thirdLargest >= options.separationMargin
    }

    @inline(__always)
    func projection(x: Int, y: Int, onto axis: SIMD3<Float>) -> Float {
        let s = sample(x: x, y: y)
        return s.x * axis.x + s.y * axis.y + s.z * axis.z
    }

    @inline(__always)
    func bandMean(row: Int, from x0: Int, count: Int) -> SIMD3<Float> {
        var sum = SIMD3<Float>(repeating: 0)
        var i = (row * width + x0) * PixelField.bytesPerSample
        for _ in 0..<count {
            sum += SIMD3<Float>(Float(bytes[i]), Float(bytes[i + 1]), Float(bytes[i + 2]))
            i += PixelField.bytesPerSample
        }
        return sum / (255 * Float(count))
    }

    @inline(__always)
    func sample(x: Int, y: Int) -> SIMD3<Float> {
        let i = (y * width + x) * PixelField.bytesPerSample
        return SIMD3<Float>(Float(bytes[i]), Float(bytes[i + 1]), Float(bytes[i + 2])) / 255
    }

    @inline(__always)
    func luma(x: Int, y: Int) -> Float {
        let i = (y * width + x) * PixelField.bytesPerSample
        return (0.2126 * Float(bytes[i]) + 0.7152 * Float(bytes[i + 1]) + 0.0722 * Float(bytes[i + 2])) / 255
    }
}

/// Third-smallest and third-largest of a short run, tracked in one pass without allocating.
///
/// Order statistics rather than a mean: the question the separation test asks is whether the two
/// runs *interleave*, and a mean cannot answer that. Discarding two values from each end is what
/// keeps a cursor, a hairline or a noise spike from deciding it.
private struct Extremes {
    private var smallest = (Float.infinity, Float.infinity, Float.infinity)
    private var largest = (-Float.infinity, -Float.infinity, -Float.infinity)

    @inline(__always)
    mutating func add(_ value: Float) {
        if value < smallest.0 {
            smallest = (value, smallest.0, smallest.1)
        } else if value < smallest.1 {
            smallest = (smallest.0, value, smallest.1)
        } else if value < smallest.2 {
            smallest.2 = value
        }

        if value > largest.0 {
            largest = (value, largest.0, largest.1)
        } else if value > largest.1 {
            largest = (largest.0, value, largest.1)
        } else if value > largest.2 {
            largest.2 = value
        }
    }

    var thirdSmallest: Float { smallest.2 }
    var thirdLargest: Float { largest.2 }
}

// MARK: - Integer rectangle

/// Half-open in both axes: `x0..<x1`, `y0..<y1`, which is also how the boundary indices read —
/// `x0` is the boundary the rectangle starts at and `x1` the one it stops at.
private struct IntRect: Hashable {
    let x0: Int
    let x1: Int
    let y0: Int
    let y1: Int

    var width: Int { x1 - x0 }
    var height: Int { y1 - y0 }
    var cgRect: CGRect { CGRect(x: x0, y: y0, width: width, height: height) }
}

private extension VisualRegionDetector.Candidate {
    /// Bring a candidate found in the transposed field back into the original's coordinates.
    var swappingAxes: VisualRegionDetector.Candidate {
        VisualRegionDetector.Candidate(
            rect: CGRect(x: rect.minY, y: rect.minX, width: rect.height, height: rect.width),
            confidence: confidence,
            interiorIsBrighter: interiorIsBrighter,
            edgeSupport: edgeSupport,
            contrast: contrast
        )
    }
}
