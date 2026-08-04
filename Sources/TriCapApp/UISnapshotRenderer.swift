import AnnotationCore
import AppKit
import CaptureCore
import CoreGraphics
import ExportCore
import Foundation
import SelectionUI
import SwiftUI
import TriCapKit

/// Offscreen renderer for TriCap's own UI, invoked as `TriCap --render-ui-snapshots <directory>`.
///
/// It exists so the interface can be inspected — and regressions caught — on a machine where
/// nobody is watching the screen and where granting Screen Recording to a screenshot tool is not
/// possible. Every image it writes is the *real* view hierarchy (`SettingsView`, `EditorView`,
/// `SelectionOverlayView`, the recording HUD) drawn through AppKit's normal display path; nothing
/// here is a mock-up. The one thing it cannot show is the menu-bar dropdown, which only the
/// window server can render.
@MainActor
enum UISnapshotRenderer {

    static let flag = "--render-ui-snapshots"

    /// Runs the renderer if the flag is present. Returns `true` if the process should exit.
    static func runIfRequested(arguments: [String]) -> Bool {
        guard let index = arguments.firstIndex(of: flag) else { return false }
        let directory = index + 1 < arguments.count
            ? URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
            : URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("ui-snapshots")

        do {
            try render(into: directory)
            print("wrote UI snapshots to \(directory.path)")
        } catch {
            FileHandle.standardError.write(Data("snapshot render failed: \(error)\n".utf8))
            exit(1)
        }
        return true
    }

