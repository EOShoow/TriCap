import AppKit
import CaptureCore
import CoreGraphics
import ExportCore
import Foundation
import TriCapKit

/// `TriCap --benchmark-export <directory> [--frames N] [--runs N]`
///
/// Measures the two numbers that matter separately, because they trade against each other:
///
/// - **Tail latency** — from "the user clicked Export" to "the file is written and verified".
///   This is the wait the user actually experiences, and what pre-encoding is meant to remove.
/// - **In-recording cost** — the per-frame work added while capture is running. Pre-encoding
///   moves work *into* the recording, so a tail-latency win that drops frames is not a win.
///
/// The material is synthesised rather than screen-captured, and the report says so. That is a
/// deliberate trade: a real screen recording on this machine is not reproducible (the display can
/// stop compositing, and the content differs run to run), while what governs encoder cost is
/// **frame entropy**, which a generator can hold constant. The frames here are built to defeat
/// libwebp's frame coalescing completely — every frame differs from its predecessor across the
/// whole canvas — which is the *worst* case and the one real video-like content approaches.
@MainActor
enum ExportBenchmark {

    static let flag = "--benchmark-export"

    static func runIfRequested(arguments: [String]) -> Bool {
        guard let index = arguments.firstIndex(of: flag) else { return false }
        let directory = index + 1 < arguments.count && !arguments[index + 1].hasPrefix("--")
            ? URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
            : FileManager.default.temporaryDirectory.appendingPathComponent("tricap-benchmark")

        let frames = intArgument("--frames", in: arguments) ?? 181     // 12 fps × 15 s + 1
        let runs = intArgument("--runs", in: arguments) ?? 3
        let width = intArgument("--width", in: arguments) ?? 1440
        let height = intArgument("--height", in: arguments) ?? 900

        Task { @MainActor in
            do {
                try run(directory: directory, frameCount: frames, runs: runs,
                        canvas: CGSize(width: width, height: height))
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("benchmark failed: \(error)\n".utf8))
                exit(1)
            }
        }
        return true
    }

    private static func intArgument(_ name: String, in arguments: [String]) -> Int? {
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
        return Int(arguments[index + 1])
    }

    // MARK: - Material

    /// One frame of synthetic screen-like content at `index`.
    ///
    /// Deliberately high-entropy and *fully* different every frame: a scrolling gradient, moving
    /// blocks, text-like rows and a per-frame noise field. If any of this were static, libwebp
    /// would coalesce it and the benchmark would measure the easy case.
    static func syntheticFrame(index: Int, size: CGSize) -> CGImage? {
        let width = Int(size.width)
        let height = Int(size.height)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }

        let t = CGFloat(index)

        // A scrolling background gradient — every pixel changes every frame.
        if let gradient = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            colors: [
                CGColor(srgbRed: 0.10 + 0.4 * abs(sin(t * 0.11)), green: 0.16, blue: 0.30, alpha: 1),
                CGColor(srgbRed: 0.05, green: 0.22 + 0.4 * abs(cos(t * 0.07)), blue: 0.55, alpha: 1),
            ] as CFArray,
            locations: [0, 1]
        ) {
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: CGFloat(index % 40) * 6, y: 0),
                end: CGPoint(x: size.width, y: size.height),
                options: []
            )
        }

        // Text-like rows: the dominant content of a real screen recording.
        context.setFillColor(CGColor(srgbRed: 0.92, green: 0.93, blue: 0.96, alpha: 1))
        var y = size.height - 60 + CGFloat((index * 7) % 24)
        var seed = UInt64(index &* 2_654_435_761)
        func nextRandom() -> UInt64 {
            seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
            return seed
        }
        while y > 40 {
            var x: CGFloat = 60
            while x < size.width - 80 {
                let wordWidth = CGFloat(nextRandom() % 70) + 18
                context.fill(CGRect(x: x, y: y, width: wordWidth, height: 9))
                x += wordWidth + CGFloat(nextRandom() % 14) + 6
            }
            y -= 22
        }

        // A few moving solid blocks — windows, images, a video pane.
        let blocks: [(CGColor, CGFloat)] = [
            (CGColor(srgbRed: 0.95, green: 0.72, blue: 0.20, alpha: 1), 0.9),
            (CGColor(srgbRed: 0.90, green: 0.30, blue: 0.28, alpha: 1), 1.4),
            (CGColor(srgbRed: 0.25, green: 0.72, blue: 0.45, alpha: 1), 0.6),
        ]
        for (offset, block) in blocks.enumerated() {
            let phase = t * block.1 * 0.06 + CGFloat(offset)
            let rect = CGRect(
                x: size.width * 0.5 + cos(phase) * size.width * 0.32 - 110,
                y: size.height * 0.5 + sin(phase * 1.3) * size.height * 0.30 - 80,
                width: 220, height: 160
            )
            context.setFillColor(block.0)
            context.fill(rect)
        }

        // Fine per-frame noise, so no macroblock is ever identical between frames.
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.10))
        for _ in 0..<1200 {
            let px = CGFloat(nextRandom() % UInt64(width))
            let py = CGFloat(nextRandom() % UInt64(height))
            context.fill(CGRect(x: px, y: py, width: 2, height: 2))
        }

        return context.makeImage()
    }

    /// One simulated recording, paced at the real capture interval.
    ///
    /// Pacing is the whole point. An earlier version submitted frames as fast as it could build
    /// them, which left the pre-encoder no wall-clock time to work in and made the fast path look
    /// worthless. A real recording delivers a frame every `1/fps` seconds, and the question that
    /// matters is whether encoding fits in that gap.
    ///
    /// Returns how late each frame was, which is the in-recording cost: a frame that cannot be
    /// handled within its interval is a frame the real recorder would drop.
    struct RecordingRun {
        var clip: RecordedClip
        var worstLatenessMs: Double
        var lateFrames: Int
        var submitSeconds: Double
    }

    static func simulateRecording(
        pngs: [Data],
        canvas: CGSize,
        frameRate: Int,
        preEncoder: LivePreEncoder?
    ) -> RecordingRun {
        let interval = 1.0 / Double(frameRate)
        var frames: [RecordedFrame] = []
        frames.reserveCapacity(pngs.count)

        var worstLatenessMs = 0.0
        var lateFrames = 0
        var submitSeconds = 0.0
        let start = ContinuousClock.now

        for (index, png) in pngs.enumerated() {
            // Wait for this frame's delivery slot, as ScreenCaptureKit would.
            let due = Double(index) * interval
            while elapsed(since: start) < due {
                usleep(200)
            }
            let lateness = (elapsed(since: start) - due) * 1000
            worstLatenessMs = max(worstLatenessMs, lateness)
            if lateness > interval * 1000 { lateFrames += 1 }

            guard let image = ImageProcessing.image(fromPNG: png) else { continue }
            let submitStart = ContinuousClock.now
            preEncoder?.submit(image: image, captureTimestamp: due)
            submitSeconds += elapsed(since: submitStart)

            frames.append(RecordedFrame(pngData: png, timestamp: due))
        }

        let clip = RecordedClip(
            frames: frames,
            pixelSize: canvas,
            region: syntheticRegion(canvas: canvas),
            nominalFrameInterval: interval,
            stopReason: .userStopped,
            droppedFrameCount: 0,
            colorSpace: nil,
            retainedBytes: frames.reduce(0) { $0 + $1.pngData.count },
            wallClockDuration: Double(frames.count) * interval
        )
        return RecordingRun(
            clip: clip, worstLatenessMs: worstLatenessMs,
            lateFrames: lateFrames, submitSeconds: submitSeconds
        )
    }

    private static func syntheticRegion(canvas: CGSize) -> CaptureRegion {
        let display = DisplayGeometry(
            displayID: 1,
            appKitBounds: CGRect(origin: .zero, size: canvas),
            quartzBounds: CGRect(origin: .zero, size: canvas),
            pointPixelScale: 1,
            primaryHeightInPoints: canvas.height
        )
        return CaptureRegion(
            appKitGlobalRect: CGRect(origin: .zero, size: canvas),
            display: display
        )!
    }

    static func elapsed(since start: ContinuousClock.Instant) -> Double {
        Double((ContinuousClock.now - start).components.attoseconds) / 1e18
            + Double((ContinuousClock.now - start).components.seconds)
    }

    // MARK: - Runs

    /// Where the export time actually goes, per frame.
    ///
    /// Written before any optimisation, because "the export is slow" has at least four candidate
    /// causes — PNG decode, pixel extraction, `WebPAnimEncoderAdd`, and the final assemble — and
    /// guessing which one dominates is how you optimise the wrong thing.
    static func profile(
        frameCount: Int,
        canvas: CGSize,
        options: AnimatedWebPOptions,
        strategy: AnimationEncodeStrategy = .default
    ) {
        let interval = 1.0 / 12.0
        var pngs: [Data] = []
        for index in 0..<frameCount {
            if let image = syntheticFrame(index: index, size: canvas),
               let png = ImageProcessing.pngData(from: image) {
                pngs.append(png)
            }
        }

        var decodeSeconds = 0.0
        var rasterSeconds = 0.0
        var addSeconds = 0.0
        var images: [CGImage] = []
        for png in pngs {
            let start = ContinuousClock.now
            guard let image = ImageProcessing.image(fromPNG: png) else { continue }
            decodeSeconds += elapsed(since: start)
            images.append(image)
        }
        for image in images {
            let start = ContinuousClock.now
            _ = ImageProcessing.rgbxBytes(image)
            rasterSeconds += elapsed(since: start)
        }

        guard let session = try? WebPAnimEncoderSession(canvasSize: canvas, options: options, strategy: strategy) else { return }
        for (index, image) in images.enumerated() {
            let start = ContinuousClock.now
            _ = session.add(image: image, timestampMs: Int((Double(index) * interval * 1000).rounded()))
            addSeconds += elapsed(since: start)
        }
        let assembleStart = ContinuousClock.now
        let data = session.finish(endTimestampMs: Int((Double(images.count) * interval * 1000).rounded()))
        let assembleSeconds = elapsed(since: assembleStart)

        let n = Double(max(1, images.count))
        print("  -- per-frame cost breakdown (\(images.count) frames at \(Int(canvas.width))×\(Int(canvas.height))) --")
        print(String(format: "    PNG decode        %7.1f ms/frame   (%.2f s total)", decodeSeconds / n * 1000, decodeSeconds))
        print(String(format: "    RGBX extraction   %7.1f ms/frame   (%.2f s total)", rasterSeconds / n * 1000, rasterSeconds))
        print(String(format: "    WebPAnimEncoderAdd%7.1f ms/frame   (%.2f s total)  <- dominates",
                     addSeconds / n * 1000, addSeconds))
        print(String(format: "    assemble          %7.1f ms total    (%d KB)",
                     assembleSeconds * 1000, (data?.count ?? 0) / 1024))
        print(String(format: "    capture interval  %7.1f ms/frame at 12 fps", interval * 1000))
        let realtimeRatio = (addSeconds / n) / interval
        print(String(format: "    encode is %.1f× the capture interval — pre-encoding %@ keep up",
                     realtimeRatio, realtimeRatio < 1 ? "CAN" : "CANNOT"))
        print("")
    }

    private static func run(directory: URL, frameCount: Int, runs: Int, canvas: CGSize) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let options = AnimatedWebPOptions()
        let frameRate = 12

        print("== Animated WebP export benchmark")
        print("  canvas \(Int(canvas.width))×\(Int(canvas.height)) · \(frameRate) fps · \(frameCount) frames"
              + " · quality \(options.quality) · method \(options.method) · lossless \(options.lossless)")
        print("  material: synthetic, every frame fully different (defeats frame coalescing)")
        print("  recording is paced at the real \(String(format: "%.1f", 1000.0 / Double(frameRate))) ms frame interval")
        print("  runs: \(runs) (median reported)\n")

        for (name, strategy) in [("thorough (shipped through 79d20b3)", AnimationEncodeStrategy.thorough),
                                 ("balanced (minimize_size=0, allow_mixed=0)", AnimationEncodeStrategy.balanced)] {
            print("  strategy: \(name)")
            profile(frameCount: min(frameCount, 24), canvas: canvas, options: options, strategy: strategy)
        }

        // Build the material once. Generation is not part of any measurement.
        print("  building \(frameCount) synthetic frames…")
        var pngs: [Data] = []
        pngs.reserveCapacity(frameCount)
        for index in 0..<frameCount {
            if let image = syntheticFrame(index: index, size: canvas),
               let png = ImageProcessing.pngData(from: image) {
                pngs.append(png)
            }
        }
        print("  \(pngs.count) frames, \(pngs.reduce(0) { $0 + $1.count } / 1_048_576) MB of PNG\n")

        /// The three configurations, in the order they were arrived at.
        enum Arm: String, CaseIterable {
            case baseline = "A  thorough, no pre-encode  (the 79d20b3 baseline)"
            case fasterStrategy = "B  balanced, no pre-encode"
            case preEncoded = "C  balanced + live pre-encode"

            var strategy: AnimationEncodeStrategy {
                self == .baseline ? .thorough : .balanced
            }
            var usesPreEncoder: Bool { self == .preEncoded }
        }

        var tails: [Arm: [Double]] = [:]
        var lateness: [Arm: [Double]] = [:]
        var lateCounts: [Arm: [Int]] = [:]
        var sizes: [Arm: Int] = [:]
        var preEncodeStatus = "—"

        for run in 1...runs {
            for arm in Arm.allCases {
                autoreleasepool {
                    let preEncoder = arm.usesPreEncoder
                        ? LivePreEncoder(canvasSize: canvas, options: options,
                                         frameRate: frameRate, strategy: arm.strategy)
                        : nil

                    let recording = simulateRecording(
                        pngs: pngs, canvas: canvas, frameRate: frameRate, preEncoder: preEncoder
                    )
                    lateness[arm, default: []].append(recording.worstLatenessMs)
                    lateCounts[arm, default: []].append(recording.lateFrames)

                    // The clock the user experiences: it starts when they click Export.
                    let start = ContinuousClock.now
                    let artifact = preEncoder?.finish(
                        endTimestampMs: Int((Double(pngs.count) / Double(frameRate) * 1000).rounded())
                    )
                    if arm.usesPreEncoder {
                        preEncodeStatus = artifact == nil
                            ? "unavailable (\(preEncoder?.abandonedBecause?.reason ?? "unknown"))"
                            : "available, \(artifact!.frameCount) frames"
                    }
                    if let result = try? exportFully(
                        clip: recording.clip, options: options, directory: directory,
                        baseName: "\(arm.hashValue)-\(run)", preEncoded: artifact, strategy: arm.strategy
                    ) {
                        tails[arm, default: []].append(elapsed(since: start))
                        sizes[arm] = result.byteCount
                        try? FileManager.default.removeItem(at: result.url)
                    }
                }
            }
            print("  run \(run) complete")
        }

        print("\n  -- tail latency: Export click → written and verified --")
        let baselineMedian = median(tails[.baseline] ?? [])
        for arm in Arm.allCases {
            let values = tails[arm] ?? []
            let m = median(values)
            var line = "    \(arm.rawValue.padding(toLength: 46, withPad: " ", startingAt: 0)) median \(fmt(m))"
            if let m, let base = baselineMedian, base > 0, arm != .baseline {
                line += String(format: "   (%.1f%% faster than A)", (base - m) / base * 100)
            }
            print(line + "   [" + values.map { fmt($0) }.joined(separator: ", ") + "]")
        }

        print("\n  -- in-recording cost: how late each frame was against its delivery slot --")
        for arm in Arm.allCases {
            let worst = median(lateness[arm] ?? []) ?? 0
            let late = lateCounts[arm]?.max() ?? 0
            print(String(format: "    %@ worst %.1f ms, %d frame(s) later than one interval",
                         arm.rawValue.padding(toLength: 46, withPad: " ", startingAt: 0), worst, late))
        }
        print("    (a frame later than one interval is one a real recorder would have dropped)")

        print("\n  -- output size --")
        for arm in Arm.allCases {
            guard let bytes = sizes[arm] else { continue }
            var line = "    \(arm.rawValue.padding(toLength: 46, withPad: " ", startingAt: 0)) \(bytes / 1024) KB"
            if let base = sizes[.baseline], base > 0, arm != .baseline {
                line += String(format: "   (%+.1f%% vs A)", Double(bytes - base) / Double(base) * 100)
            }
            print(line)
        }
        print("\n  pre-encode: \(preEncodeStatus)")
    }

    /// The complete "click Export" path: encode, write, re-read, verify.
    private static func exportFully(
        clip: RecordedClip,
        options: AnimatedWebPOptions,
        directory: URL,
        baseName: String,
        preEncoded: PreEncodedAnimation?,
        strategy: AnimationEncodeStrategy
    ) throws -> ExportResult {
        guard let timeline = ClipTiming.timeline(
            for: clip.frames,
            nominalFrameInterval: clip.nominalFrameInterval,
            totalDuration: clip.duration
        ) else { throw TriCapError.noFramesCaptured }

        let source = AnimationFrameSource(
            frameCount: clip.frames.count,
            timestampsMs: timeline.timestampsMs,
            endTimestampMs: timeline.endTimestampMs,
            canvasSize: clip.pixelSize
        ) { index in
            guard let image = clip.frames[index].decodedImage() else {
                throw TriCapError.encodingFailed("Frame \(index) could not be decoded.")
            }
            return image
        }

        return try ExportService.exportAnimation(
            source: source,
            annotations: [],
            options: options,
            directory: directory,
            baseName: baseName,
            vaultRoot: nil,
            linkStyle: .markdown,
            preEncoded: preEncoded,
            strategy: strategy
        )
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    private static func fmt(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.3f s", value)
    }
}
