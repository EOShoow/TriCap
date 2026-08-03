import AnnotationCore
import AppKit
import CaptureCore
import ExportCore
import SelectionUI
import SwiftUI
import TriCapKit

/// Version strings surfaced in the UI and the about pane.
public enum TriCapVersion {
    public static let app = "0.1.0"
    public static var libwebpVersion: String { WebPCodec.versionString }
}

/// Menu-bar controller and capture orchestrator.
///
/// TriCap has no Dock icon and no main window: everything hangs off the status item, the global
/// hot key, and the transient windows the capture flow creates.
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {

    private let store = SettingsStore()
    private let hud = RecordingHUD()

    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var editorWindows: [ObjectIdentifier: NSWindow] = [:]

    private var selector: RegionSelector?
    private var recorder: RegionRecorder?
    private var isCapturing = false

    // MARK: - Lifecycle

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installStatusItem()
        registerHotKey()

        store.onChange = { [weak self] previous, current in
            guard let self else { return }
            if previous.hotKey != current.hotKey { self.registerHotKey() }
            self.refreshMenu()
        }

        if let error = store.prepareSaveDirectory() {
            TriCapLog.app.error("save directory unavailable: \(error, privacy: .public)")
        }
        TriCapLog.app.info("TriCap \(TriCapVersion.app, privacy: .public) launched (libwebp \(TriCapVersion.libwebpVersion, privacy: .public))")
    }

    public func applicationWillTerminate(_ notification: Notification) {
        GlobalHotKeyMonitor.shared.unregister()
    }

    public func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: - Menu bar

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "viewfinder.rectangular",
            accessibilityDescription: "TriCap"
        )
        item.button?.image?.isTemplate = true
        item.menu = buildMenu()
        statusItem = item
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let capture = NSMenuItem(
            title: "Capture Region…",
            action: #selector(captureRegion),
            keyEquivalent: ""
        )
        capture.target = self
        menu.addItem(capture)

        let record = NSMenuItem(
            title: "Record Region…",
            action: #selector(recordRegion),
            keyEquivalent: ""
        )
        record.target = self
        menu.addItem(record)

        menu.addItem(.separator())

        let shortcut = NSMenuItem(
            title: "Shortcut: \(store.settings.hotKey.displayString)",
            action: nil,
            keyEquivalent: ""
        )
        shortcut.isEnabled = false
        menu.addItem(shortcut)

        let reveal = NSMenuItem(
            title: "Open Save Folder",
            action: #selector(openSaveFolder),
            keyEquivalent: ""
        )
        reveal.target = self
        menu.addItem(reveal)

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let quit = NSMenuItem(title: "Quit TriCap", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        return menu
    }

    private func refreshMenu() {
        statusItem?.menu = buildMenu()
    }

    private func registerHotKey() {
        let combo = store.settings.hotKey
        let registered = GlobalHotKeyMonitor.shared.register(combo) { [weak self] in
            Task { @MainActor in self?.beginCapture(mode: .still) }
        }
        if !registered {
            presentAlert(
                title: "Shortcut unavailable",
                message: "Another app already uses \(combo.displayString). Pick a different shortcut in TriCap settings."
            )
        }
    }

    // MARK: - Menu actions

    @objc private func captureRegion() { beginCapture(mode: .still) }
    @objc private func recordRegion() { beginCapture(mode: .recording) }

    @objc private func openSaveFolder() {
        store.prepareSaveDirectory()
        NSWorkspace.shared.open(store.settings.saveDirectoryURL)
    }

    @objc private func showSettings() {
        if let settingsWindow {
            NSApp.activate(ignoringOtherApps: true)
            settingsWindow.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingController(rootView: SettingsView(store: store))
        let window = NSWindow(contentViewController: hosting)
        window.title = "TriCap Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        window.delegate = self
        settingsWindow = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Capture flow

    private func beginCapture(mode: RegionSelector.CaptureMode) {
        guard !isCapturing else { return }
        isCapturing = true

        Task { @MainActor in
            defer {
                isCapturing = false
                // Settings can change the hot key label; keep the menu honest.
                refreshMenu()
                syncHotKeyRegistration()
            }

            guard await ensurePermission() else { return }

            let selector = RegionSelector()
            self.selector = selector
            let outcome = await selector.selectRegion(initialMode: mode)
            self.selector = nil

            switch outcome {
            case .cancelled:
                TriCapLog.app.info("capture cancelled at selection")
            case .selected(let region, .still):
                await captureStill(region: region)
            case .selected(let region, .recording):
                await recordClip(region: region)
            }
        }
    }

    private func captureStill(region: CaptureRegion) async {
        // Give the window server one turn to actually remove the overlay before we sample the
        // screen. The content filter already excludes TriCap, but this also avoids catching the
        // dimming layer's fade-out on slower machines.
        try? await Task.sleep(nanoseconds: 80_000_000)

        do {
            let still = try await StillCaptureService.capture(region: region)
            presentEditor(source: .still(still))
        } catch {
            presentCaptureError(error)
        }
    }

    private func recordClip(region: CaptureRegion) async {
        let limits = store.settings.recordingLimits
        let countdown = store.settings.countdownSeconds

        guard await hud.runCountdown(seconds: countdown, over: region) else {
            hud.dismiss()
            TriCapLog.app.info("recording cancelled during countdown")
            return
        }

        let recorder = RegionRecorder(region: region, limits: limits)
        self.recorder = recorder

        var stopped = false
        let stop: @MainActor () -> Void = { [weak self] in
            guard !stopped else { return }
            stopped = true
            Task { @MainActor in await self?.finishRecording() }
        }

        recorder.onProgress = { [weak self] progress in
            self?.hud.update(progress: progress, limits: limits)
        }
        recorder.onAutoStop = { reason in
            TriCapLog.app.info("recording auto-stopped: \(reason.rawValue, privacy: .public)")
            stop()
        }

        do {
            try await recorder.start()
        } catch {
            self.recorder = nil
            hud.dismiss()
            presentCaptureError(error)
            return
        }

        hud.showRecordingHUD(region: region, onStop: stop)
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            Task { @MainActor in await self?.cancelRecording() }
            return nil
        }
    }

    private var escapeMonitor: Any?

    private func teardownRecordingChrome() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
        hud.dismiss()
    }

    private func finishRecording() async {
        guard let recorder else { return }
        self.recorder = nil
        teardownRecordingChrome()

        do {
            let clip = try await recorder.finish()
            presentEditor(source: .clip(clip))
        } catch {
            presentCaptureError(error)
        }
    }

    private func cancelRecording() async {
        guard let recorder else { return }
        self.recorder = nil
        teardownRecordingChrome()
        await recorder.cancel()
        TriCapLog.app.info("recording cancelled by user")
    }

    // MARK: - Permission

    private func ensurePermission() async -> Bool {
        switch ScreenRecordingPermission.authorizationStatus() {
        case .authorized:
            return true

        case .notDetermined:
            let proceed = presentConfirm(
                title: "TriCap needs Screen Recording permission",
                message: "macOS will ask once. Without it TriCap cannot see the screen at all.",
                confirmTitle: "Ask macOS"
            )
            guard proceed else { return false }

            let status = ScreenRecordingPermission.request()
            if status == .authorized { return true }
            presentPermissionDeniedAlert(justRequested: true)
            return false

        case .denied:
            presentPermissionDeniedAlert(justRequested: false)
            return false
        }
    }

    private func presentPermissionDeniedAlert(justRequested: Bool) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Screen Recording permission is off"
        alert.informativeText = justRequested
            ? "Enable TriCap under System Settings → Privacy & Security → Screen & System Audio Recording, then relaunch TriCap. macOS only applies newly granted permission to a fresh launch."
            : "macOS will not ask again. Enable TriCap under System Settings → Privacy & Security → Screen & System Audio Recording, then relaunch TriCap."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            ScreenRecordingPermission.openSystemSettings()
        }
    }

    // MARK: - Editor

    private func presentEditor(source: EditorSource) {
        var window: NSWindow?

        let model = EditorModel(
            source: source,
            settings: store.settings,
            onExported: { [weak self] result in
                self?.handleExport(result)
            },
            onClosed: {
                window?.close()
            }
        )

        let hosting = NSHostingController(rootView: EditorView(model: model))
        let created = NSWindow(contentViewController: hosting)
        created.title = source.isClip ? "TriCap — Recording" : "TriCap — Screenshot"
        created.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        created.isReleasedWhenClosed = false
        created.setContentSize(preferredEditorSize(for: model.canvasSize))
        created.center()
        created.delegate = self
        window = created
        editorWindows[ObjectIdentifier(created)] = created

        NSApp.activate(ignoringOtherApps: true)
        created.makeKeyAndOrderFront(nil)
    }

    /// Fit the canvas on screen without shrinking below a usable toolbar width.
    private func preferredEditorSize(for canvas: CGSize) -> CGSize {
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

    private func handleExport(_ result: ExportResult) {
        let settings = store.settings
        let pasteboard = NSPasteboard.general

        if settings.copyReferenceAfterExport || settings.copyImageAfterExport {
            pasteboard.clearContents()
        }
        if settings.copyImageAfterExport, let image = NSImage(contentsOf: result.url) {
            pasteboard.writeObjects([image])
        }
        if settings.copyReferenceAfterExport {
            pasteboard.setString(result.reference, forType: .string)
        }

        TriCapLog.app.info(
            "export complete: \(result.url.lastPathComponent, privacy: .public) container=\(result.container.rawValue, privacy: .public)"
        )
    }

    // MARK: - Alerts

    private func presentCaptureError(_ error: Error) {
        if case TriCapError.cancelled = error { return }

        if let triCapError = error as? TriCapError {
            switch triCapError {
            case .screenRecordingPermissionDenied, .screenRecordingPermissionNotDetermined:
                presentPermissionDeniedAlert(justRequested: false)
                return
            default:
                break
            }
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Capture failed"
        alert.informativeText = (error as? TriCapError)?.localizedDescription ?? error.localizedDescription
        if let suggestion = (error as? TriCapError)?.recoverySuggestion {
            alert.informativeText += "\n\n" + suggestion
        }
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func presentAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func presentConfirm(title: String, message: String, confirmTitle: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Re-register the hot key when the user changed it in settings.
    private func syncHotKeyRegistration() {
        let desired = store.settings.hotKey
        guard GlobalHotKeyMonitor.shared.registeredCombo != desired else { return }
        registerHotKey()
    }
}

extension AppDelegate: NSWindowDelegate {
    public func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === settingsWindow {
            settingsWindow = nil
            refreshMenu()
            syncHotKeyRegistration()
        }
        editorWindows.removeValue(forKey: ObjectIdentifier(window))
    }
}
