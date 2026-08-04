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
    private var welcomeWindow: NSWindow?
    private let editorPresenter = EditorPresenter()
    private let toast = ExportToastPresenter()
    private lazy var pinboard = PinboardController(settingsProvider: { [weak self] in
        self?.store.settings ?? AppSettings()
    })

    private var selector: RegionSelector?
    /// The one live recording, if any. Owned by the running `Task` in `beginCapture`.
    private var recordingSession: RecordingSession?

    /// The pre-encoder for the recording in flight, held only so quitting can release its libwebp
    /// encoder rather than leaving it to a deinit that may never run.
    private var livePreEncoder: LivePreEncoder?

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
        registerPinHotKey()
        pinboard.onCountChanged = { [weak self] in self?.refreshMenu() }

        store.onChange = { [weak self] previous, current in
            guard let self, !self.isRollingBackHotKey else { return }
            var handled = false
            if previous.hotKey != current.hotKey {
                self.registerHotKey(previous: previous.hotKey)
                handled = true
            }
            if previous.pinHotKey != current.pinHotKey {
                self.registerPinHotKey(previous: previous.pinHotKey)
                handled = true
            }
            if !handled { self.refreshMenu() }
        }

        if let error = store.prepareSaveDirectory() {
            TriCapLog.app.error("save directory unavailable: \(error, privacy: .public)")
        }
        TriCapLog.app.info("TriCap \(TriCapVersion.app, privacy: .public) launched (libwebp \(TriCapVersion.libwebpVersion, privacy: .public))")

        // A menu-bar app with no Dock icon is invisible on first launch. Say hello once.
        if !store.hasSeenWelcome {
            store.hasSeenWelcome = true
            showWelcome()
        }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        livePreEncoder?.cancel()
        livePreEncoder = nil
        pinboard.closeAll()
        SharedEscapeKey.claim.reset()
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
        let permission = ScreenRecordingPermission.authorizationStatus()

        // When TriCap cannot capture, say so first and offer the fix — an app whose only two
        // commands silently fail is worse than one that explains itself.
        if permission != .authorized {
            let warning = NSMenuItem(
                title: permission == .denied
                    ? "Screen Recording is turned off"
                    : "Screen Recording not allowed yet",
                action: nil,
                keyEquivalent: ""
            )
            warning.image = NSImage(
                systemSymbolName: permission == .denied ? "exclamationmark.triangle.fill" : "lock.shield",
                accessibilityDescription: nil
            )
            warning.isEnabled = false
            menu.addItem(warning)

            let fix = NSMenuItem(
                title: permission == .denied ? "Open System Settings…" : "Allow Screen Recording…",
                action: permission == .denied ? #selector(openPermissionSettings) : #selector(requestPermissionFromMenu),
                keyEquivalent: ""
            )
            fix.target = self
            menu.addItem(fix)
            menu.addItem(.separator())
        }

        if gate.isBusy {
            let busy = NSMenuItem(title: "Capture in progress…", action: nil, keyEquivalent: "")
            busy.isEnabled = false
            menu.addItem(busy)
        } else {
            let capture = NSMenuItem(
                title: "Capture Region…",
                action: #selector(captureRegion),
                keyEquivalent: ""
            )
            capture.target = self
            capture.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: nil)
            menu.addItem(capture)

            let record = NSMenuItem(
                title: "Record Region…",
                action: #selector(recordRegion),
                keyEquivalent: ""
            )
            record.target = self
            record.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: nil)
            menu.addItem(record)

            // Always available regardless of the configured default, so "annotate this one" never
            // requires a trip through Settings.
            let captureAndEdit = NSMenuItem(
                title: "Screenshot and Edit…",
                action: #selector(captureRegionAndEdit),
                keyEquivalent: ""
            )
            captureAndEdit.target = self
            captureAndEdit.image = NSImage(systemSymbolName: "pencil.tip.crop.circle", accessibilityDescription: nil)
            menu.addItem(captureAndEdit)
        }

        menu.addItem(.separator())

        let pin = NSMenuItem(
            title: "Pin from Clipboard",
            action: #selector(pinFromClipboardFromMenu),
            keyEquivalent: ""
        )
        pin.target = self
        pin.image = NSImage(systemSymbolName: "pin", accessibilityDescription: nil)
        menu.addItem(pin)

        let closePins = NSMenuItem(
            title: pinboard.pinCount > 1 ? "Close All Pins (\(pinboard.pinCount))" : "Close All Pins",
            action: #selector(closeAllPinsFromMenu),
            keyEquivalent: ""
        )
        closePins.target = self
        closePins.isEnabled = pinboard.hasPins
        menu.addItem(closePins)

        menu.addItem(.separator())

        let shortcut = NSMenuItem(
            title: "Screenshot  \(store.settings.hotKey.displayString)      Pin  \(store.settings.pinHotKey.displayString)",
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

        let welcome = NSMenuItem(title: "Getting Started…", action: #selector(showWelcomeFromMenu), keyEquivalent: "")
        welcome.target = self
        menu.addItem(welcome)

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

    /// Apply the configured *pin* shortcut, rolling back independently of the capture shortcut.
    ///
    /// Kept separate on purpose: F3 is Mission Control's factory binding, so this registration is
    /// the one most likely to fail, and its failure must not disturb ⌥⇧5.
    private func registerPinHotKey(previous: HotKeyCombo? = GlobalHotKeyMonitor.shared.combo(in: .pinFromClipboard)) {
        let desired = store.settings.pinHotKey
        let outcome = HotKeyRegistrationPolicy.apply(desired: desired, previous: previous) { combo in
            GlobalHotKeyMonitor.shared.register(
                combo,
                in: .pinFromClipboard,
                allowingNoModifiers: combo.isAllowedAsBareKey
            ) { [weak self] in
                Task { @MainActor in self?.pinFromClipboard() }
            }
        }

        if outcome.rolledBack, let active = outcome.active {
            isRollingBackHotKey = true
            store.settings.pinHotKey = active
            isRollingBackHotKey = false
            presentAlert(
                title: "Pin shortcut unavailable",
                message: "Another app already uses \(desired.displayString), so TriCap kept \(active.displayString). Pick a different pin shortcut in Settings."
            )
        } else if outcome.lostShortcut {
            presentAlert(
                title: "Pin shortcut unavailable",
                message: pinShortcutUnavailableMessage(desired)
            )
        }
        refreshMenu()
    }

    /// F3 is Mission Control's default, and macOS gives the key to whoever registered first — so
    /// say which key failed and what to do, rather than silently binding something else.
    private func pinShortcutUnavailableMessage(_ combo: HotKeyCombo) -> String {
        let base = "TriCap could not claim \(combo.displayString) for pinning."
        let missionControl = combo == .defaultPin
            ? " On Apple keyboards F3 is Mission Control by default; either turn that off under System Settings → Keyboard → Keyboard Shortcuts → Mission Control, or pick a different key here."
            : " Another application already owns it."
        return base + missionControl + " Use “Pin from Clipboard” in the menu meanwhile."
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
                Task { @MainActor in
                    guard let self else { return }
                    self.beginCapture(mode: self.hotKeyLaunchCaptureMode())
                }
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
    @objc private func captureRegionAndEdit() { beginCapture(mode: .still, forceEditor: true) }
    @objc private func recordRegion() { beginCapture(mode: .recording) }

    // MARK: - Pinning

    @objc private func pinFromClipboardFromMenu() { pinFromClipboard() }
    @objc private func closeAllPinsFromMenu() { pinboard.closeAll() }

    /// Pin the clipboard image, and say why when there is nothing to pin.
    ///
    /// Never creates an empty window: a floating rectangle with no content cannot explain itself,
    /// so an empty or non-image clipboard produces a one-line notice instead.
    private func pinFromClipboard() {
        let outcome = pinboard.pinFromClipboard()
        if outcome.isSuccess {
            toast.showNotice(outcome.userMessage, systemImage: "pin.fill", isWarning: false)
        } else {
            toast.showNotice(outcome.userMessage, systemImage: "photo.badge.exclamationmark", isWarning: true)
        }
        refreshMenu()
    }

    @objc private func openPermissionSettings() {
        ScreenRecordingPermission.openSystemSettings()
    }

    @objc private func requestPermissionFromMenu() {
        _ = ScreenRecordingPermission.request()
        refreshMenu()
    }

    @objc private func showWelcomeFromMenu() { showWelcome() }

    /// The first-run window, also reachable from the menu and from Settings → About.
    func showWelcome() {
        if let welcomeWindow {
            NSApp.activate(ignoringOtherApps: true)
            welcomeWindow.makeKeyAndOrderFront(nil)
            return
        }

        let view = WelcomeView(
            shortcut: store.settings.hotKey,
            pinShortcut: store.settings.pinHotKey,
            permissionStatus: ScreenRecordingPermission.authorizationStatus(),
            onGrantPermission: { [weak self] in
                _ = ScreenRecordingPermission.request()
                self?.refreshMenu()
                self?.reopenWelcome()
            },
            onOpenSystemSettings: { ScreenRecordingPermission.openSystemSettings() },
            onTryCapture: { [weak self] in
                self?.closeWelcome()
                self?.beginCapture(mode: .still)
            },
            onOpenSettings: { [weak self] in self?.showSettings() },
            onDismiss: { [weak self] in self?.closeWelcome() }
        )

        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Welcome to TriCap"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        window.delegate = self
        welcomeWindow = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func closeWelcome() {
        welcomeWindow?.close()
        welcomeWindow = nil
    }

    /// Rebuild the window so the permission step reflects the new answer.
    private func reopenWelcome() {
        closeWelcome()
        showWelcome()
    }

    @objc private func openSaveFolder() {
        store.prepareSaveDirectory()
        NSWorkspace.shared.open(store.settings.saveDirectoryURL)
    }

    @objc func showSettings() {
        if let settingsWindow {
            NSApp.activate(ignoringOtherApps: true)
            settingsWindow.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingController(
            rootView: SettingsView(store: store, onShowWelcome: { [weak self] in self?.showWelcome() })
        )
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
    /// The mode the hot key opens with — a fixed choice, or the last completed one.
    private func hotKeyLaunchCaptureMode() -> RegionSelector.CaptureMode {
        let intent = store.settings.hotKeyLaunchMode.effectiveIntent(
            lastUsed: store.settings.lastCaptureIntent
        )
        return intent == .recording ? .recording : .still
    }

    /// Remember what actually completed. Cancellations deliberately do not count: an aborted
    /// picker says nothing about what the user wants next time.
    private func rememberCompletedCaptureIntent(_ mode: RegionSelector.CaptureMode) {
        let intent: CaptureIntent = mode == .recording ? .recording : .still
        guard store.settings.lastCaptureIntent != intent else { return }
        store.settings.lastCaptureIntent = intent
    }

    private func beginCapture(mode: RegionSelector.CaptureMode, forceEditor: Bool = false) {
        guard gate.tryBegin() else { return }
        toast.dismiss()
        refreshMenu()

        Task { @MainActor in
            defer {
                gate.end()
                recordingSession = nil
                selector = nil
                refreshMenu()
            }

            guard await ensurePermission() else { return }

            // Snapshot the window list before the overlay covers everything, so a single click
            // can capture the window the pointer is over.
            let windows = await WindowSurvey.currentWindows()

            let selector = RegionSelector()
            self.selector = selector
            let outcome = await selector.selectRegion(initialMode: mode, windowCandidates: windows)
            self.selector = nil

            switch outcome {
            case .cancelled:
                TriCapLog.app.info("capture cancelled at selection")
            case .selected(let region, .still):
                rememberCompletedCaptureIntent(.still)
                gate.transition(to: .capturingStill)
                await captureStill(region: region, forceEditor: forceEditor)
            case .selected(let region, .recording):
                rememberCompletedCaptureIntent(.recording)
                await recordClip(region: region)
            }
        }
    }

    private func captureStill(region: CaptureRegion, forceEditor: Bool) async {
        // Give the window server one turn to actually remove the overlay before we sample the
        // screen. The content filter already excludes TriCap, but this also avoids catching the
        // dimming layer's fade-out on slower machines.
        try? await Task.sleep(nanoseconds: 80_000_000)

        do {
            let still = try await StillCaptureService.capture(region: region)

            // The common case is "capture, then paste", so that is the default: no window, no
            // file on disk until the user asks for one. `forceEditor` is the menu's
            // "Screenshot and Edit…", which overrides the setting for one capture.
            let action = forceEditor ? .openEditor : store.settings.stillCaptureAction
            switch action {
            case .openEditor:
                presentEditor(source: .still(still))
            case .copyToClipboard:
                copyStillToClipboard(still)
            }
        } catch {
            presentCaptureError(error)
        }
    }

    /// Put a finished screenshot on the clipboard, and only claim success if it got there.
    private func copyStillToClipboard(_ still: CapturedStill) {
        guard let receipt = PasteboardImage.write(still.image) else {
            // A refused pasteboard write is recoverable: the capture is still in memory, so offer
            // the editor rather than dropping it on the floor.
            presentClipboardFailure(still)
            return
        }

        let notice = ClipboardCopyNotice.success(
            width: still.image.width,
            height: still.image.height,
            wroteRasterData: receipt.wroteRasterData,
            colorNotice: still.colorSpace.userFacingNotice
        )
        toast.showNotice(notice.message, systemImage: notice.systemImage, isWarning: notice.isWarning)
        TriCapLog.app.info("screenshot copied to clipboard: \(receipt.types.joined(separator: ","), privacy: .public)")
    }

    private func presentClipboardFailure(_ still: CapturedStill) {
        TriCapLog.app.error("clipboard write refused every representation")
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Could not copy the screenshot"
        alert.informativeText = "The clipboard refused the image. The capture is still open — you can annotate and save it instead."
        alert.addButton(withTitle: "Open Editor")
        alert.addButton(withTitle: "Discard")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            presentEditor(source: .still(still))
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

        let recorder = RegionRecorder(region: region, limits: limits)

        // Encode frames as they arrive rather than all at once after Export. The pre-encoder is
        // never load-bearing: if it falls behind, fails, or the user trims or annotates, the
        // export takes the ordinary per-frame route and nothing is lost.
        let preEncoder = LivePreEncoder(
            canvasSize: recorder.pixelSize,
            options: store.settings.animatedWebPOptions,
            frameRate: limits.frameRate
        )
        livePreEncoder = preEncoder
        recorder.onFrameAccepted = { [weak preEncoder] image, timestamp in
            preEncoder?.submit(image: image, captureTimestamp: timestamp)
        }

        let session = RecordingSession(
            backend: recorder,
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

        livePreEncoder = nil
        switch outcome {
        case .finished(let clip):
            // The end timestamp is the one thing that cannot be known live: it depends on the
            // measured wall-clock duration, which is only final once capture stops.
            let endTimestampMs = ClipTiming.timeline(
                for: clip.frames,
                nominalFrameInterval: clip.nominalFrameInterval,
                totalDuration: clip.duration
            )?.endTimestampMs
            var artifact: PreEncodedAnimation?
            if let endTimestampMs {
                // Draining can block, so it happens off the main actor. In practice the queue is
                // nearly empty by now: encoding keeps up with capture.
                artifact = await Task.detached(priority: .userInitiated) {
                    preEncoder.finish(endTimestampMs: endTimestampMs)
                }.value
            } else {
                preEncoder.cancel()
            }
            presentEditor(source: .clip(clip), preEncoded: artifact)
        case .cancelled:
            preEncoder.cancel()
            TriCapLog.app.info("recording cancelled by user")
        case .failed(let error):
            preEncoder.cancel()
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

    private func presentEditor(source: EditorSource, preEncoded: PreEncodedAnimation? = nil) {
        editorPresenter.present(
            source: source,
            settings: store.settings,
            windowDelegate: self,
            preEncoded: preEncoded,
            onExported: { [weak self] result in self?.handleExport(result) }
        )
    }

    private func handleExport(_ result: ExportResult) {
        let settings = store.settings
        let pasteboard = NSPasteboard.general

        // Track what actually happened rather than what the settings asked for, so the
        // confirmation can never claim a copy that did not take place.
        var copiedImage = false
        var copiedReference = false

        if settings.copyReferenceAfterExport || settings.copyImageAfterExport {
            pasteboard.clearContents()
        }
        if settings.copyImageAfterExport, let image = NSImage(contentsOf: result.url) {
            copiedImage = pasteboard.writeObjects([image])
        }
        if settings.copyReferenceAfterExport {
            copiedReference = pasteboard.setString(result.reference, forType: .string)
        }

        // A reference that is a bare path is a different promise from a Markdown embed; the
        // summary says which so the user knows what they are about to paste.
        let insideVault = settings.markdownVaultRootURL.map { root in
            MarkdownReference.relativePath(of: result.url, inside: root) != nil
        } ?? false

        let summary = ExportSummary.make(
            from: result,
            copiedReference: copiedReference,
            copiedImage: copiedImage,
            insideVault: insideVault
        )
        toast.show(summary: summary, fileURL: result.url, thumbnail: thumbnail(for: result.url))

        TriCapLog.app.info(
            "export complete: \(result.url.lastPathComponent, privacy: .public) container=\(result.container.rawValue, privacy: .public) clipboard=\(summary.clipboardDescription ?? "none", privacy: .public)"
        )
    }

    /// A small preview for the toast. Best-effort: a missing thumbnail just shows a placeholder.
    private func thumbnail(for url: URL) -> NSImage? {
        guard let image = NSImage(contentsOf: url) else { return nil }
        image.size = NSSize(width: 112, height: 112)
        return image
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
        if window === welcomeWindow {
            welcomeWindow = nil
            return
        }
        editorPresenter.release(window)
    }
}
