import AppKit
import CaptureCore
import CoreGraphics
import ExportCore
import Foundation
import TriCapKit

/// `TriCap --benchmark-recording <dir> [--fps N] [--long-edge N] [--seconds N] [--runs N]
///                                     [--quality N] [--method N]`
///
/// The **real** counterpart to `--benchmark-export`. The synthetic benchmark proves what the
/// encoder can do with frames handed to it on a platter; it cannot prove anything about
/// ScreenCaptureKit's delivery scheduling, the capture thread's synchronous CGImage→PNG work in
/// `RegionRecorder`, or how the live pre-encoder behaves when all of that shares one machine.
/// This tool records the actual screen through the full production path — `RegionRecorder` with
/// `onFrameAccepted` feeding a `LivePreEncoder`, exactly as `AppDelegate.recordClip` wires it —
/// while an on-screen driver keeps most of the captured region changing every frame.
///
/// Honesty rules, inherited from the selftest:
/// - Run under `caffeinate -dimsu`. If the display is not compositing live (two stills either
///   side of a deliberate change are byte-identical), the run is reported as **SKIPPED** and the
///   process exits 2 — numbers from a frozen composite would be fiction.
/// - Every metric the release-plan gates need is printed per run and as a median: dropped frames,
///   encode p50/p95, peak backlog vs limit, abandonment, drain + export tail latency, retained
///   PNG bytes, output file size.
@MainActor
enum RecordingBenchmark {

    static let flag = "--benchmark-recording"

    static func runIfRequested(arguments: [String]) -> Bool {
        guard let index = arguments.firstIndex(of: flag) else { return false }
        let directory = index + 1 < arguments.count && !arguments[index + 1].hasPrefix("--")
            ? URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
            : FileManager.default.temporaryDirectory.appendingPathComponent("tricap-recording-benchmark")

        let fps = (intArgument("--fps", in: arguments) ?? 12).clamped(to: RecordingLimits.frameRateRange)
        let longEdge = (intArgument("--long-edge", in: arguments) ?? 1440)
            .clamped(to: RecordingLimits.longEdgeRange)
        let seconds = TimeInterval(intArgument("--seconds", in: arguments) ?? 15)
            .clamped(to: RecordingLimits.durationRange)
        let runs = intArgument("--runs", in: arguments) ?? 3
        let options = AnimatedWebPOptions(
            quality: intArgument("--quality", in: arguments) ?? AnimatedWebPOptions().quality,
            method: intArgument("--method", in: arguments) ?? AnimatedWebPOptions().method
        )

        Task { @MainActor in
            do {
                let outcome = try await run(
                    directory: directory, fps: fps, longEdge: longEdge,
                    seconds: seconds, runs: runs, options: options
                )
                exit(outcome)
            } catch {
                FileHandle.standardError.write(Data("recording benchmark failed: \(error)\n".utf8))
                exit(1)
            }
        }
        return true
    }

    private static func intArgument(_ name: String, in arguments: [String]) -> Int? {
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
        return Int(arguments[index + 1])
    }

    // MARK: - One run

    private struct RunMetrics {
        var frames = 0
        var dropped = 0
        var retainedBytes = 0
        var wallDuration: TimeInterval = 0
        var stopReason = ""
        var p50EncodeMs: Double?
        var p95EncodeMs: Double?
        var peakBacklog = 0
        var backlogLimit = 0
        var abandonment: String?
        var artifactAvailable = false
        var drainSeconds: Double = 0
        var tailSeconds: Double = 0
        var reuseDecisionWasFastPath = false
        var outputBytes = 0
    }

