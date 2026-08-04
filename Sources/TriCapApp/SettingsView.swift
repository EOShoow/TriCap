import AppKit
import CaptureCore
import ExportCore
import SwiftUI
import TriCapKit

/// The settings window.
///
/// Four tabs, each answering one question: *how do I start a capture*, *how good should it look*,
/// *where does it go*, and *what is this*. Quality is its own tab because it is the only area with
/// a real information hierarchy — a named choice most people never look past, and the encoder
/// parameters behind it for the people who do.
struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var loginItem: LoginItemController
    @State private var hotKeyError: String?
    @State private var pinHotKeyError: String?
    @State private var showAdvancedQuality: Bool

    /// Injected by the app so the About tab can reopen the welcome window.
    var onShowWelcome: (() -> Void)?

    init(
        store: SettingsStore,
        loginItem: LoginItemController = LoginItemController(),
        onShowWelcome: (() -> Void)? = nil,
        initiallyExpandAdvancedQuality: Bool = false
    ) {
        self.store = store
        self.loginItem = loginItem
        self.onShowWelcome = onShowWelcome
        _showAdvancedQuality = State(initialValue: initiallyExpandAdvancedQuality)
    }

    var body: some View {
        TabView {
            generalTab.tabItem { Label("General", systemImage: "gearshape") }
            qualityTab.tabItem { Label("Quality", systemImage: "dial.high") }
            outputTab.tabItem { Label("Output", systemImage: "square.and.arrow.down") }
            aboutTab.tabItem { Label("About", systemImage: "info.circle") }
        }
        // Tall enough that the General tab — two shortcuts, the post-screenshot action, the
        // countdown, launch-at-login and the permission row — fits without scrolling. The Form
        // still scrolls if a longer explanation wraps, but nothing important should need hunting.
        .frame(width: 540, height: 780)
    }

    // MARK: - General

    private var generalTab: some View {
        Form {
            Section {
                HStack {
                    Text("Screenshot")
                    Spacer()
                    HotKeyRecorder(
                        combo: $store.settings.hotKey,
                        errorMessage: $hotKeyError
                    )
                }
                if let hotKeyError {
                    Text(hotKeyError).font(.caption).foregroundStyle(.red)
                }
                Picker("Shortcut opens", selection: $store.settings.hotKeyLaunchMode) {
                    ForEach(HotKeyLaunchMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                Text(store.settings.hotKeyLaunchMode.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("In the picker: **click a window** to capture it, or drag out any area — hold **⌥** while dragging to ignore edge snapping. **R** switches to recording, **S** back to a screenshot, **Esc** cancels.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Capture shortcut")
            }

            Section {
                HStack {
                    Text("Pin")
                    Spacer()
                    HotKeyRecorder(
                        combo: $store.settings.pinHotKey,
                        errorMessage: $pinHotKeyError
                    )
                }
                if let pinHotKeyError {
                    Text(pinHotKeyError).font(.caption).foregroundStyle(.red)
                }
                Text("Pins whatever image is on the clipboard as a floating window that stays above other apps. **Esc** closes the front one. On Apple keyboards **F3** is Mission Control by default — if TriCap cannot claim it, it says so and keeps working from the menu.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Pin shortcut")
            }

            Section {
                Picker("After a screenshot", selection: $store.settings.stillCaptureAction) {
                    ForEach(StillCaptureAction.allCases) { action in
                        Text(action.displayName).tag(action)
                    }
                }
                Text(store.settings.stillCaptureAction.summary)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Screenshots")
            }

            Section {
                LabeledContent("Countdown before recording") {
                    Stepper(
                        store.settings.countdownSeconds == 0 ? "Off" : "\(store.settings.countdownSeconds) s",
                        value: $store.settings.countdownSeconds,
                        in: AppSettings.countdownRange
                    )
                }
                Text("Gives you time to get the window ready. **Esc** cancels during the countdown and during the recording itself, even while another app is in front.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Recording")
            }

            Section {
                loginItemRow
            } header: {
                Text("Startup")
            }

            Section {
                permissionRow
            } header: {
                Text("Screen recording permission")
            }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
        .onAppear { loginItem.refresh() }
    }

    /// Launch at login, driven entirely by `SMAppService.mainApp.status` — the system's answer is
    /// re-read on every appearance and after every toggle, never cached in AppSettings.
    private var loginItemRow: some View {
        let presentation = loginItem.presentation
        return VStack(alignment: .leading, spacing: 8) {
            Toggle(
                "Open TriCap at login",
                isOn: Binding(
                    get: { presentation.toggleIsOn },
                    set: { loginItem.setEnabled($0) }
                )
            )
            .accessibilityLabel("Open TriCap at login")
            .accessibilityHint("Adds or removes TriCap in System Settings Login Items. Off by default.")

            if let statusText = presentation.statusText {
                HStack(alignment: .top) {
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(presentation.isWarning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .fixedSize(horizontal: false, vertical: true)
                    if presentation.offersSystemSettings {
                        Spacer()
                        Button("Open Login Items Settings…") { loginItem.openSystemSettings() }
                            .font(.caption)
                    }
                }
            }
            if let error = loginItem.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Login item error: \(error)")
            }
        }
    }

    private var permissionRow: some View {
        let status = ScreenRecordingPermission.authorizationStatus()
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                switch status {
                case .authorized:
                    Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .denied:
                    Label("Turned off", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                case .notDetermined:
                    Label("Not requested yet", systemImage: "questionmark.circle").foregroundStyle(.orange)
                }
                Spacer()
                Button("Open System Settings") { ScreenRecordingPermission.openSystemSettings() }
            }
            Text(permissionExplanation(for: status))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func permissionExplanation(for status: ScreenRecordingAuthorization) -> String {
        switch status {
        case .authorized:
            return "TriCap can capture the screen. Nothing is uploaded — every capture stays on this Mac."
        case .denied:
            return "macOS will not ask again. Enable TriCap under Privacy & Security → Screen & System Audio Recording, then quit and reopen TriCap."
        case .notDetermined:
            return "macOS will ask the first time you capture. TriCap cannot see anything until you allow it."
        }
    }

    // MARK: - Quality

    private var qualityPresetBinding: Binding<QualityPreset> {
        Binding(
            get: { store.settings.qualityPreset },
            set: { store.settings.applyQualityPreset($0) }
        )
    }

    var qualityTab: some View {
        Form {
            Section {
                Picker("Quality", selection: qualityPresetBinding) {
                    ForEach(QualityPreset.selectable) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                    if store.settings.qualityPreset == .custom {
                        Divider()
                        Text(QualityPreset.custom.displayName).tag(QualityPreset.custom)
                    }
                }
                Text(store.settings.qualityPreset.summary)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("How good should captures look?")
            }

            Section {
                Picker("Screenshot format", selection: $store.settings.stillFormat) {
                    ForEach([OutputFormat.png, .jpeg, .webp], id: \.self) { format in
                        Text(format.displayName).tag(format)
                    }
                }
                Text(store.settings.stillFormat.qualityExplanation)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Screenshots")
            }

            Section {
                DisclosureGroup("Advanced encoder settings", isExpanded: $showAdvancedQuality) {
                    // Only the parameters that actually do something for the chosen format.
                    if store.settings.stillFormat.usesQualityParameter {
                        LabeledContent("\(store.settings.stillFormat.displayName) quality") {
                            Stepper(
                                "\(store.settings.stillQuality)",
                                value: $store.settings.stillQuality,
                                in: 0...100,
                                step: 5
                            )
                        }
                    } else {
                        LabeledContent("\(store.settings.stillFormat.displayName) quality") {
                            Text("Lossless — no setting")
                                .foregroundStyle(.secondary)
                        }
                    }

                    Divider()

                    LabeledContent("Recording longest edge") {
                        Stepper(
                            "\(store.settings.recordingLimits.maxLongEdgePixels) px",
                            value: $store.settings.recordingLimits.maxLongEdgePixels,
                            in: RecordingLimits.longEdgeRange,
                            step: 80
                        )
                    }
                    LabeledContent("Recording frame rate") {
                        Stepper(
                            "\(store.settings.recordingLimits.frameRate) fps",
                            value: $store.settings.recordingLimits.frameRate,
                            in: RecordingLimits.frameRateRange
                        )
                    }
                    LabeledContent("Maximum recording length") {
                        Stepper(
                            "\(Int(store.settings.recordingLimits.maxDuration)) s",
                            value: Binding(
                                get: { Int(store.settings.recordingLimits.maxDuration) },
                                set: { store.settings.recordingLimits.maxDuration = TimeInterval($0) }
                            ),
                            in: Int(RecordingLimits.durationRange.lowerBound)...Int(RecordingLimits.durationRange.upperBound)
                        )
                    }
                    LabeledContent("Animated WebP quality") {
                        Stepper(
                            "\(store.settings.animatedWebPOptions.quality)",
                            value: $store.settings.animatedWebPOptions.quality,
                            in: AnimatedWebPOptions.qualityRange,
                            step: 5
                        )
                    }
                    Toggle("Loop the animation forever", isOn: Binding(
                        get: { store.settings.animatedWebPOptions.loopCount == 0 },
                        set: { store.settings.animatedWebPOptions.loopCount = $0 ? 0 : 1 }
                    ))

                    Text("Changing any of these switches the preset above to **Custom**. Nothing you set here is ever overwritten by a preset unless you pick one.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Advanced")
            } footer: {
                markdown(sizeGuidance)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
    }

    /// `Text` from a runtime-built Markdown string.
    ///
    /// `Text("literal **bold**")` parses Markdown because the literal becomes a
    /// `LocalizedStringKey`; a `String` built at runtime does not, and renders the asterisks.
    private func markdown(_ string: String) -> Text {
        Text((try? AttributedString(markdown: string)) ?? AttributedString(string))
    }

    /// Plain-language explanation of the three levers, plus the current budget.
    ///
    /// Deliberately qualitative. TriCap has not measured file sizes across representative screen
    /// content, so a precise claim ("halving the long edge quarters the file") would be a number
    /// invented to sound authoritative. What *is* safe to say is the ordering of the levers and
    /// the reason for it, plus the memory budget, which is computed rather than guessed.
    private var sizeGuidance: String {
        let limits = store.settings.recordingLimits
        return """
        For a recording, **resolution** and **frame rate** usually move the file size much more \
        than the **quality** factor does: fewer pixels and fewer frames means less to encode at \
        all, while the quality factor only changes how hard each frame is squeezed. Exactly how \
        much depends on what is on screen — a mostly-still window compresses very differently \
        from a video. At these settings TriCap holds at most \(limits.maxFrameCount) frames, \
        capped at \(limits.maxFrameBufferBytes / 1_048_576) MB, for up to \
        \(Int(limits.maxDuration)) s. TriCap never records audio.
        """
    }

    // MARK: - Output

    private var outputTab: some View {
        Form {
            Section {
                directoryRow(
                    title: "Save to",
                    path: store.settings.saveDirectoryPath,
                    onPick: { url in store.settings.saveDirectoryPath = url.path },
                    onClear: nil
                )
                HStack {
                    Spacer()
                    Button("Open Folder") {
                        store.prepareSaveDirectory()
                        NSWorkspace.shared.open(store.settings.saveDirectoryURL)
                    }
                }
                TextField("Filename starts with", text: $store.settings.filenamePrefix)
                markdown("Files are named `\(OutputFileWriterPreview.example(prefix: store.settings.filenamePrefix, format: store.settings.stillFormat))`. An existing name is never overwritten — TriCap adds `-1`, `-2`, and so on.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Where captures go")
            }

            Section {
                directoryRow(
                    title: "Vault root",
                    path: store.settings.markdownVaultRootPath ?? "Not set",
                    onPick: { url in store.settings.markdownVaultRootPath = url.path },
                    onClear: { store.settings.markdownVaultRootPath = nil }
                )
                Picker("Reference style", selection: $store.settings.markdownLinkStyle) {
                    ForEach(MarkdownLinkStyle.allCases, id: \.self) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                Text("Save inside the vault and TriCap copies a **relative** reference you can paste straight into a note. Save anywhere else and it copies the **full file path** instead, because a relative link would not resolve.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Markdown / Obsidian")
            }

            Section {
                Toggle("Copy the reference after saving", isOn: $store.settings.copyReferenceAfterExport)
                Toggle("Also copy the image itself", isOn: $store.settings.copyImageAfterExport)
                Text("With both on, the clipboard holds the image *and* the text reference; apps take whichever they understand.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Clipboard")
            }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
    }

    private func directoryRow(
        title: String,
        path: String,
        onPick: @escaping (URL) -> Void,
        onClear: (() -> Void)?
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
            Spacer()
            Text((path as NSString).abbreviatingWithTildeInPath)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: 220, alignment: .trailing)
            Button("Choose…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.allowsMultipleSelection = false
                panel.canCreateDirectories = true
                if panel.runModal() == .OK, let url = panel.url { onPick(url) }
            }
            if let onClear {
                Button("Clear", action: onClear)
            }
        }
    }

    // MARK: - About

    private var aboutTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("TriCap").font(.title2.bold())
            Text("Region screenshots and short animated WebP clips, entirely on this Mac.")
                .foregroundStyle(.secondary)

            Divider()

            Label("No network code, no telemetry, no cloud sync.", systemImage: "lock.shield")
            Label("Animated WebP encoded by libwebp \(TriCapVersion.libwebpVersion), compiled into the app.", systemImage: "shippingbox")
            Label("Captures via ScreenCaptureKit; nothing leaves this machine.", systemImage: "display")

            Spacer()

            HStack {
                if let onShowWelcome {
                    Button("Show Getting Started…", action: onShowWelcome)
                }
                Spacer()
                Button("Reset all settings") { store.resetToDefaults() }
            }
        }
        .padding(20)
    }
}

/// Builds the example filename shown in the Output tab, using the same rules as the real writer.
enum OutputFileWriterPreview {
    static func example(prefix: String, format: OutputFormat) -> String {
        let base = OutputFileWriter.baseName(
            prefix: prefix,
            date: Date(timeIntervalSince1970: 1_754_200_530),
            timeZone: TimeZone(identifier: "UTC") ?? .current
        )
        return "\(base).\(format.fileExtension)"
    }
}

/// Captures the next key press and turns it into a ``HotKeyCombo``.
private struct HotKeyRecorder: NSViewRepresentable {
    @Binding var combo: HotKeyCombo
    @Binding var errorMessage: String?

    func makeNSView(context: Context) -> HotKeyRecorderView {
        let view = HotKeyRecorderView()
        view.onCapture = { newCombo in
            guard let newCombo else {
                errorMessage = "A shortcut needs one of ⌘ ⌥ ⌃ ⇧, or a function key on its own."
                return
            }
            errorMessage = nil
            combo = newCombo
        }
        return view
    }

    func updateNSView(_ view: HotKeyRecorderView, context: Context) {
        view.combo = combo
    }
}

private final class HotKeyRecorderView: NSView {
    var combo: HotKeyCombo = .default { didSet { button.title = combo.displayString } }
    var onCapture: ((HotKeyCombo?) -> Void)?

    private let button = NSButton(title: HotKeyCombo.default.displayString, target: nil, action: nil)
    private var monitor: Any?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        button.bezelStyle = .rounded
        button.target = self
        button.action = #selector(startRecording)
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 90),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The monitor is torn down as soon as a key is captured (see `startRecording`), and again
    /// when the view leaves the hierarchy, so there is no `deinit` cleanup — an `NSEvent` monitor
    /// token is not `Sendable` and cannot be touched from a nonisolated `deinit`.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopRecording() }
    }

    @objc private func startRecording() {
        guard monitor == nil else { return }
        button.title = "Press keys…"
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            defer { self.stopRecording() }
            if event.keyCode == 53 { return nil }  // Esc keeps the current shortcut
            self.onCapture?(HotKeyCombo.from(event: event))
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        button.title = combo.displayString
    }
}