    static func render(into directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let store = SettingsStore(defaults: snapshotDefaults())

        // Login-item state is injected, not read from the real SMAppService: this process is a
        // bare SwiftPM binary whose live status would be .notFound and vary by machine.
        try write(
            hosting(
                SettingsView(store: store, loginItem: LoginItemController(service: FakeLoginItemService(fixed: .notRegistered))),
                size: CGSize(width: 540, height: 780)
            ),
            to: directory.appendingPathComponent("01-settings-general.png")
        )
        // The requiresApproval state: toggle on, warning line, System Settings entry point.
        try write(
            hosting(
                SettingsView(store: store, loginItem: LoginItemController(service: FakeLoginItemService(fixed: .requiresApproval))),
                size: CGSize(width: 540, height: 780)
            ),
            to: directory.appendingPathComponent("19-settings-login-approval.png")
        )

        // The quality tab with its advanced section open, which is the whole point of the
        // preset/advanced split. `stillFormat` is PNG here, so no fake Quality stepper appears.
        try write(
            hosting(
                SettingsQualityPreview(store: store, expandAdvanced: true),
                size: CGSize(width: 540, height: 700)
            ),
            to: directory.appendingPathComponent("08-settings-quality.png")
        )

        try write(
            hosting(
                WelcomeView(
                    shortcut: store.settings.hotKey,
                    pinShortcut: store.settings.pinHotKey,
                    permissionStatus: .notDetermined,
                    onGrantPermission: {}, onOpenSystemSettings: {},
                    onTryCapture: {}, onOpenSettings: {}, onDismiss: {}
                ),
                size: CGSize(width: 460, height: 560)
            ),
            to: directory.appendingPathComponent("09-welcome.png")
        )

        try write(
            hosting(exportToastPreview(), size: CGSize(width: 400, height: 160)),
            to: directory.appendingPathComponent("10-export-toast.png")
        )

        // The same toast carrying a warning, to prove the extra lines are not clipped.
        try write(
            hosting(exportToastWarningPreview(), size: CGSize(width: 400, height: 200)),
            to: directory.appendingPathComponent("13-export-toast-warning.png")
        )

        let still = syntheticStill()
        let stillModel = EditorModel(source: .still(still), settings: store.settings, onExported: { _ in }, onClosed: {})
        stillModel.document.add(
            AnnotationItem(
                shape: .arrow(from: CGPoint(x: 120, y: 340), to: CGPoint(x: 430, y: 170)),
                style: AnnotationStyle(color: .red, lineWidth: 8)
            )
        )
        stillModel.document.add(
            AnnotationItem(
                shape: .rectangle(CGRect(x: 400, y: 120, width: 300, height: 110)),
                style: AnnotationStyle(color: .yellow, lineWidth: 8)
            )
        )
        stillModel.document.add(
            AnnotationItem(
                shape: .text(origin: CGPoint(x: 120, y: 380), string: "annotate me"),
                style: AnnotationStyle(color: .blue, fontSize: 44)
            )
        )
        stillModel.document.add(
            AnnotationItem(
                shape: .mosaic(CGRect(x: 90, y: 430, width: 320, height: 90)),
                style: AnnotationStyle(mosaicBlockSize: 18)
            )
        )
        try write(
            hosting(EditorView(model: stillModel), size: CGSize(width: 900, height: 700)),
            to: directory.appendingPathComponent("02-editor-still.png")
        )

        let clipModel = EditorModel(source: .clip(syntheticClip()), settings: store.settings, onExported: { _ in }, onClosed: {})
        clipModel.trimStart = 2
        clipModel.trimEnd = 9
        clipModel.previewIndex = 5
        clipModel.tool = .mosaic
        try write(
            hosting(EditorView(model: clipModel), size: CGSize(width: 900, height: 760)),
            to: directory.appendingPathComponent("03-editor-clip-trim.png")
        )

        // A one-frame clip: the trim and scrub sliders must be absent, not padded to 0...1.
        let singleFrameModel = EditorModel(
            source: .clip(syntheticClip(frameCount: 1)),
            settings: store.settings,
            onExported: { _ in },
            onClosed: {}
        )
        try write(
            hosting(EditorView(model: singleFrameModel), size: CGSize(width: 900, height: 700)),
            to: directory.appendingPathComponent("07-editor-single-frame-clip.png")
        )

        try write(selectionOverlaySnapshot(), to: directory.appendingPathComponent("04-selection-overlay.png"))
        try write(
            selectionOverlaySnapshot(recording: false),
            to: directory.appendingPathComponent("11-selection-overlay-screenshot.png")
        )
        // Hovering a window before any drag: the highlight and its size badge, which is what the
        // user sees for the whole first second of every capture now.
        try write(
            windowHighlightSnapshot(),
            to: directory.appendingPathComponent("14-selection-window-highlight.png")
        )
        // The two overlaps that used to erase the mode banner: a full-screen window highlight and
        // a manual selection dragged straight through the banner. Both `.copy`-blend over it; the
        // banner must be repainted on top.
        try write(
            bannerOverlapSnapshot(kind: .fullScreenHighlight),
            to: directory.appendingPathComponent("16-banner-over-window-highlight.png")
        )
        try write(
            bannerOverlapSnapshot(kind: .selectionThroughBanner),
            to: directory.appendingPathComponent("17-banner-over-selection.png")
        )
        // Mosaic before/after on the fixture that exposed the old defect: dark text rows near the
        // top of a light page. The old implementation sampled the vertically mirrored band and
        // painted white blocks here; the pixelated band must visibly derive from the covered rows.
        try write(
            mosaicBeforeAfterSnapshot(),
            to: directory.appendingPathComponent("18-mosaic-before-after.png")
        )
        // Where the chrome lands for a near-full-screen recording — the case that used to put the
        // Stop button off the top of the display.
        try write(
            hudPlacementSnapshot(),
            to: directory.appendingPathComponent("15-hud-placement-near-fullscreen.png")
        )
        try write(countdownSnapshot(), to: directory.appendingPathComponent("12-recording-countdown.png"))
        try write(recordingHUDSnapshot(), to: directory.appendingPathComponent("05-recording-hud.png"))
        try write(menuBarSnapshot(), to: directory.appendingPathComponent("06-menu-bar-item.png"))
    }

    // MARK: - Individual snapshots

    /// The real ``SelectionOverlayView`` with a live selection, over a synthetic desktop.
    private static func selectionOverlaySnapshot(recording: Bool = true) throws -> NSBitmapImageRep {
        let size = CGSize(width: 900, height: 560)
        let container = offscreenContainer(size: size)
        let desktop = syntheticDesktop(width: Int(size.width), height: Int(size.height))

        let overlay = SelectionOverlayView(frame: container.bounds)
        overlay.isRecordingMode = recording
        container.addSubview(overlay)

        // The overlay interprets its selection in AppKit *global* points and converts through its
        // window, so the rect has to be offset by the (deliberately off-screen) window origin —
        // exactly the conversion the live overlay performs during a drag.
        let windowOrigin = container.window?.frame.origin ?? .zero
        overlay.globalSelection = CGRect(
            x: windowOrigin.x + 210,
            y: windowOrigin.y + 150,
            width: 470,
            height: 260
        )
        overlay.selectionPixelSize = CGSize(width: 940, height: 520)

        settle(container)
        return try composite(base: desktop, overlay: try bitmap(of: container, background: nil))
    }