    private static func run(
        directory: URL, fps: Int, longEdge: Int, seconds: TimeInterval,
        runs: Int, options: AnimatedWebPOptions
    ) async throws -> Int32 {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        guard ScreenRecordingPermission.authorizationStatus() == .authorized else {
            print("SKIPPED: Screen Recording permission is not granted; a real capture is impossible.")
            return 2
        }
        let displays = DisplaySurvey.currentDisplays()
        guard let display = displays.first else {
            print("SKIPPED: no display.")
            return 2
        }

        // A region covering most of the display; the recorder downscales to `longEdge`, so the
        // *output* canvas is the size under test regardless of the physical panel.
        let bounds = display.appKitBounds.insetBy(dx: 16, dy: 40)
        guard let region = CaptureRegion(appKitGlobalRect: bounds, display: display) else {
            print("SKIPPED: could not resolve a capture region.")
            return 2
        }

        print("== Real-recording benchmark (full RegionRecorder + LivePreEncoder path)")
        print("  requested: \(fps) fps · long edge \(longEdge) px · \(Int(seconds)) s · quality \(options.quality) · method \(options.method) · runs \(runs)")

        // The driver churns most of the region so libwebp cannot coalesce its way to an easy
        // result — this is the "genuinely high-motion" content the gates are defined against.
        let driver = HighMotionDriver(region: region)
        driver.show()
        defer { driver.hide() }

        // Compositing-liveness probe, verbatim from the selftest's reasoning: a sleeping display
        // keeps serving one frozen composite and every number below would be meaningless.
        var compositingIsLive = false
        do {
            let before = try await StillCaptureService.capture(region: region)
            driver.step(3)
            try? await Task.sleep(nanoseconds: 400_000_000)
            let after = try await StillCaptureService.capture(region: region)
            compositingIsLive = ImageProcessing.pngData(from: before.image)
                != ImageProcessing.pngData(from: after.image)
        } catch {
            compositingIsLive = false
        }
        guard compositingIsLive else {
            print("SKIPPED: the screen is not compositing live (two stills around a deliberate")
            print("         change are byte-identical). Re-run under `caffeinate -dimsu` with the")
            print("         display awake. No numbers are reported from a frozen composite.")
            return 2
        }

        var all: [RunMetrics] = []
        for runIndex in 1...runs {
            let metrics = try await singleRun(
                region: region, fps: fps, longEdge: longEdge, seconds: seconds,
                options: options, directory: directory, label: "run\(runIndex)"
            )
            all.append(metrics)
            report(metrics, label: "run \(runIndex)")
        }

        print("\n  -- medians over \(runs) run(s) --")
        func med(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
        print(String(format: "    frames %d · dropped %d (max) · encode p95 %@ ms · peak backlog %d/%d (max) · tail %.2f s · retained %d MB (max) · output %d KB",
                     Int(med(all.map { Double($0.frames) })),
                     all.map(\.dropped).max() ?? 0,
                     all.compactMap(\.p95EncodeMs).max().map { String(format: "%.1f", $0) } ?? "—",
                     all.map(\.peakBacklog).max() ?? 0,
                     all.first?.backlogLimit ?? 0,
                     med(all.map(\.tailSeconds)),
                     (all.map(\.retainedBytes).max() ?? 0) / 1_048_576,
                     Int(med(all.map { Double($0.outputBytes) })) / 1024))
        let abandoned = all.compactMap(\.abandonment)
        print("    abandonments: \(abandoned.isEmpty ? "none" : abandoned.joined(separator: " | "))")
        print("    fast path used: \(all.filter(\.reuseDecisionWasFastPath).count)/\(runs) run(s)")
        return 0
    }

    private static func singleRun(
        region: CaptureRegion, fps: Int, longEdge: Int, seconds: TimeInterval,
        options: AnimatedWebPOptions, directory: URL, label: String
    ) async throws -> RunMetrics {
        var metrics = RunMetrics()
        let limits = RecordingLimits(frameRate: fps, maxDuration: seconds, maxLongEdgePixels: longEdge)
        let recorder = RegionRecorder(region: region, limits: limits)

        // Wired exactly as AppDelegate.recordClip does it.
        let preEncoder = LivePreEncoder(
            canvasSize: recorder.pixelSize, options: options, frameRate: limits.frameRate
        )
        recorder.onFrameAccepted = { [weak preEncoder] image, timestamp in
            preEncoder?.submit(image: image, captureTimestamp: timestamp)
        }

        try await recorder.start()
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        let clip = try await recorder.finish()

        metrics.frames = clip.frames.count
        metrics.dropped = clip.droppedFrameCount
        metrics.retainedBytes = clip.retainedBytes
        metrics.wallDuration = clip.wallClockDuration
        metrics.stopReason = clip.stopReason.rawValue

        // Drain: how long finish() blocks waiting for the queue — the pre-encode share of the tail.
        let timeline = ClipTiming.timeline(
            for: clip.frames, nominalFrameInterval: clip.nominalFrameInterval,
            totalDuration: clip.duration
        )
        let drainStart = ContinuousClock.now
        let artifact = timeline.flatMap { preEncoder.finish(endTimestampMs: $0.endTimestampMs) }
        metrics.drainSeconds = ExportBenchmark.elapsed(since: drainStart)

        let diag = preEncoder.diagnostics
        metrics.p50EncodeMs = diag.p50EncodeMs
        metrics.p95EncodeMs = diag.p95EncodeMs
        metrics.peakBacklog = diag.peakBacklog
        metrics.backlogLimit = diag.backlogLimit
        metrics.abandonment = diag.abandonment?.reason
        metrics.artifactAvailable = artifact != nil

        // The full "click Export" tail, exactly as the editor performs it.
        guard let timeline else { return metrics }
        let source = AnimationFrameSource(
            frameCount: clip.frames.count,
            timestampsMs: timeline.timestampsMs,
            endTimestampMs: timeline.endTimestampMs,
            canvasSize: clip.pixelSize
        ) { index in
            guard let image = clip.frames[index].decodedImage() else {
                throw TriCapError.encodingFailed("frame \(index) could not be decoded")
            }
            return image
        }
        let tailStart = ContinuousClock.now
        let result = try ExportService.exportAnimation(
            source: source, annotations: [], options: options,
            directory: directory, baseName: label, vaultRoot: nil, linkStyle: .markdown,
            preEncoded: artifact
        )
        metrics.tailSeconds = ExportBenchmark.elapsed(since: tailStart)
        metrics.reuseDecisionWasFastPath = artifact != nil
        metrics.outputBytes = result.byteCount
        try? FileManager.default.removeItem(at: result.url)
        return metrics
    }

    private static func report(_ m: RunMetrics, label: String) {
        let p50 = m.p50EncodeMs.map { String(format: "%.1f", $0) } ?? "—"
        let p95 = m.p95EncodeMs.map { String(format: "%.1f", $0) } ?? "—"
        print("""
          \(label): \(m.frames) frames (\(String(format: "%.2f", m.wallDuration)) s, stop=\(m.stopReason)) · dropped \(m.dropped) \
        · retained \(m.retainedBytes / 1_048_576) MB PNG
            encode p50 \(p50) / p95 \(p95) ms · peak backlog \(m.peakBacklog)/\(m.backlogLimit) \
        · abandonment: \(m.abandonment ?? "none")
            drain \(String(format: "%.2f", m.drainSeconds)) s · export tail \(String(format: "%.2f", m.tailSeconds)) s \
        (\(m.reuseDecisionWasFastPath ? "fast path" : "SLOW PATH")) · output \(m.outputBytes / 1024) KB
        """)
    }
}

/// Fills the captured region with content that changes almost everywhere, every frame: a
/// hue-cycling background plus four large orbiting blocks, driven at 60 Hz by layer property
/// changes (cheap for the window server, expensive for the encoder — which is the point).
@MainActor
private final class HighMotionDriver {
    private let window: NSWindow
    private let background: NSView
    private var blocks: [NSView] = []
    private var timer: Timer?
    private var frameIndex = 0
    private let regionRect: CGRect

