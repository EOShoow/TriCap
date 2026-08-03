import AppKit
import CaptureCore
import SwiftUI
import TriCapKit

/// The settings window.
struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    @State private var hotKeyCapture = false
    @State private var hotKeyError: String?

    var body: some View {
        TabView {
            generalTab.tabItem { Label("General", systemImage: "gearshape") }
            recordingTab.tabItem { Label("Recording", systemImage: "record.circle") }
            outputTab.tabItem { Label("Output", systemImage: "square.and.arrow.down") }
            aboutTab.tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 520, height: 430)
    }

    // MARK: - General

    private var generalTab: some View {
        Form {
            Section {
                HStack {
                    Text("Shortcut")
                    Spacer()
                    HotKeyRecorder(
                        combo: $store.settings.hotKey,
                        isRecording: $hotKeyCapture,
                        errorMessage: $hotKeyError
                    )
                }
                if let hotKeyError {
                    Text(hotKeyError).font(.caption).foregroundStyle(.red)
                }
                Text("Opens the region picker. Press R in the picker to record instead, S to go back to a screenshot, Esc to cancel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Global shortcut")
            }

            Section {
                permissionRow
            } header: {
                Text("Screen recording permission")
            }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
    }

    private var permissionRow: some View {
        let status = ScreenRecordingPermission.authorizationStatus()
        return HStack(alignment: .top) {
            switch status {
            case .authorized:
                Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .denied:
                VStack(alignment: .leading, spacing: 4) {
                    Label("Denied", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                    Text("macOS will not ask again. Enable TriCap in System Settings, then relaunch it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            case .notDetermined:
                VStack(alignment: .leading, spacing: 4) {
                    Label("Not requested yet", systemImage: "questionmark.circle").foregroundStyle(.orange)
                    Text("TriCap asks the first time you capture.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Open System Settings") { ScreenRecordingPermission.openSystemSettings() }
        }
    }

    // MARK: - Recording

    private var recordingTab: some View {
        Form {
            Section {
                LabeledContent("Frame rate") {
                    Stepper(
                        "\(store.settings.recordingLimits.frameRate) fps",
                        value: $store.settings.recordingLimits.frameRate,
                        in: RecordingLimits.frameRateRange
                    )
                }
                LabeledContent("Maximum length") {
                    Stepper(
                        "\(Int(store.settings.recordingLimits.maxDuration)) s",
                        value: Binding(
                            get: { Int(store.settings.recordingLimits.maxDuration) },
                            set: { store.settings.recordingLimits.maxDuration = TimeInterval($0) }
                        ),
                        in: Int(RecordingLimits.durationRange.lowerBound)...Int(RecordingLimits.durationRange.upperBound)
                    )
                }
                LabeledContent("Longest edge") {
                    Stepper(
                        "\(store.settings.recordingLimits.maxLongEdgePixels) px",
                        value: $store.settings.recordingLimits.maxLongEdgePixels,
                        in: RecordingLimits.longEdgeRange,
                        step: 80
                    )
                }
                LabeledContent("Countdown") {
                    Stepper(
                        store.settings.countdownSeconds == 0 ? "Off" : "\(store.settings.countdownSeconds) s",
                        value: $store.settings.countdownSeconds,
                        in: AppSettings.countdownRange
                    )
                }
                Text("At \(store.settings.recordingLimits.frameRate) fps for \(Int(store.settings.recordingLimits.maxDuration)) s TriCap holds at most \(store.settings.recordingLimits.maxFrameCount) frames, capped at \(store.settings.recordingLimits.maxFrameBufferBytes / 1_048_576) MB.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Limits")
            }

            Section {
                LabeledContent("Quality") {
                    Stepper(
                        "\(store.settings.animatedWebPOptions.quality)",
                        value: $store.settings.animatedWebPOptions.quality,
                        in: AnimatedWebPOptions.qualityRange,
                        step: 5
                    )
                }
                Toggle("Loop forever", isOn: Binding(
                    get: { store.settings.animatedWebPOptions.loopCount == 0 },
                    set: { store.settings.animatedWebPOptions.loopCount = $0 ? 0 : 1 }
                ))
                Text("Animated WebP only. TriCap never records audio.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Animated WebP")
            }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
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
            } header: {
                Text("Location")
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
                Text("Files saved inside the vault get a relative reference on the clipboard. Anything outside it gets the absolute file path instead.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Markdown / Obsidian")
            }

            Section {
                Picker("Screenshot format", selection: $store.settings.stillFormat) {
                    ForEach([OutputFormat.png, .jpeg, .webp], id: \.self) { format in
                        Text(format.displayName).tag(format)
                    }
                }
                LabeledContent("Quality") {
                    Stepper(
                        "\(store.settings.stillQuality)",
                        value: $store.settings.stillQuality,
                        in: 0...100,
                        step: 5
                    )
                }
                TextField("Filename prefix", text: $store.settings.filenamePrefix)
                Toggle("Copy reference after saving", isOn: $store.settings.copyReferenceAfterExport)
                Toggle("Also copy the image itself", isOn: $store.settings.copyImageAfterExport)
            } header: {
                Text("Files")
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
                Spacer()
                Button("Reset all settings") { store.resetToDefaults() }
            }
        }
        .padding(20)
    }
}

/// Captures the next key press and turns it into a ``HotKeyCombo``.
private struct HotKeyRecorder: NSViewRepresentable {
    @Binding var combo: HotKeyCombo
    @Binding var isRecording: Bool
    @Binding var errorMessage: String?

    func makeNSView(context: Context) -> HotKeyRecorderView {
        let view = HotKeyRecorderView()
        view.onCapture = { newCombo in
            guard let newCombo else {
                errorMessage = "A shortcut needs at least one of ⌘ ⌥ ⌃ ⇧."
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
