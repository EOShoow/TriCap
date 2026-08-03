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
    private let editorPresenter = EditorPresenter()

    private var selector: RegionSelector?
    /// The one live recording, if any. Owned by the running `Task` in `beginCapture`.
    private var recordingSession: RecordingSession?

    /// The single gate every capture entry point goes through. It stays occupied for the whole
    /// pipeline — selection, countdown, recording, teardown and the editor hand-off — so a second
    /// hot-key press or menu click while a recording is live is refused instead of overwriting the
    /// live recorder, HUD and cancel key.
    private let gate = CaptureSessionGate()

    /// Guards against `registerHotKey()` re-entering itself when a failed registration rolls the
    /// stored setting back (which itself fires `store.onChange`).
    private var isRollingBackHotKey = false

    // MARK: - Lifecycle

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installStatusItem()
        registerHotKey()

        store.onChange = { [weak self] previous, current in
            guard let self, !self.isRollingBackHotKey else { return }
            if previous.hotKey != current.hotKey {
                self.registerHotKey(previous: previous.hotKey)
            } else {
                self.refreshMenu()
            }
        }

        if let error = store.prepareSaveDirectory() {
            TriCapLog.app.error("save directory unavailable: \(error, privacy: .public)")
        }
        TriCapLog.app.info("TriCap \(TriCapVersion.app, privacy: .public) launched (libwebp \(TriCapVersion.libwebpVersion, privacy: .public))")
    }

    public func applicationWillTerminate(_ notification: Notification) {
        GlobalHotKeyMonitor.shared.unregisterAll()
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

    /// Apply the configured shortcut, rolling back to the previous one if the new one is taken.
    ///
    /// The failure mode this guards against: `RegisterEventHotKey` needs the old key released
    /// before the new one is claimed, so a rejected new combination used to leave TriCap with no
    /// working shortcut at all.
    private func registerHotKey(previous: HotKeyCombo? = GlobalHotKeyMonitor.shared.registeredCombo) {
        let desired = store.settings.hotKey
        let outcome = HotKeyRegistrationPolicy.apply(desired: desired, previous: previous) { combo in
            GlobalHotKeyMonitor.shared.register(combo, in: .primaryCapture) { [weak self] in
                Task { @MainActor in self?.beginCapture(mode: .still) }
            }
        }

        if outcome.rolledBack, let active = outcome.active {
            // Put the setting back so the UI, the menu and the registration all agree.
            isRollingBackHotKey = true
            store.settings.hotKey = active
            isRollingBackHotKey = false
            presentAlert(
                title: "Shortcut unavailable",
                message: "Another app already uses \(desired.displayString), so TriCap kept \(active.displayString). Pick a different shortcut in Settings."
            )
        } else if outcome.lostShortcut {
            presentAlert(
                title: "Shortcut unavailable",
                message: "TriCap could not claim \(desired.displayString). Use the menu-bar item, or pick a different shortcut in Settings."
            )
        }
        refreshMenu()
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

    /// The single entry point for every capture. The hot key and both menu items call this.
    ///
    /// The gate is held for the *entire* pipeline and released in one place, after the recording
    /// has been fully torn down. `recordClip` therefore awaits `RecordingSession.run()` rather
    /// than returning as soon as the HUD is on screen — which is what previously let a second
    /// trigger overwrite the live recorder, HUD, stop target and cancel key.
    private func beginCapture(mode: RegionSelector.CaptureMode) {
        guard gate.tryBegin() else { return }

        Task { @MainActor in
            defer {
                gate.end()
                recordingSession = nil
                selector = nil
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
                gate.transition(to: .capturingStill)
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
        let chrome = RecordingChromeController()

        gate.transition(to: .countdown)
        guard await chrome.runCountdown(seconds: store.settings.countdownSeconds, over: region) else {
            chrome.dismiss()
            TriCapLog.app.info("recording cancelled during countdown")
            return
        }

        let session = RecordingSession(
            backend: RegionRecorder(region: region, limits: limits),
            chrome: chrome,
            region: region,
            limits: limits
        )
        recordingSession = session
        gate.transition(to: .recording)

        // Returns only once the recorder and the chrome are fully torn down.
        let outcome = await session.run()
        gate.transition(to: .finishing)
        recordingSession = nil

        if session.ignoredStopRequests > 0 {
            TriCapLog.app.info(
                "ignored \(session.ignoredStopRequests, privacy: .public) duplicate stop/cancel request(s)"
            )
        }

        switch outcome {
        case .finished(let clip):
            presentEditor(source: .clip(clip))
        case .cancelled:
            TriCapLog.app.info("recording cancelled by user")
        case .failed(let error):
            presentCaptureError(error)
        }
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
        editorPresenter.present(
            source: source,
            settings: store.settings,
            windowDelegate: self,
            onExported: { [weak self] result in self?.handleExport(result) }
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

}

extension AppDelegate: NSWindowDelegate {
    public func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === settingsWindow {
            settingsWindow = nil
            refreshMenu()
            return
        }
        editorPresenter.release(window)
    }
}