    /// The overlay with a window highlighted under the pointer and no drag in progress.
    /// Original next to mosaic'd, on content shaped like the report: dark "text" near the top of
    /// a light page, with a bright band at the vertically mirrored position that the old
    /// implementation would have sampled instead.
    private static func mosaicBeforeAfterSnapshot() throws -> NSBitmapImageRep {
        let width = 420
        let height = 300

        func fixture() -> CGImage {
            let ctx = ImageProcessing.makeContext(width: width, height: height)!
            // Light page.
            ctx.setFillColor(CGColor(srgbRed: 0.97, green: 0.97, blue: 0.95, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            // Dark text-like rows near the TOP (context space: high y).
            ctx.setFillColor(CGColor(srgbRed: 0.15, green: 0.17, blue: 0.22, alpha: 1))
            for (row, widths) in [(252, [70, 40, 90, 55]), (232, [50, 85, 35, 70]), (212, [95, 45, 60, 40])] {
                var x = 24
                for w in widths {
                    ctx.fill(CGRect(x: x, y: row, width: w, height: 11))
                    x += w + 14
                }
            }
            // A saturated band at the mirrored position — what the old code wrongly sampled.
            ctx.setFillColor(CGColor(srgbRed: 0.98, green: 0.62, blue: 0.15, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 30, width: width, height: 50))
            return ctx.makeImage()!
        }

        let base = fixture()
        let mosaic = AnnotationItem(
            shape: .mosaic(CGRect(x: 16, y: 30, width: width - 32, height: 72)),   // the text rows
            style: AnnotationStyle(mosaicBlockSize: 14)
        )
        guard let after = AnnotationRenderer.render(items: [mosaic], onto: base) else {
            throw TriCapError.encodingFailed("mosaic snapshot render failed")
        }

        // Side by side with a caption strip.
        let pad = 16
        let captionHeight = 34
        let sheetWidth = width * 2 + pad * 3
        let sheetHeight = height + pad * 2 + captionHeight
        let sheet = ImageProcessing.makeContext(width: sheetWidth, height: sheetHeight)!
        sheet.setFillColor(CGColor(srgbRed: 0.13, green: 0.13, blue: 0.14, alpha: 1))
        sheet.fill(CGRect(x: 0, y: 0, width: sheetWidth, height: sheetHeight))
        sheet.draw(base, in: CGRect(x: pad, y: pad, width: width, height: height))
        sheet.draw(after, in: CGRect(x: pad * 2 + width, y: pad, width: width, height: height))
        guard let composite = sheet.makeImage() else {
            throw TriCapError.encodingFailed("mosaic snapshot composite failed")
        }
        let rep = NSBitmapImageRep(cgImage: composite)
        rep.size = NSSize(width: sheetWidth, height: sheetHeight)
        return rep
    }

    /// The overlap regressions: content drawn with `.copy` blending crossing the mode banner.
    private enum BannerOverlap {
        case fullScreenHighlight
        case selectionThroughBanner
    }

    private static func bannerOverlapSnapshot(kind: BannerOverlap) throws -> NSBitmapImageRep {
        let size = CGSize(width: 900, height: 560)
        let container = offscreenContainer(size: size)
        let desktop = syntheticDesktop(width: Int(size.width), height: Int(size.height))

        let overlay = SelectionOverlayView(frame: container.bounds)
        container.addSubview(overlay)

        let windowOrigin = container.window?.frame.origin ?? .zero
        switch kind {
        case .fullScreenHighlight:
            // Hovering a full-screen window: the highlight's `.copy` fill covers the entire view,
            // banner region included.
            overlay.highlightedWindow = CGRect(origin: windowOrigin, size: size)
            overlay.highlightedWindowPixelSize = CGSize(width: 1800, height: 1120)
        case .selectionThroughBanner:
            // A drag that crosses the banner: the punch-out clears everything it covers.
            overlay.isRecordingMode = true
            overlay.globalSelection = CGRect(
                x: windowOrigin.x + 180, y: windowOrigin.y + size.height - 220,
                width: 540, height: 220
            )
            overlay.selectionPixelSize = CGSize(width: 1080, height: 440)
        }

        settle(container)
        return try composite(base: desktop, overlay: try bitmap(of: container, background: nil))
    }

    private static func windowHighlightSnapshot() throws -> NSBitmapImageRep {
        let size = CGSize(width: 900, height: 560)
        let container = offscreenContainer(size: size)
        let desktop = syntheticDesktop(width: Int(size.width), height: Int(size.height))

        let overlay = SelectionOverlayView(frame: container.bounds)
        overlay.isRecordingMode = false
        container.addSubview(overlay)

        // Same global-point convention as `selectionOverlaySnapshot`.
        let windowOrigin = container.window?.frame.origin ?? .zero
        overlay.highlightedWindow = CGRect(
            x: windowOrigin.x + 150,
            y: windowOrigin.y + 120,
            width: 560,
            height: 320
        )
        overlay.highlightedWindowPixelSize = CGSize(width: 1120, height: 640)

        settle(container)
        return try composite(base: desktop, overlay: try bitmap(of: container, background: nil))
    }

    /// A scale drawing of where the chrome ends up for a near-full-screen selection.
    ///
    /// The HUD itself is the real one, built by `RecordingHUD.populateHUD`; what this adds is the
    /// *context* a plain HUD screenshot cannot show — the display, its visible frame, the
    /// selection, and the resulting placement. That relationship is the thing that was broken, so
    /// it is the thing worth looking at.
    private static func hudPlacementSnapshot() throws -> NSBitmapImageRep {
        // A small display drawn 1:1, so the real 300×74 HUD is in true proportion to it. Scaling
        // the display but not the HUD would make the picture lie about whether it fits.
        let displayBounds = CGRect(x: 0, y: 0, width: 900, height: 560)
        let visibleFrame = CGRect(x: 0, y: 20, width: 900, height: 510)   // menu bar + Dock
        let region = CGRect(x: 0, y: 0, width: 900, height: 526)          // 94% tall, flush bottom

        let placement = HUDPlacement.place(
            size: RecordingHUD.hudSize, over: region, in: visibleFrame
        )

        let size = CGSize(width: displayBounds.width, height: displayBounds.height + 34)
        let container = offscreenContainer(size: size)
        container.appearance = NSAppearance(named: .darkAqua)
        container.layer?.backgroundColor = NSColor(calibratedWhite: 0.09, alpha: 1).cgColor

        // The display, then the strips outside the visible frame, then the selection.
        let display = NSView(frame: displayBounds)
        display.wantsLayer = true
        display.layer?.backgroundColor = NSColor(calibratedWhite: 0.16, alpha: 1).cgColor
        container.addSubview(display)

        for strip in [
            CGRect(x: 0, y: visibleFrame.maxY, width: displayBounds.width,
                   height: displayBounds.maxY - visibleFrame.maxY),
            CGRect(x: 0, y: 0, width: displayBounds.width, height: visibleFrame.minY),
        ] where strip.height > 0 {
            let bar = NSView(frame: strip)
            bar.wantsLayer = true
            bar.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.28).cgColor
            container.addSubview(bar)
        }

        let selection = NSView(frame: region)
        selection.wantsLayer = true
        selection.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.14).cgColor
        selection.layer?.borderColor = NSColor.systemBlue.cgColor
        selection.layer?.borderWidth = 2
        container.addSubview(selection)

        let hudBacking = NSView(frame: placement.frame)
        hudBacking.wantsLayer = true
        hudBacking.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.9).cgColor
        hudBacking.layer?.cornerRadius = 12
        hudBacking.layer?.borderColor = NSColor.systemGreen.cgColor
        hudBacking.layer?.borderWidth = 2
        let hud = RecordingHUD()
        hud.populateHUD(hudBacking, onStop: {})
        hud.update(
            progress: RecordingProgress(frameCount: 51, elapsed: 4.2, retainedBytes: 12 * 1_048_576),
            limits: RecordingLimits(frameRate: 12, maxDuration: 15)
        )
        snapshotHUDs.append(hud)
        container.addSubview(hudBacking)

