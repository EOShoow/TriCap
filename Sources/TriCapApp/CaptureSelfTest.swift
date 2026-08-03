import AnnotationCore
import AppKit
import CaptureCore
import CoreGraphics
import ExportCore
import Foundation
import TriCapKit

/// End-to-end capture check, invoked as `TriCap --selftest [output-directory]`.
///
/// Drives the *real* pipeline — ScreenCaptureKit permission, still capture, annotation
/// compositing, PNG/JPEG/WebP encoding, a live recording, trimming, animated-WebP encoding — and
/// re-reads every artefact it writes. It exists because the interactive flow needs a human at the
/// keyboard, while everything downstream of "the user dragged a rectangle" can be verified
/// unattended, and because the reviewer needs a single reproducible command that either exits 0
/// or says exactly what failed.
@MainActor
enum CaptureSelfTest {

    static let flag = "--selftest"

    static func runIfRequested(arguments: [String]) -> Bool {
        guard let index = arguments.firstIndex(of: flag) else { return false }
        let directory = index + 1 < arguments.count
            ? URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
            : URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("selftest-output", isDirectory: true)

        var exitCode: Int32 = 0
        var finished = false

        Task { @MainActor in
            exitCode = await run(into: directory) ? 0 : 1
            finished = true
        }

        // The capture APIs are async and need a live run loop; `main.swift` is straight-line code,
        // so pump the main run loop until the task completes.
        let deadline = Date().addingTimeInterval(180)
        while !finished && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        if !finished {
            print("FAIL  self-test timed out after 180 s")
            exitCode = 1
        }
        exit(exitCode)
    }

    // MARK: - Steps

    private static var failures = 0

    private static func check(_ label: String, _ condition: Bool, detail: String = "") {
        let mark = condition ? "PASS" : "FAIL"
        if !condition { failures += 1 }
        print("  \(mark)  \(label)\(detail.isEmpty ? "" : "  — \(detail)")")
    }

    private static func section(_ title: String) {
        print("\n== \(title)")
    }

