import AppKit
import CaptureCore
import ExportCore
import SwiftUI
import TriCapKit

/// Creates, owns and releases annotation-editor windows.
///
/// Split out of `AppDelegate` so the ownership graph is small enough to reason about and can be
/// exercised directly by the lifecycle check in `--selftest`.
///
/// **The cycle this type exists to avoid.** The editor's *Close* button has to be able to close
/// its own window, so the model needs a way to reach it. Capturing the window strongly in the
/// `onClosed` closure creates `window → contentViewController → EditorView → model → closure →
/// window`, which keeps the window, the model and every retained recording frame alive forever —
/// a 15-second clip is tens of megabytes per leaked editor. The closure therefore captures a
/// box that holds the window *weakly*.
@MainActor
final class EditorPresenter {

    /// Weak handles handed back for lifecycle assertions.
    struct Handle {
        weak var window: NSWindow?
        weak var model: EditorModel?
    }

    /// Weak back-pointer: retained by the model's close action, retains nothing itself.
    private final class WindowBox {
        weak var window: NSWindow?
    }

    /// The presenter is the sole owner of open editor windows.
    private var windows: [ObjectIdentifier: NSWindow] = [:]

    var openWindowCount: Int { windows.count }

    /// Build and show an editor window.
    ///
    /// - Parameter orderFront: `false` keeps the window off screen, which is what the headless
    ///   lifecycle check wants.
    @discardableResult
    func present(
        source: EditorSource,
        settings: AppSettings,
        windowDelegate: NSWindowDelegate?,
        orderFront: Bool = true,
        onExported: @escaping (ExportResult) -> Void
    ) -> Handle {
        let box = WindowBox()

        let model = EditorModel(
            source: source,
            settings: settings,
            onExported: onExported,
            // `box` is captured strongly; `box.window` is weak, so the cycle is broken here.
            onClosed: { box.window?.close() }
        )

        let hosting = NSHostingController(rootView: EditorView(model: model))
        let window = NSWindow(contentViewController: hosting)
        window.title = source.isClip ? "TriCap — Recording" : "TriCap — Screenshot"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(preferredSize(for: model.canvasSize))
        window.center()
        window.delegate = windowDelegate
        box.window = window

        windows[ObjectIdentifier(window)] = window

        if orderFront {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }

        return Handle(window: window, model: model)
    }

    /// Drop the presenter's ownership. After this the window, its hosting controller, the
    /// `EditorModel` and every recorded frame it holds are free to deallocate.
    func release(_ window: NSWindow) {
        guard let owned = windows.removeValue(forKey: ObjectIdentifier(window)) else { return }
        owned.delegate = nil
        // Tearing down the content view controller drops the SwiftUI hosting view (and with it the
        // `EditorModel`) without waiting for AppKit to get around to releasing the window.
        owned.contentViewController = nil
    }

    /// Fit the canvas on screen without shrinking below a usable toolbar width.
    private func preferredSize(for canvas: CGSize) -> CGSize {
        let visible = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1280, height: 800)
        let chrome = CGSize(width: 0, height: 190)
        let maxCanvas = CGSize(
            width: max(480, visible.width * 0.8),
            height: max(320, visible.height * 0.8 - chrome.height)
        )
        let scale = min(1, min(maxCanvas.width / max(1, canvas.width), maxCanvas.height / max(1, canvas.height)))
        return CGSize(
            width: max(680, canvas.width * scale),
            height: max(460, canvas.height * scale + chrome.height)
        )
    }
}