        let caption = NSTextField(labelWithString:
            "94%-tall selection · strategy: \(placement.strategy.rawValue) · red strips are outside visibleFrame")
        caption.font = .systemFont(ofSize: 12, weight: .medium)
        caption.textColor = .white
        caption.frame = CGRect(x: 12, y: size.height - 24, width: size.width - 24, height: 18)
        container.addSubview(caption)

        settle(container)
        return try bitmap(of: container)
    }

    /// The *real* recording HUD, populated by `RecordingHUD` itself.
    private static func recordingHUDSnapshot() throws -> NSBitmapImageRep {
        let content = offscreenContainer(size: RecordingHUD.hudSize)
        content.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.82).cgColor
        content.layer?.cornerRadius = 12
        content.appearance = NSAppearance(named: .darkAqua)

        let hud = RecordingHUD()
        hud.populateHUD(content, onStop: {})
        hud.update(
            progress: RecordingProgress(frameCount: 51, elapsed: 4.2, retainedBytes: 12 * 1_048_576),
            limits: RecordingLimits(frameRate: 12, maxDuration: 15)
        )
        snapshotHUDs.append(hud)

        settle(content)
        return try bitmap(of: content)
    }

    /// Keeps the snapshot HUD alive until its bitmap has been taken.
    private static var snapshotHUDs: [RecordingHUD] = []

    /// The *real* countdown panel, populated by `RecordingHUD` itself.
    private static func countdownSnapshot() throws -> NSBitmapImageRep {
        let content = offscreenContainer(size: RecordingHUD.countdownSize)
        content.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.82).cgColor
        content.layer?.cornerRadius = 12

        let hud = RecordingHUD()
        hud.populateCountdown(content, seconds: 3)
        snapshotHUDs.append(hud)

        settle(content)
        return try bitmap(of: content)
    }

    /// The post-export confirmation, with the wording the tests assert.
    private static func exportToastPreview() -> some View {
        ExportToastPreview(
            summary: ExportSummary(
                fileName: "TriCap-2026-08-03-141530.webp",
                folderDisplayPath: "~/Documents/Vault/assets",
                sizeDescription: "1.4 MB",
                detailDescription: "1440 × 900 · Animated WebP · 52 frames · 4.7 s",
                clipboardDescription: "Copied the Markdown reference",
                warning: nil
            )
        )
    }

    /// The confirmation for a recording that produced no motion — the longest wording it can show.
    private static func exportToastWarningPreview() -> some View {
        ExportToastPreview(
            summary: ExportSummary(
                fileName: "TriCap-2026-08-03-141530.webp",
                folderDisplayPath: "~/Pictures/TriCap",
                sizeDescription: "38 KB",
                detailDescription: "800 × 600 · Animated WebP",
                clipboardDescription: "Copied the file path",
                warning: "Nothing moved during the recording, so this is a single-frame WebP."
            )
        )
    }

    /// The status item's template image at menu-bar size, on a menu-bar-like strip.
    private static func menuBarSnapshot() throws -> NSBitmapImageRep {
        let size = CGSize(width: 240, height: 32)
        let container = offscreenContainer(size: size)
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let imageView = NSImageView(frame: CGRect(x: 12, y: 6, width: 20, height: 20))
        let symbol = NSImage(systemSymbolName: "viewfinder.rectangular", accessibilityDescription: "TriCap")
        symbol?.isTemplate = true
        imageView.image = symbol
        imageView.contentTintColor = .labelColor
        container.addSubview(imageView)

        let label = NSTextField(labelWithString: "TriCap status item (⌥⇧5)")
        label.font = .systemFont(ofSize: 12)
        label.frame = CGRect(x: 40, y: 8, width: 200, height: 16)
        container.addSubview(label)

        settle(container)
        return try bitmap(of: container)
    }

    // MARK: - Plumbing

    /// Host a SwiftUI view in a real (never-ordered-front) window.
    ///
    /// SwiftUI only resolves a layout once its host is attached to a window and the run loop has
    /// turned; snapshotting a detached `NSHostingView` yields a half-laid-out toolbar. The window
    /// is created off-screen and never ordered front, so nothing appears on the user's display.
    private static func hosting<V: View>(_ view: V, size: CGSize) -> NSView {
        let window = NSWindow(
            contentRect: NSRect(origin: CGPoint(x: -10_000, y: -10_000), size: size),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        window.contentView = hosting
        window.setContentSize(size)
        window.layoutIfNeeded()

        for _ in 0..<25 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            window.layoutIfNeeded()
            hosting.layoutSubtreeIfNeeded()
        }
        snapshotWindows.append(window)
        return hosting
    }

    /// Keeps snapshot windows alive until the process exits; releasing one mid-render tears down
    /// the hosting view before `cacheDisplay` has run.
    private static var snapshotWindows: [NSWindow] = []

    /// A layer-backed content view inside an off-screen window.
    ///
    /// Attaching to a window makes AppKit turn on layer backing for the whole subtree, so every
    /// custom `draw(_:)` view ends up with layer contents that `CALayer.render(in:)` can capture.
    /// A detached view hierarchy renders as an empty rectangle instead.
    private static func offscreenContainer(size: CGSize) -> NSView {
        let window = NSWindow(
            contentRect: NSRect(origin: CGPoint(x: -10_000, y: -10_000), size: size),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(origin: .zero, size: size))
        content.wantsLayer = true
        window.contentView = content
        snapshotWindows.append(window)
        return content
    }

    /// Give AppKit a few run-loop turns to draw a freshly-populated offscreen hierarchy.
    private static func settle(_ view: NSView) {
        view.needsDisplay = true
        for _ in 0..<10 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
        }
    }

    /// Snapshot a view hierarchy to a bitmap.
    ///
    /// `cacheDisplay(in:to:)` walks the `draw(_:)` path, which captures TriCap's own custom views
    /// perfectly but misses AppKit controls that render through Core Animation (segmented
    /// controls, sliders, push buttons — i.e. most of what SwiftUI produces). Rendering the layer
    /// tree instead picks those up, so layer-backed hierarchies go through `CALayer.render(in:)`
    /// and everything else keeps the `draw(_:)` path.
    private static func bitmap(of view: NSView, background: NSColor? = .windowBackgroundColor) throws -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw TriCapError.encodingFailed("bitmapImageRepForCachingDisplay returned nil")
        }

        if let layer = view.layer, let context = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            let cg = context.cgContext
            cg.clear(CGRect(origin: .zero, size: view.bounds.size))
            if let background {
                cg.setFillColor(background.cgColor)
                cg.fill(view.bounds)
            }
            // `CALayer.render(in:)` draws in the layer's own geometry and ignores
            // `isGeometryFlipped`. AppKit flips the layer geometry for views whose `isFlipped` is
            // true (every `NSHostingView`), so exactly those need the context flipped back;
            // plain bottom-left-origin views must not be flipped or they come out upside down.
            if view.isFlipped {
                cg.translateBy(x: 0, y: view.bounds.height)
                cg.scaleBy(x: 1, y: -1)
            }
            layer.render(in: cg)
            NSGraphicsContext.restoreGraphicsState()
            return rep
        }

        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// Composite `overlay` (with alpha) over `base`.
    ///
    /// The live selection overlay is the content view of a fully transparent window, so its
    /// punched-out region reveals the real screen underneath. Reproducing that offscreen means
    /// rendering the overlay on its own and compositing it here, rather than stacking it on a
    /// backdrop view inside one opaque layer tree (which would fill the punch-out with black).
    private static func composite(base: CGImage, overlay: NSBitmapImageRep) throws -> NSBitmapImageRep {
        let width = base.width
        let height = base.height
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: ImageProcessing.outputColorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            throw TriCapError.encodingFailed("could not allocate the compositing context")
        }
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: width, height: height))
        if let overlayImage = overlay.cgImage {
            ctx.draw(overlayImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        guard let merged = ctx.makeImage() else {
            throw TriCapError.encodingFailed("compositing produced no image")
        }
        return NSBitmapImageRep(cgImage: merged)
    }

    private static func write(_ view: NSView, to url: URL) throws {
        try write(try bitmap(of: view), to: url)
    }

    private static func write(_ rep: NSBitmapImageRep, to url: URL) throws {
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw TriCapError.encodingFailed("PNG representation failed for \(url.lastPathComponent)")
        }
        try data.write(to: url)
    }

    /// Snapshots must never disturb the user's real preferences.
    private static func snapshotDefaults() -> UserDefaults {
        let suite = UserDefaults(suiteName: "app.tricap.ui-snapshots")!
        suite.removePersistentDomain(forName: "app.tricap.ui-snapshots")
        return suite
    }

    // MARK: - Synthetic content

    /// A recognisable stand-in for a real screen capture.
    private static func syntheticDesktop(width: Int, height: Int) -> CGImage {
        let ctx = ImageProcessing.makeContext(width: width, height: height)!
        let colors = [
            CGColor(red: 0.16, green: 0.20, blue: 0.32, alpha: 1),
            CGColor(red: 0.30, green: 0.44, blue: 0.62, alpha: 1),
        ] as CFArray
        if let gradient = CGGradient(colorsSpace: ImageProcessing.outputColorSpace, colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(
                gradient,
                start: .zero,
                end: CGPoint(x: width, y: height),
                options: []
            )
        }
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.18))
        ctx.setLineWidth(1)
        for x in stride(from: 0, to: width, by: 40) {
            ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x, y: height))
        }
        for y in stride(from: 0, to: height, by: 40) {
            ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: width, y: y))
        }
        ctx.strokePath()

        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.9))
        ctx.fill(CGRect(x: 80, y: height - 200, width: 300, height: 60))
        ctx.setFillColor(CGColor(red: 0.95, green: 0.75, blue: 0.25, alpha: 0.95))
        ctx.fill(CGRect(x: 420, y: height - 320, width: 220, height: 150))
        return ctx.makeImage()!
    }

    private static func syntheticStill() -> CapturedStill {
        let image = syntheticDesktop(width: 940, height: 620)
        return CapturedStill(
            image: image,
            region: snapshotRegion(pixelWidth: 940, pixelHeight: 620),
            colorSpace: ImageProcessing.ColorSpaceOutcome(
                sourceName: "kCGColorSpaceSRGB",
                converted: false,
                wasWideGamutOrHDR: false
            )
        )
    }

    private static func syntheticClip(frameCount: Int = 12) -> RecordedClip {
        let frames: [RecordedFrame] = (0..<frameCount).map { index in
            let ctx = ImageProcessing.makeContext(width: 640, height: 400)!
            ctx.draw(syntheticDesktop(width: 640, height: 400), in: CGRect(x: 0, y: 0, width: 640, height: 400))
            ctx.setFillColor(CGColor(red: 0.95, green: 0.28, blue: 0.24, alpha: 1))
            ctx.fill(CGRect(x: 40 + index * 45, y: 170, width: 60, height: 60))
            let image = ctx.makeImage()!
            return RecordedFrame(pngData: ImageProcessing.pngData(from: image)!, timestamp: Double(index) / 12.0)
        }
        return RecordedClip(
            frames: frames,
            pixelSize: CGSize(width: 640, height: 400),
            region: snapshotRegion(pixelWidth: 640, pixelHeight: 400),
            nominalFrameInterval: 1.0 / 12.0,
            stopReason: .userStopped,
            droppedFrameCount: 0,
            colorSpace: nil,
            retainedBytes: frames.reduce(0) { $0 + $1.pngData.count },
            wallClockDuration: Double(frames.count) / 12.0
        )
    }

    private static func snapshotRegion(pixelWidth: Int, pixelHeight: Int) -> CaptureRegion {
        let display = DisplayGeometry(
            displayID: 1,
            appKitBounds: CGRect(x: 0, y: 0, width: 1512, height: 982),
            quartzBounds: CGRect(x: 0, y: 0, width: 1512, height: 982),
            pointPixelScale: 2.0,
            primaryHeightInPoints: 982
        )
        return CaptureRegion(
            display: display,
            appKitGlobalRect: CGRect(x: 100, y: 100, width: CGFloat(pixelWidth) / 2, height: CGFloat(pixelHeight) / 2),
            displayPixelRect: CGRect(x: 200, y: 200, width: CGFloat(pixelWidth), height: CGFloat(pixelHeight)),
            sourceRectInDisplayPoints: CGRect(x: 100, y: 100, width: CGFloat(pixelWidth) / 2, height: CGFloat(pixelHeight) / 2)
        )
    }
}

/// A canned login-item backend for deterministic settings snapshots.
@MainActor
private struct FakeLoginItemService: LoginItemService {
    let fixed: LoginItemStatus
    var status: LoginItemStatus { fixed }
    func register() throws {}
    func unregister() throws {}
    func openSystemSettings() {}
}