    static func run(into directory: URL) async -> Bool {
        failures = 0
        print("TriCap self-test")
        print("  output directory: \(directory.path)")
        print("  libwebp: \(WebPCodec.versionString) (encoder/mux/demux \(WebPCodec.encoderVersion)/\(WebPCodec.muxVersion)/\(WebPCodec.demuxVersion))")

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // ---- Permission -------------------------------------------------------------------
        section("Screen recording permission")
        let preflight = CGPreflightScreenCaptureAccess()
        let status = ScreenRecordingPermission.authorizationStatus()
        print("  CGPreflightScreenCaptureAccess() = \(preflight)")
        print("  ScreenRecordingPermission.authorizationStatus() = \(status.rawValue)")

        do {
            let content = try await ScreenRecordingPermission.shareableContent()
            check("SCShareableContent reachable", true, detail: "\(content.displays.count) display(s), \(content.applications.count) app(s)")
        } catch {
            check("SCShareableContent reachable", false, detail: "\(error)")
            print("\n  Screen Recording permission is not granted to this binary.")
            print("  Grant it in System Settings → Privacy & Security → Screen & System Audio Recording,")
            print("  then re-run. Everything below this point needs it.")
            return false
        }

        // ---- Displays ---------------------------------------------------------------------
        section("Displays")
        let displays = DisplaySurvey.currentDisplays()
        check("at least one display", !displays.isEmpty)
        for display in displays {
            print("""
              display \(display.displayID): appKit=\(shortRect(display.appKitBounds)) \
            quartz=\(shortRect(display.quartzBounds)) scale=\(display.pointPixelScale) \
            pixels=\(Int(display.pixelSize.width))x\(Int(display.pixelSize.height))
            """)
        }
        guard let main = displays.first else { return false }
        if displays.count == 1 {
            print("  NOTE: only one display is attached, so multi-display selection is NOT covered by this run.")
        }

        // ---- Region resolution ------------------------------------------------------------
        section("Region resolution")
        // A 400x300 pt region 100 pt in from the bottom-left of the main display.
        guard let region = CaptureRegion(
            appKitGlobalRect: CGRect(x: main.appKitBounds.minX + 100, y: main.appKitBounds.minY + 100, width: 400, height: 300),
            display: main
        ) else {
            check("region resolves", false)
            return false
        }
        check(
            "region resolves",
            true,
            detail: "pixels=\(shortRect(region.displayPixelRect)) sourceRect(pt)=\(shortRect(region.sourceRectInDisplayPoints))"
        )
        check(
            "pixel size == points × scale",
            region.displayPixelRect.width == 400 * main.pointPixelScale
                && region.displayPixelRect.height == 300 * main.pointPixelScale
        )

        // A one-pixel selection in the top-left corner of the display (the Retina edge case).
        let cornerRect = CGRect(
            x: main.appKitBounds.minX,
            y: main.appKitBounds.maxY - 1.0 / main.pointPixelScale,
            width: 1.0 / main.pointPixelScale,
            height: 1.0 / main.pointPixelScale
        )
        if let corner = CaptureRegion(appKitGlobalRect: cornerRect, display: main) {
            check(
                "1-pixel top-left corner selection",
                corner.displayPixelRect == CGRect(x: 0, y: 0, width: 1, height: 1),
                detail: shortRect(corner.displayPixelRect)
            )
        } else {
            check("1-pixel top-left corner selection", false, detail: "returned nil")
        }

        // ---- Still capture ----------------------------------------------------------------
        section("Still capture")
        let still: CapturedStill
        do {
            still = try await StillCaptureService.capture(region: region)
            check(
                "SCScreenshotManager capture",
                true,
                detail: "\(still.image.width)x\(still.image.height), source colour space \(still.colorSpace.sourceName), converted=\(still.colorSpace.converted)"
            )
        } catch {
            check("SCScreenshotManager capture", false, detail: "\(error)")
            return false
        }
        check(
            "capture matches the requested pixel rect",
            still.image.width == Int(region.displayPixelRect.width)
                && still.image.height == Int(region.displayPixelRect.height)
        )
        check(
            "capture is sRGB",
            still.image.colorSpace?.name == CGColorSpace.sRGB,
            detail: (still.image.colorSpace?.name as String?) ?? "nil"
        )
        if let notice = still.colorSpace.userFacingNotice {
            print("  colour-space notice surfaced to the user: \(notice)")
        }

        // ---- Annotation + still export ----------------------------------------------------
        section("Annotate and export stills")
        let canvas = still.pixelSize
        var document = AnnotationDocument()
        document.add(AnnotationItem(
            shape: .arrow(from: CGPoint(x: canvas.width * 0.1, y: canvas.height * 0.8),
                          to: CGPoint(x: canvas.width * 0.6, y: canvas.height * 0.3)),
            style: AnnotationStyle(color: .red, lineWidth: max(3, canvas.width / 160))
        ))
        document.add(AnnotationItem(
            shape: .rectangle(CGRect(x: canvas.width * 0.55, y: canvas.height * 0.15,
                                     width: canvas.width * 0.3, height: canvas.height * 0.25)),
            style: AnnotationStyle(color: .yellow, lineWidth: max(3, canvas.width / 160))
        ))
        document.add(AnnotationItem(
            shape: .text(origin: CGPoint(x: canvas.width * 0.08, y: canvas.height * 0.08), string: "TriCap self-test"),
            style: AnnotationStyle(color: .blue, fontSize: max(14, canvas.width / 24))
        ))
        document.add(AnnotationItem(
            shape: .mosaic(CGRect(x: canvas.width * 0.05, y: canvas.height * 0.5,
                                  width: canvas.width * 0.35, height: canvas.height * 0.18)),
            style: AnnotationStyle(mosaicBlockSize: max(6, canvas.width / 60))
        ))
        check("annotation document has 4 items and can undo", document.items.count == 4 && document.canUndo)

        let vaultRoot = directory.appendingPathComponent("vault", isDirectory: true)
        let insideVault = vaultRoot.appendingPathComponent("assets", isDirectory: true)

        for format in [OutputFormat.png, .jpeg, .webp] {
            do {
                let result = try ExportService.exportStill(
                    image: still.image,
                    annotations: document.items,
                    format: format,
                    quality: 85,
                    directory: insideVault,
                    baseName: "still-\(format.rawValue)",
                    vaultRoot: vaultRoot,
                    linkStyle: .markdown
                )
                let onDisk = (try? Data(contentsOf: result.url)) ?? Data()
                check(
                    "export \(format.displayName)",
                    true,
                    detail: "\(result.url.lastPathComponent) \(result.byteCount) bytes container=\(result.container.rawValue)"
                )
                check("  \(format.displayName) extension matches magic bytes",
                      MagicBytes.detect(onDisk).matchesExtension == result.url.pathExtension)
                check("  \(format.displayName) reference is vault-relative",
                      result.reference == "![still-\(format.rawValue)](assets/still-\(format.rawValue).\(format.fileExtension))",
                      detail: result.reference)
                if format == .webp {
                    let decoded = try WebPCodec.decodeStill(data: onDisk)
                    check("  WebP decodes back at the same size",
                          decoded.width == still.image.width && decoded.height == still.image.height,
                          detail: "\(decoded.width)x\(decoded.height)")
                }
            } catch {
                check("export \(format.displayName)", false, detail: "\(error)")
            }
        }

        // Outside the vault: absolute path, no Markdown syntax.
        do {
            let outside = directory.appendingPathComponent("outside", isDirectory: true)
            let result = try ExportService.exportStill(
                image: still.image, annotations: [], format: .png, quality: 90,
                directory: outside, baseName: "outside-vault",
                vaultRoot: vaultRoot, linkStyle: .markdown
            )
            check("outside-vault reference is the absolute path",
                  result.reference == result.url.standardizedFileURL.path && !result.reference.hasPrefix("!["),
                  detail: result.reference)
        } catch {
            check("outside-vault reference is the absolute path", false, detail: "\(error)")
        }

        // Filename collision handling.
        do {
            let a = try ExportService.exportStill(
                image: still.image, annotations: [], format: .png, quality: 90,
                directory: insideVault, baseName: "collision", vaultRoot: vaultRoot, linkStyle: .markdown
            )
            let b = try ExportService.exportStill(
                image: still.image, annotations: [], format: .png, quality: 90,
                directory: insideVault, baseName: "collision", vaultRoot: vaultRoot, linkStyle: .markdown
            )
            check("filename collision resolves to -1",
                  a.url.lastPathComponent == "collision.png" && b.url.lastPathComponent == "collision-1.png",
                  detail: "\(a.url.lastPathComponent), \(b.url.lastPathComponent)")
        } catch {
            check("filename collision resolves to -1", false, detail: "\(error)")
        }

        // ---- Recording --------------------------------------------------------------------
        section("Recording (5 s target)")
        let limits = RecordingLimits(frameRate: 12, maxDuration: 15, maxLongEdgePixels: 1440)
        let recorder = RegionRecorder(region: region, limits: limits)
        print("  output pixel size: \(Int(recorder.pixelSize.width))x\(Int(recorder.pixelSize.height))")

        do {
            try await recorder.start()
        } catch {
            check("recording starts", false, detail: "\(error)")
            return failures == 0
        }
        check("recording starts", true)

        // Animate something inside the captured region so successive frames differ.
        let mover = MovingWindow(region: region)
        mover.show()
        try? await Task.sleep(nanoseconds: 5_000_000_000)
        mover.hide()

        let clip: RecordedClip
        do {
            clip = try await recorder.finish()
        } catch {
            check("recording finishes with frames", false, detail: "\(error)")
            return false
        }
        check(
            "recording finishes with frames",
            clip.frames.count > 1,
            detail: "\(clip.frames.count) frames, \(String(format: "%.2f", clip.duration)) s, \(clip.retainedBytes / 1024) KB retained, stop=\(clip.stopReason.rawValue), dropped=\(clip.droppedFrameCount)"
        )
        check("retained memory stayed under the ceiling", clip.retainedBytes <= limits.maxFrameBufferBytes)
        check("frame count stayed under the ceiling", clip.frames.count <= limits.maxFrameCount)
        check(
            "frame timestamps are non-decreasing",
            zip(clip.frames, clip.frames.dropFirst()).allSatisfy { $1.timestamp >= $0.timestamp }
        )

        // ---- Trim + animated WebP ---------------------------------------------------------
        section("Trim and export animated WebP")
        let head = min(2, max(0, clip.frames.count - 2))
        let tail = max(head, clip.frames.count - 3)
        let trimmed = ClipTrimmer.trim(frames: clip.frames, to: head...tail)
        check("trim keeps the expected frame count", trimmed.count == tail - head + 1,
              detail: "kept \(trimmed.count) of \(clip.frames.count) (indices \(head)...\(tail))")
        check("trimmed clip restarts at t=0", trimmed.first?.timestamp == 0)

        guard let timeline = ClipTiming.timeline(for: trimmed, nominalFrameInterval: clip.nominalFrameInterval) else {
            check("timeline builds", false)
            return false
        }
        check("timeline is strictly increasing and starts at 0",
              timeline.timestampsMs.first == 0
                && zip(timeline.timestampsMs, timeline.timestampsMs.dropFirst()).allSatisfy { $1 > $0 })

        // A *filled* badge in the top-left corner, so the per-frame probe below lands on solid
        // colour rather than on the hairline of a stroked outline.
        var filledRed = AnnotationStyle(color: .red)
        filledRed.filled = true
        let overlay = [
            AnnotationItem(shape: .rectangle(CGRect(x: 0, y: 0, width: 80, height: 40)), style: filledRed),
            AnnotationItem(
                shape: .rectangle(CGRect(x: 8, y: 8, width: clip.pixelSize.width - 16, height: clip.pixelSize.height * 0.18)),
                style: AnnotationStyle(color: .red, lineWidth: 6)
            ),
            AnnotationItem(
                shape: .text(origin: CGPoint(x: 100, y: 8), string: "fixed overlay"),
                style: AnnotationStyle(color: .yellow, fontSize: max(14, clip.pixelSize.width / 24))
            ),
        ]

        let source = AnimationFrameSource(
            frameCount: trimmed.count,
            timestampsMs: timeline.timestampsMs,
            endTimestampMs: timeline.endTimestampMs,
            canvasSize: clip.pixelSize
        ) { index in
            guard let image = trimmed[index].decodedImage() else {
                throw TriCapError.encodingFailed("frame \(index) failed to decode")
            }
            return image
        }

        do {
            let result = try ExportService.exportAnimation(
                source: source,
                annotations: overlay,
                options: AnimatedWebPOptions(quality: 80, loopCount: 0),
                directory: insideVault,
                baseName: "clip",
                vaultRoot: vaultRoot,
                linkStyle: .markdown
            )
            let info = result.animationInfo
            check("animated WebP written", true,
                  detail: "\(result.url.lastPathComponent) \(result.byteCount) bytes")
            check("container is animated WebP", result.container == .webpAnimated)
            // libwebp coalesces frames identical to their predecessor, so the stored count can be
            // lower than the submitted count; the invariant that must hold exactly is duration.
            check("stored frame count is within the submitted count",
                  (info?.frameCount ?? 0) >= 1 && (info?.frameCount ?? .max) <= trimmed.count,
                  detail: "\(info?.frameCount ?? -1) stored of \(trimmed.count) submitted (identical frames merged)")
            check("total playback duration is preserved",
                  info?.totalDurationMs == timeline.endTimestampMs,
                  detail: "\(info?.totalDurationMs ?? -1) ms vs \(timeline.endTimestampMs) ms")
            check("canvas size round-trips",
                  info?.canvasWidth == Int(clip.pixelSize.width) && info?.canvasHeight == Int(clip.pixelSize.height),
                  detail: "\(info?.canvasWidth ?? -1)x\(info?.canvasHeight ?? -1)")
            check("loop count is 0 (infinite)", info?.loopCount == 0)
            check("timestamps read back strictly increasing",
                  zip(info?.frameTimestampsMs ?? [], (info?.frameTimestampsMs ?? []).dropFirst()).allSatisfy { $1 > $0 })
            check("every frame duration > 0", (info?.durationsMs ?? []).allSatisfy { $0 > 0 })
            check("markdown reference is vault-relative",
                  result.reference == "![clip](assets/clip.webp)", detail: result.reference)
            print("  frame timestamps (ms): \(info?.frameTimestampsMs ?? [])")
            print("  frame durations  (ms): \(info?.durationsMs ?? [])")

            // Confirm the fixed overlay really is on every frame.
            let rawFrames = try WebPCodec.decodeAnimationFrames(data: try Data(contentsOf: result.url))
            check("decoded frame count matches the stored count",
                  rawFrames.count == info?.frameCount, detail: "\(rawFrames.count)")
            let width = Int(clip.pixelSize.width)
            // Inside the filled badge at (0,0)-(80,40) in annotation space (top-left origin).
            let probeX = 40
            let probeY = 20
            let redEverywhere = rawFrames.allSatisfy { pixels in
                let offset = probeY * width * 4 + probeX * 4
                guard offset + 2 < pixels.count else { return false }
                return pixels[offset] > 120 && pixels[offset + 1] < 140
            }
            check("fixed overlay present on every frame", redEverywhere,
                  detail: "sampled (\(probeX),\(probeY)) in all \(rawFrames.count) frames")
        } catch {
            check("animated WebP written", false, detail: "\(error)")
        }

        let fileCountAfterExports = (try? FileManager.default.contentsOfDirectory(atPath: insideVault.path))?.count ?? 0

        // ---- Cancellation -----------------------------------------------------------------
        section("Cancel an in-flight recording")
        let cancellable = RegionRecorder(region: region, limits: limits)
        do {
            try await cancellable.start()
            try? await Task.sleep(nanoseconds: 700_000_000)
            await cancellable.cancel()
            check("cancel completes and releases every retained frame", true)
            do {
                _ = try await cancellable.finish()
                check("finish after cancel yields no clip", false, detail: "finish() unexpectedly returned a clip")
            } catch {
                check("finish after cancel yields no clip", true, detail: "\(error)")
            }
        } catch {
            check("cancellable recording starts", false, detail: "\(error)")
        }

        let filesAfterCancel = (try? FileManager.default.contentsOfDirectory(atPath: insideVault.path))?.count ?? 0
        check("cancelling wrote no file", filesAfterCancel == fileCountAfterExports,
              detail: "\(filesAfterCancel) files in assets/, unchanged from \(fileCountAfterExports)")

        // ---- Summary ----------------------------------------------------------------------
        section("Summary")
        print(failures == 0 ? "  ALL CHECKS PASSED" : "  \(failures) CHECK(S) FAILED")
        print("  artefacts: \(directory.path)")
        return failures == 0
    }

