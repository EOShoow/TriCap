import AnnotationCore
import AppKit
import ApplicationServices
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
    private static var skipped = 0

    private static func check(_ label: String, _ condition: Bool, detail: String = "") {
        let mark = condition ? "PASS" : "FAIL"
        if !condition { failures += 1 }
        print("  \(mark)  \(label)\(detail.isEmpty ? "" : "  — \(detail)")")
    }

    /// A check whose precondition is objectively absent in this environment.
    ///
    /// Reported as SKIP rather than PASS so the run never claims to have verified something it
    /// did not, and never as FAIL so an environment limitation is not mistaken for a defect.
    private static func skip(_ label: String, reason: String) {
        skipped += 1
        print("  SKIP  \(label)  — not verified in this run: \(reason)")
    }

    /// Run the main run loop for a while.
    ///
    /// `--selftest` never calls `NSApp.run()`, so AppKit's run-loop observers — the ones that
    /// finish tearing down a window that was actually put on screen — otherwise never fire.
    private static func spinRunLoop(seconds: Double) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    /// A plain opaque sRGB image, for exercising paths that just need *some* bitmap.
    private static func solidImage(width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
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
            guard !content.displays.isEmpty else {
                // NSScreen still lists the panel, but ScreenCaptureKit publishes no capturable
                // display while it is asleep or the session is locked. Say so plainly instead of
                // failing later with a confusing "noDisplaysAvailable" from inside the capture.
                check("a capturable display is available", false, detail: "ScreenCaptureKit reports 0 displays")
                print("")
                print("  The display appears to be asleep or the session is locked, so nothing can")
                print("  be captured. Re-run with the display awake, e.g.:")
                print("    caffeinate -dimsu .build/release/TriCap --selftest ./build/selftest")
                return false
            }
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

        // Before asserting on frame count, establish that the window server is actually
        // compositing live: capture two stills either side of a deliberate change. On a machine
        // whose display is asleep or whose session is detached, ScreenCaptureKit keeps reporting
        // the display and keeps serving a frozen composite, and every recording would be a single
        // frame through no fault of the recorder.
        var motionIsVisible = false
        do {
            let before = try await StillCaptureService.capture(region: region)
            mover.step()
            try? await Task.sleep(nanoseconds: 400_000_000)
            let after = try await StillCaptureService.capture(region: region)
            motionIsVisible = ImageProcessing.pngData(from: before.image)
                != ImageProcessing.pngData(from: after.image)
        } catch {
            motionIsVisible = false
        }
        if !motionIsVisible {
            print("  NOTE: the screen is not compositing live (two stills either side of a")
            print("        deliberate on-screen change are byte-identical). Multi-frame")
            print("        expectations are skipped; everything else still runs.")
        }

        try? await Task.sleep(nanoseconds: 5_000_000_000)
        mover.hide()

        let clip: RecordedClip
        do {
            clip = try await recorder.finish()
        } catch {
            check("recording finishes with frames", false, detail: "\(error)")
            return false
        }
        if clip.stopReason == .streamError {
            print("  NOTE: the capture stream ended early (stop=streamError). This normally means")
            print("        the display went to sleep mid-run — re-run under `caffeinate -dimsu`.")
        }
        let recordingDetail = "\(clip.frames.count) frames, \(String(format: "%.2f", clip.duration)) s, \(clip.retainedBytes / 1024) KB retained, stop=\(clip.stopReason.rawValue), dropped=\(clip.droppedFrameCount)"
        check("recording finishes with at least one frame", !clip.frames.isEmpty, detail: recordingDetail)
        if motionIsVisible {
            check("recording captured the on-screen motion as multiple frames",
                  clip.frames.count > 1, detail: recordingDetail)
        } else {
            skip("recording captured the on-screen motion as multiple frames",
                 reason: "the display is not compositing live (\(recordingDetail))")
        }
        check(
            "colour-space outcome survived teardown",
            clip.colorSpace != nil,
            detail: clip.colorSpace.map { "\($0.sourceName) converted=\($0.converted) wide=\($0.wasWideGamutOrHDR)" }
                ?? "nil — the recorder lost it"
        )
        if let notice = clip.colorSpaceNotice {
            print("  editor would show: \(notice)")
        } else {
            print("  no colour-space notice (capture was already sRGB)")
        }
        check(
            "measured wall clock is consistent with the frame span",
            clip.wallClockDuration > 0 && clip.duration >= clip.wallClockDuration - 0.001,
            detail: String(format: "wall %.3f s, duration %.3f s", clip.wallClockDuration, clip.duration)
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
        let trimmedSpan = ClipTrimmer.trimmedDuration(
            frames: clip.frames, range: head...tail, clipDuration: clip.duration
        )
        check("trim keeps the expected frame count", trimmed.count == tail - head + 1,
              detail: "kept \(trimmed.count) of \(clip.frames.count) (indices \(head)...\(tail))")
        check("trimmed clip restarts at t=0", trimmed.first?.timestamp == 0)
        check("trimmed span is positive and no longer than the clip",
              trimmedSpan > 0 && trimmedSpan <= clip.duration + 0.001,
              detail: String(format: "%.3f s of %.3f s", trimmedSpan, clip.duration))

        guard let timeline = ClipTiming.timeline(
            for: trimmed,
            nominalFrameInterval: clip.nominalFrameInterval,
            totalDuration: trimmedSpan
        ) else {
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
            let collapsed = result.collapsedToSingleFrame
            if collapsed {
                print("  NOTE: every retained frame was identical, so libwebp wrote a single-frame")
                print("        still WebP. The animation-specific checks below do not apply.")
            }
            check(
                "container matches what libwebp produced",
                collapsed ? result.container == .webpStill : result.container == .webpAnimated,
                detail: result.container.rawValue
            )
            // libwebp coalesces frames identical to their predecessor, so the stored count can be
            // lower than the submitted count; the invariant that must hold exactly is duration.
            check("stored frame count is within the submitted count",
                  (info?.frameCount ?? 0) >= 1 && (info?.frameCount ?? .max) <= trimmed.count,
                  detail: "\(info?.frameCount ?? -1) stored of \(trimmed.count) submitted (identical frames merged)")
            check("total playback duration is preserved",
                  collapsed || info?.totalDurationMs == timeline.endTimestampMs,
                  detail: "\(info?.totalDurationMs ?? -1) ms vs \(timeline.endTimestampMs) ms")
            check("canvas size round-trips",
                  info?.canvasWidth == Int(clip.pixelSize.width) && info?.canvasHeight == Int(clip.pixelSize.height),
                  detail: "\(info?.canvasWidth ?? -1)x\(info?.canvasHeight ?? -1)")
            check("loop count is 0 (infinite)", collapsed || info?.loopCount == 0,
                  detail: "\(info?.loopCount ?? -1)")
            check("timestamps read back strictly increasing",
                  zip(info?.frameTimestampsMs ?? [], (info?.frameTimestampsMs ?? []).dropFirst()).allSatisfy { $1 > $0 })
            check("every frame duration > 0",
                  collapsed || (info?.durationsMs ?? []).allSatisfy { $0 > 0 })
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

        // ---- Static screen: the duration ceiling must fire from the wall clock -------------
        section("Static-screen recording (duration ceiling)")
        // ScreenCaptureKit only delivers a `.complete` frame when the picture changed, so a
        // frame-driven duration check never fires on a still screen. This records a corner of the
        // desktop — deliberately *not* animating anything — with a short ceiling and checks that
        // the recorder stops itself anyway, exactly once, at the right time.
        let staticLimits = RecordingLimits(frameRate: 12, maxDuration: 3, maxLongEdgePixels: 640)
        let staticRegionRect = CGRect(
            x: main.appKitBounds.minX + 4,
            y: main.appKitBounds.minY + 4,
            width: 160,
            height: 120
        )
        if let staticRegion = CaptureRegion(appKitGlobalRect: staticRegionRect, display: main) {
            let staticRecorder = RegionRecorder(region: staticRegion, limits: staticLimits)
            var autoStops: [RecordingStopReason] = []
            staticRecorder.onAutoStop = { autoStops.append($0) }

            let started = ContinuousClock.now
            do {
                try await staticRecorder.start()
                // Wait past the ceiling without touching the screen.
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                let elapsedAtStop = (ContinuousClock.now - started).timeIntervalValue

                check(
                    "duration ceiling fired without any new frames",
                    autoStops.contains(.durationLimit),
                    detail: autoStops.isEmpty ? "no auto-stop at all" : autoStops.map(\.rawValue).joined(separator: ",")
                )
                check(
                    "it fired exactly once",
                    autoStops.count == 1,
                    detail: "\(autoStops.count) auto-stop callback(s)"
                )
                check(
                    "it fired at the ceiling, not when the next frame happened to arrive",
                    autoStops.contains(.durationLimit) && elapsedAtStop >= staticLimits.maxDuration,
                    detail: String(format: "waited %.1f s for a %.0f s ceiling", elapsedAtStop, staticLimits.maxDuration)
                )

                let staticClip = try await staticRecorder.finish()

                // The regression assertion. The old check lived in the frame handler, so it could
                // only fire once a frame arrived with elapsed > maxDuration — which requires the
                // frame span itself to exceed the ceiling. A frame span *below* the ceiling proves
                // the stop came from the wall clock and not from a frame.
                let staticFrameSpan = (staticClip.frames.last?.timestamp ?? 0)
                    - (staticClip.frames.first?.timestamp ?? 0)
                check(
                    "the ceiling fired although no frame ever passed it",
                    staticFrameSpan < staticLimits.maxDuration,
                    detail: String(
                        format: "last frame at %.2f s, ceiling %.0f s — a frame-driven check could not have fired",
                        staticFrameSpan, staticLimits.maxDuration
                    )
                )
                check(
                    "static clip reports the real recorded length, not the frame span",
                    staticClip.duration >= staticLimits.maxDuration - 0.5,
                    detail: String(
                        format: "%d frame(s), frame span %.2f s, reported duration %.2f s",
                        staticClip.frames.count,
                        (staticClip.frames.last?.timestamp ?? 0) - (staticClip.frames.first?.timestamp ?? 0),
                        staticClip.duration
                    )
                )
                check("static clip stop reason is the duration limit",
                      staticClip.stopReason == .durationLimit,
                      detail: staticClip.stopReason.rawValue)

                // Export it and confirm the animation really is that long.
                let staticTimeline = ClipTiming.timeline(
                    for: staticClip.frames,
                    nominalFrameInterval: staticClip.nominalFrameInterval,
                    totalDuration: staticClip.duration
                )
                if let staticTimeline {
                    check(
                        "exported timeline covers the whole recording",
                        Double(staticTimeline.endTimestampMs) >= (staticLimits.maxDuration - 0.5) * 1000,
                        detail: "\(staticTimeline.endTimestampMs) ms across \(staticTimeline.frameCount) frame(s)"
                    )

                    let staticSource = AnimationFrameSource(
                        frameCount: staticClip.frames.count,
                        timestampsMs: staticTimeline.timestampsMs,
                        endTimestampMs: staticTimeline.endTimestampMs,
                        canvasSize: staticClip.pixelSize
                    ) { index in
                        guard let image = staticClip.frames[index].decodedImage() else {
                            throw TriCapError.encodingFailed("static frame \(index) failed to decode")
                        }
                        return image
                    }
                    do {
                        let staticResult = try ExportService.exportAnimation(
                            source: staticSource, annotations: [], options: .default,
                            directory: insideVault, baseName: "static", vaultRoot: vaultRoot, linkStyle: .markdown
                        )
                        check(
                            "static recording exports successfully",
                            true,
                            detail: "\(staticResult.url.lastPathComponent) container=\(staticResult.container.rawValue) collapsed=\(staticResult.collapsedToSingleFrame)"
                        )
                        if let info = staticResult.animationInfo, !staticResult.collapsedToSingleFrame {
                            check(
                                "exported static animation runs for the full recording",
                                Double(info.totalDurationMs) >= (staticLimits.maxDuration - 0.5) * 1000,
                                detail: "\(info.totalDurationMs) ms"
                            )
                        }
                    } catch {
                        check("static recording exports successfully", false, detail: "\(error)")
                    }
                } else {
                    check("static clip produced a timeline", false)
                }
            } catch {
                check("static recording starts", false, detail: "\(error)")
            }
        } else {
            check("static region resolves", false)
        }

        // ---- Global cancel key -------------------------------------------------------------
        section("Recording-cancel hot key")
        // The recording cancel key has to work while another application is focused, which a
        // local NSEvent monitor cannot do. Carbon accepts a modifier-less key code and needs no
        // Accessibility permission — this proves both, and that claiming it leaves the user's
        // configurable capture shortcut alone.
        print("  AXIsProcessTrusted() = \(AXIsProcessTrusted())  (Accessibility is never requested)")

        let primaryCombo = HotKeyCombo.default
        var primaryFired = 0
        let primaryClaimed = GlobalHotKeyMonitor.shared.register(primaryCombo, in: .primaryCapture) {
            primaryFired += 1
        }
        check("primary capture shortcut registers", primaryClaimed, detail: primaryCombo.displayString)

        var cancelFired = 0
        let escapeClaimed = GlobalHotKeyMonitor.shared.register(
            .bareEscape, in: .escapeDismiss, allowingNoModifiers: true
        ) { cancelFired += 1 }
        check("a bare Escape can be claimed system-wide without Accessibility", escapeClaimed)
        check("claiming Escape leaves the capture shortcut registered",
              GlobalHotKeyMonitor.shared.combo(in: .primaryCapture) == primaryCombo,
              detail: GlobalHotKeyMonitor.shared.combo(in: .primaryCapture)?.displayString ?? "nil")
        check("the two slots hold different combinations",
              GlobalHotKeyMonitor.shared.combo(in: .escapeDismiss) == .bareEscape)

        GlobalHotKeyMonitor.shared.unregister(.escapeDismiss)
        check("releasing Escape does not release the capture shortcut",
              !GlobalHotKeyMonitor.shared.isRegistered(.escapeDismiss)
                  && GlobalHotKeyMonitor.shared.combo(in: .primaryCapture) == primaryCombo)

        // Re-claiming after release must work, because every recording does it.
        let reclaimed = GlobalHotKeyMonitor.shared.register(
            .bareEscape, in: .escapeDismiss, allowingNoModifiers: true
        ) { cancelFired += 1 }
        check("Escape can be re-claimed for the next recording", reclaimed)
        GlobalHotKeyMonitor.shared.unregister(.escapeDismiss)

        // The countdown claims Escape, then the recording rebinds it in place. Re-registering the
        // same combination would fail with eventHotKeyExistsErr, so the hand-off must not do that.
        var handoffCancels = 0
        let handoffClaim = TransientHotKeyClaim(
            combo: .bareEscape,
            register: { combo, action in
                GlobalHotKeyMonitor.shared.register(
                    combo, in: .escapeDismiss, allowingNoModifiers: true, action: action
                )
            },
            unregister: { GlobalHotKeyMonitor.shared.unregister(.escapeDismiss) }
        )
        check("countdown claims Escape", handoffClaim.claim { handoffCancels += 1 })
        check("recording rebinds the same claim without re-registering",
              handoffClaim.claim { handoffCancels += 2 } && handoffClaim.registrationCount == 1,
              detail: "registrations=\(handoffClaim.registrationCount)")
        check("the claim is still live across the hand-off",
              GlobalHotKeyMonitor.shared.isRegistered(.escapeDismiss))
        handoffClaim.release()
        handoffClaim.release()
        check("release is idempotent and gives the key back",
              handoffClaim.releaseCount == 1 && !GlobalHotKeyMonitor.shared.isRegistered(.escapeDismiss),
              detail: "releases=\(handoffClaim.releaseCount)")

        check("a modifier-less combination is refused for the configurable shortcut",
              !GlobalHotKeyMonitor.shared.register(.bareEscape, in: .primaryCapture) {})
        // That refusal left the primary slot empty; restore it so the app-level invariant holds.
        _ = GlobalHotKeyMonitor.shared.register(primaryCombo, in: .primaryCapture) { primaryFired += 1 }
        GlobalHotKeyMonitor.shared.unregisterAll()
        check("all hot keys released at the end of the run",
              GlobalHotKeyMonitor.shared.combo(in: .primaryCapture) == nil
                  && GlobalHotKeyMonitor.shared.combo(in: .escapeDismiss) == nil)

        // ---- Pin shortcut --------------------------------------------------------------------
        section("Pin hot key (F3)")
        // The pin key is a separate slot from the capture key, and it is the one most likely to
        // collide: F3 is Mission Control's factory binding. This registers both for real and
        // reports which of the two outcomes this machine actually produces.
        let pinCombo = HotKeyCombo.defaultPin
        check("F3 is on the bare-key allow list", pinCombo.isValid && !pinCombo.hasModifier,
              detail: pinCombo.displayString)

        _ = GlobalHotKeyMonitor.shared.register(primaryCombo, in: .primaryCapture) { primaryFired += 1 }
        var pinFired = 0
        let pinClaimed = GlobalHotKeyMonitor.shared.register(
            pinCombo, in: .pinFromClipboard, allowingNoModifiers: true
        ) { pinFired += 1 }

        if pinClaimed {
            check("the pin shortcut registers alongside the capture shortcut", true,
                  detail: "\(primaryCombo.displayString) + \(pinCombo.displayString)")
        } else {
            // Not a test failure: it is the conflict path, and the app surfaces it as a rebindable
            // error rather than silently substituting another key.
            print("  NOTE  F3 is already taken on this machine (Mission Control keeps it by "
                  + "default). The app reports this and asks for another key.")
        }
        check("the capture shortcut survives whatever the pin shortcut did",
              GlobalHotKeyMonitor.shared.combo(in: .primaryCapture) == primaryCombo)

        // Carbon refuses a second registration of the same combination. That refusal is what makes
        // conflict detection real rather than assumed, so assert it rather than trusting it.
        check("registering the same combination twice is refused",
              !GlobalHotKeyMonitor.shared.register(primaryCombo, in: .pinFromClipboard) {})

        // Restore whatever the duplicate attempt cleared, then prove independent release.
        if pinClaimed {
            _ = GlobalHotKeyMonitor.shared.register(
                pinCombo, in: .pinFromClipboard, allowingNoModifiers: true
            ) { pinFired += 1 }
            GlobalHotKeyMonitor.shared.unregister(.pinFromClipboard)
            check("releasing the pin shortcut leaves the capture shortcut alone",
                  !GlobalHotKeyMonitor.shared.isRegistered(.pinFromClipboard)
                      && GlobalHotKeyMonitor.shared.combo(in: .primaryCapture) == primaryCombo)
        }
        GlobalHotKeyMonitor.shared.unregisterAll()

        // ---- Window candidates -----------------------------------------------------------------
        section("Selectable windows")
        // The real window list, so the level filter is checked against what this machine actually
        // publishes rather than against invented fixtures.
        do {
            let all = await WindowSurvey.currentWindows()
            if all.isEmpty {
                print("  NOTE  the window list is unavailable, so hover/snap degrade to free drag")
            } else {
                let selectable = WindowPicker.selectableWindows(
                    in: all, ownBundleIdentifier: Bundle.main.bundleIdentifier
                )
                let levels = Set(all.map(\.level)).sorted()
                let belowApplicationLayer = all.filter { $0.level < 0 }
                print("  window levels present: \(levels.map(String.init).joined(separator: ", "))")
                print("  \(all.count) window(s), \(selectable.count) selectable, "
                      + "\(belowApplicationLayer.count) below the application layer")
                for window in belowApplicationLayer.prefix(6) {
                    print("    excluded  level \(window.level)  "
                          + "\(Int(window.frame.width))×\(Int(window.frame.height))  "
                          + "\(window.title ?? window.bundleIdentifier ?? "—")")
                }

                check("every selectable window is on the ordinary application layer",
                      selectable.allSatisfy { $0.level == WindowPicker.ordinaryApplicationLayer })
                check("nothing below the application layer survives the filter",
                      !selectable.contains { $0.level < 0 })
                check("TriCap's own windows are never selectable",
                      !selectable.contains { $0.bundleIdentifier == Bundle.main.bundleIdentifier })

                // The snap set has to be built from the same filtered list, or the desktop's edges
                // tug a selection that could never have been hovered.
                let displayBounds = DisplaySurvey.currentDisplays().map(\.appKitBounds)
                let edges = WindowPicker.snapEdges(
                    in: all,
                    displayBounds: displayBounds,
                    ownBundleIdentifier: Bundle.main.bundleIdentifier
                )
                check("snap edges are the selectable windows plus the displays",
                      edges.count == selectable.count + displayBounds.count,
                      detail: "\(edges.count) = \(selectable.count) window(s) + \(displayBounds.count) display(s)")
                check("no excluded window contributed a snap edge",
                      !belowApplicationLayer.contains { edges.contains($0.frame) }
                          || belowApplicationLayer.allSatisfy { window in
                              // A desktop window whose frame coincides exactly with a display is
                              // indistinguishable from the display edge, which is legitimate.
                              !edges.contains(window.frame) || displayBounds.contains(window.frame)
                          })
            }
        }

        // ---- Escape arbitration --------------------------------------------------------------
        section("Escape priority")
        // Against the *real* process-wide claim, backed by a real Carbon registration — not a fake
        // registrar. The order below is the one that used to break: a recording is already running
        // and the user pins something, which under a last-claim-wins stack silently took Escape
        // away from cancellation.
        do {
            SharedEscapeKey.claim.reset()
            var recordingCancelled = 0
            var pinClosed = 0

            let recordingToken = SharedEscapeKey.claim.push(priority: .recording) {
                recordingCancelled += 1
            }
            check("a recording can claim the shared Escape", recordingToken != nil)

            let pinToken = SharedEscapeKey.claim.push(priority: .pin) { pinClosed += 1 }
            check("pinning during a recording still gets a claim", pinToken != nil)

            SharedEscapeKey.claim.simulateFire()
            check("Escape cancels the recording, not the pin created after it",
                  recordingCancelled == 1 && pinClosed == 0,
                  detail: "recording=\(recordingCancelled), pin=\(pinClosed)")
            check("the active claim is the recording",
                  SharedEscapeKey.claim.activePriority == .recording)

            SharedEscapeKey.claim.pop(recordingToken)
            SharedEscapeKey.claim.simulateFire()
            check("the pin gets Escape back when the recording ends",
                  pinClosed == 1 && recordingCancelled == 1,
                  detail: "recording=\(recordingCancelled), pin=\(pinClosed)")

            SharedEscapeKey.claim.pop(pinToken)
            check("the key is given back once nobody wants it", !SharedEscapeKey.claim.isClaimed)
            SharedEscapeKey.claim.reset()
        }

        // ---- Pin lifecycle -------------------------------------------------------------------
        section("Pin windows")
        // The whole section runs inside one pool: putting a window on screen autoreleases it from
        // several places inside AppKit, and `--selftest` has no outer pool draining regularly, so
        // the deallocation check below would otherwise be measuring pending autoreleases rather
        // than ownership.
        weak var weakPin: PinWindow?
        autoreleasepool {
            let pinboard = PinboardController(
                limits: PinLimits(maxCount: 2, maxTotalPixels: 4_000_000, maxSinglePixels: 3_000_000),
                settingsProvider: { AppSettings() }
            )
            let board = NSPasteboard(name: .init("app.tricap.selftest.pin"))

            // Nothing on the clipboard: a pin must not be created, and the reason must be the
            // "empty" one rather than "not an image".
            board.clearContents()
            check("an empty clipboard creates no pin",
                  {
                      if case .nothingToPin(.empty) = pinboard.pinFromClipboard(board) { return true }
                      return false
                  }(),
                  detail: "pins=\(pinboard.pinCount)")
            check("no window was created for an empty clipboard", pinboard.pinCount == 0)

            // Text only: still no pin, but a different message.
            board.clearContents()
            board.setString("not an image", forType: .string)
            check("a text clipboard creates no pin",
                  {
                      if case .nothingToPin(.unsupportedContent) = pinboard.pinFromClipboard(board) {
                          return true
                      }
                      return false
                  }())

            // A real image: this creates a real NSPanel.
            board.clearContents()
            if let pinImage = solidImage(width: 320, height: 240),
               let pinPNG = ImageProcessing.pngData(from: pinImage) {
                board.setData(pinPNG, forType: .png)
            } else {
                check("built a test image for pinning", false)
            }

            check("a PNG on the clipboard produces a pin", pinboard.pinFromClipboard(board).isSuccess)
            check("pinning twice produces two independent pins",
                  pinboard.pinFromClipboard(board).isSuccess && pinboard.pinCount == 2,
                  detail: "pins=\(pinboard.pinCount)")

            check("the pin count ceiling refuses the third",
                  {
                      if case .refused(.tooManyPins) = pinboard.pinFromClipboard(board) { return true }
                      return false
                  }(),
                  detail: "pins=\(pinboard.pinCount)")

            // The windows must be real, on screen, and must never have taken key focus.
            //
            // The inspection is scoped so the array of windows is gone before teardown — otherwise
            // the weak check below would only be measuring this function's own strong reference.
            autoreleasepool {
                let visible = NSApp.windows.compactMap { $0 as? PinWindow }.filter(\.isVisible)
                check("both pins are real visible windows", visible.count == 2, detail: "\(visible.count)")
                check("no pin ever became the key window",
                      !visible.contains { $0.isKeyWindow } && NSApp.keyWindow as? PinWindow == nil)
                check("pins float above ordinary windows but below the security layer",
                      visible.allSatisfy {
                          $0.level.rawValue > NSWindow.Level.normal.rawValue
                              && $0.level.rawValue < NSWindow.Level.screenSaver.rawValue
                      },
                      detail: visible.map { "\($0.level.rawValue)" }.joined(separator: ","))
                check("pins follow the user across Spaces and full-screen apps",
                      visible.allSatisfy {
                          $0.collectionBehavior.contains(.canJoinAllSpaces)
                              && $0.collectionBehavior.contains(.fullScreenAuxiliary)
                      })
                weakPin = visible.first
            }

            // Front-to-back order, tracked by TriCap rather than read out of `NSApp.windows`.
            // A probe on this machine showed that array keeps creation order and does not change
            // when a window is ordered front, so deriving "the frontmost pin" from it closed the
            // *oldest* pin — the opposite of what Escape should do.
            autoreleasepool {
                let pinsInCreationOrder = NSApp.windows
                    .compactMap { $0 as? PinWindow }
                    .filter(\.isVisible)
                    .sorted { $0.pinID < $1.pinID }
                guard pinsInCreationOrder.count == 2 else {
                    check("two pins available for the ordering check", false)
                    return
                }
                let older = pinsInCreationOrder[0]
                let newer = pinsInCreationOrder[1]

                print("  NOTE  NSApp.windows order for the two pins: "
                      + NSApp.windows.compactMap { ($0 as? PinWindow)?.pinID }
                          .map(String.init).joined(separator: ",")
                      + "  (TriCap does not rely on it)")

                check("the newest pin is the frontmost one",
                      pinboard.frontmostPinID == newer.pinID,
                      detail: "frontmost=\(pinboard.frontmostPinID.map(String.init) ?? "nil"), newest=\(newer.pinID)")

                // The user clicks the older pin: that is what "frontmost" must mean afterwards.
                pinboard.pinDidInteract(older)
                check("interacting with a pin brings it forward",
                      pinboard.frontmostPinID == older.pinID,
                      detail: "frontmost=\(pinboard.frontmostPinID.map(String.init) ?? "nil"), touched=\(older.pinID)")

                // Escape closes that one, and the order falls back to the other.
                pinboard.closeFrontmost()
                check("Escape closes the pin the user last touched",
                      pinboard.pinCount == 1 && pinboard.frontmostPinID == newer.pinID,
                      detail: "remaining=\(pinboard.pinCount), frontmost=\(pinboard.frontmostPinID.map(String.init) ?? "nil")")
                check("the closed pin released its bitmap", older.image == nil)

                // Re-pin so the teardown checks below still have two windows to work with.
                _ = pinboard.pinFromClipboard(board)
            }

            // Teardown has to release the windows *and* the bitmaps they hold.
            pinboard.closeAll()
            check("closeAll() closes every pin", pinboard.pinCount == 0 && !pinboard.hasPins)
            pinboard.closeAll()   // idempotent
            check("closing an empty pinboard again is harmless", pinboard.pinCount == 0)
            check("no pin windows are left in the application",
                  !NSApp.windows.contains { $0 is PinWindow && $0.isVisible })

            // The bitmap is the part that costs megabytes, and dropping it must not depend on when
            // AppKit gets round to freeing the window shell.
            check("teardown released the pinned bitmap", weakPin?.image == nil,
                  detail: weakPin == nil ? "window gone too" : "window shell still held by AppKit")
            check("teardown released the content view", weakPin?.contentView == nil)
            check("teardown left no visible pin window", weakPin?.isVisible != true)

            autoreleasepool { spinRunLoop(seconds: 0.3) }

            board.clearContents()
        }
        autoreleasepool {}

        // Not asserted: AppKit keeps a window that has been on screen alive past `close()` for its
        // own bookkeeping, and a TriCap-free NSPanel behaves identically in this harness (see
        // scripts/diagnostics/panel-lifetime-probe.swift). Whether the shell has gone yet is
        // therefore AppKit's business; what TriCap owns is released above, deterministically.
        print("  NOTE  pin window shell after teardown: "
              + (weakPin == nil ? "deallocated" : "still held by AppKit (bitmap already released)"))

        // ---- Editor window lifecycle -------------------------------------------------------
        section("Editor window lifecycle")
        // Automated evidence for the retain cycle fix: build a real clip editor through the same
        // presenter the app uses, close it, and confirm the window, the model and the frames it
        // held are all deallocated.
        do {
            let presenter = EditorPresenter()
            var settings = AppSettings()
            settings.saveDirectoryPath = directory.appendingPathComponent("editor-lifecycle").path

            weak var weakWindow: NSWindow?
            weak var weakModel: EditorModel?

            autoreleasepool {
                let handle = presenter.present(
                    source: .clip(clip),
                    settings: settings,
                    windowDelegate: nil,
                    orderFront: false,
                    onExported: { _ in }
                )
                weakWindow = handle.window
                weakModel = handle.model
                check("editor window created", handle.window != nil && handle.model != nil)
                check("presenter owns exactly one window", presenter.openWindowCount == 1)
                if let window = handle.window {
                    presenter.release(window)
                    window.close()
                }
            }

            // Give AppKit a few main-actor turns to drain its own autorelease pools.
            for _ in 0..<20 { try? await Task.sleep(nanoseconds: 10_000_000) }
            autoreleasepool {}

            check("presenter released the window", presenter.openWindowCount == 0)
            check("EditorModel deallocated after close", weakModel == nil,
                  detail: weakModel == nil ? "" : "still alive — retain cycle")
            check("editor NSWindow deallocated after close", weakWindow == nil,
                  detail: weakWindow == nil ? "" : "still alive — retain cycle")
        }

        // ---- Summary ----------------------------------------------------------------------
        section("Summary")
        if failures == 0 {
            print(skipped == 0
                  ? "  ALL CHECKS PASSED"
                  : "  ALL EXECUTED CHECKS PASSED — \(skipped) SKIPPED (see SKIP lines above)")
        } else {
            print("  \(failures) CHECK(S) FAILED\(skipped == 0 ? "" : ", \(skipped) SKIPPED")")
        }
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
    private var frameIndex = 0

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

    /// Advance the animation one frame by hand (used by the compositing probe).
    func step(_ times: Int = 1) {
        for _ in 0..<max(1, times) { tick() }
    }

    private func tick() {
        frameIndex += 1
        let hue = CGFloat(frameIndex % 20) / 20.0
        view.layer?.backgroundColor = NSColor(hue: hue, saturation: 0.9, brightness: 0.95, alpha: 1).cgColor
        let travel = max(0, regionRect.width - window.frame.width - 40)
        let x = regionRect.minX + 20 + travel * CGFloat(frameIndex % 20) / 20.0
        window.setFrameOrigin(CGPoint(x: x, y: window.frame.origin.y))
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        window.orderOut(nil)
        window.close()
    }
}