    init(region: CaptureRegion) {
        regionRect = region.appKitGlobalRect
        window = NSWindow(
            contentRect: regionRect, styleMask: .borderless, backing: .buffered, defer: false
        )
        window.isOpaque = true
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.level = .floating
        background = NSView(frame: NSRect(origin: .zero, size: regionRect.size))
        background.wantsLayer = true
        window.contentView = background

        for i in 0..<4 {
            let size = CGSize(width: regionRect.width * 0.4, height: regionRect.height * 0.4)
            let block = NSView(frame: NSRect(origin: .zero, size: size))
            block.wantsLayer = true
            block.layer?.backgroundColor = NSColor(
                hue: CGFloat(i) / 4, saturation: 0.85, brightness: 0.9, alpha: 1
            ).cgColor
            background.addSubview(block)
            blocks.append(block)
        }
    }

    func show() {
        window.orderFrontRegardless()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func step(_ times: Int = 1) {
        for _ in 0..<max(1, times) { tick() }
    }

    private func tick() {
        frameIndex += 1
        let t = CGFloat(frameIndex) / 60.0
        background.layer?.backgroundColor = NSColor(
            hue: (t * 0.21).truncatingRemainder(dividingBy: 1), saturation: 0.7, brightness: 0.55, alpha: 1
        ).cgColor
        for (i, block) in blocks.enumerated() {
            let phase = t * (0.8 + CGFloat(i) * 0.35) + CGFloat(i) * .pi / 2
            block.setFrameOrigin(CGPoint(
                x: (regionRect.width - block.frame.width) * (0.5 + 0.5 * cos(phase)),
                y: (regionRect.height - block.frame.height) * (0.5 + 0.5 * sin(phase * 1.3))
            ))
            block.layer?.backgroundColor = NSColor(
                hue: (t * 0.4 + CGFloat(i) / 4).truncatingRemainder(dividingBy: 1),
                saturation: 0.9, brightness: 0.95, alpha: 1
            ).cgColor
        }
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        window.orderOut(nil)
        window.close()
    }
}