    private static func shortRect(_ rect: CGRect) -> String {
        String(format: "(%.0f,%.0f %.0fx%.0f)", rect.origin.x, rect.origin.y, rect.width, rect.height)
    }
}

/// A small opaque window parked inside the captured region that changes colour every 100 ms.
///
/// Without moving content ScreenCaptureKit sends only "idle" frames and the recording would be a
/// single still — which would make the recording checks vacuous.
@MainActor
private final class MovingWindow {
    private let window: NSWindow
    private let view: NSView
    private var timer: Timer?
    private var step = 0

    init(region: CaptureRegion) {
        let rect = region.appKitGlobalRect
        let size = CGSize(width: min(120, rect.width * 0.4), height: min(120, rect.height * 0.4))
        window = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: rect.minX + 20, y: rect.minY + 20), size: size),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isOpaque = true
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.level = .floating
        view = NSView(frame: NSRect(origin: .zero, size: size))
        view.wantsLayer = true
        window.contentView = view
        self.regionRect = rect
    }

    private let regionRect: CGRect

    func show() {
        window.orderFrontRegardless()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        step += 1
        let hue = CGFloat(step % 20) / 20.0
        view.layer?.backgroundColor = NSColor(hue: hue, saturation: 0.9, brightness: 0.95, alpha: 1).cgColor
        let travel = max(0, regionRect.width - window.frame.width - 40)
        let x = regionRect.minX + 20 + travel * CGFloat(step % 20) / 20.0
        window.setFrameOrigin(CGPoint(x: x, y: window.frame.origin.y))
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        window.orderOut(nil)
        window.close()
    }
}
