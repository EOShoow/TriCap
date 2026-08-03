import AppKit
import ExportCore
import SwiftUI
import TriCapKit

/// A transient panel confirming a save, with a way to act on it.
///
/// Before this existed the only confirmation was a line of text inside the editor window, which
/// says nothing about *where* the file went and offers no way to get to it.
@MainActor
final class ExportToastPresenter {

    private var window: NSWindow?
    private var dismissTimer: Timer?
    private var revealURL: URL?

    /// How long the toast stays up when the user does not interact with it.
    static let visibleDuration: TimeInterval = 6

    func show(summary: ExportSummary, fileURL: URL, thumbnail: NSImage?) {
        dismiss()
        revealURL = fileURL

        let content = ToastView(
            summary: summary,
            thumbnail: thumbnail,
            onReveal: { [weak self] in
                self?.reveal()
            },
            onDismiss: { [weak self] in
                self?.dismiss()
            }
        )

        let hosting = NSHostingView(rootView: content)
        hosting.frame = NSRect(x: 0, y: 0, width: 380, height: 118)

        let panel = NSPanel(
            contentRect: hosting.frame,
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.sharingType = .none
        panel.hidesOnDeactivate = false

        position(panel)
        panel.orderFrontRegardless()
        window = panel

        let timer = Timer(timeInterval: Self.visibleDuration, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.dismiss() }
        }
        RunLoop.main.add(timer, forMode: .common)
        dismissTimer = timer

        TriCapLog.app.info("export toast: \(summary.fileName, privacy: .public) — \(summary.clipboardDescription ?? "nothing copied", privacy: .public)")
    }

    func dismiss() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        window?.orderOut(nil)
        window?.close()
        window = nil
        revealURL = nil
    }

    private func reveal() {
        guard let revealURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([revealURL])
        dismiss()
    }

    /// Top-right of the screen holding the menu bar, tucked under it.
    private func position(_ panel: NSWindow) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(
            CGPoint(x: visible.maxX - size.width - 16, y: visible.maxY - size.height - 10)
        )
    }
}

struct ToastView: View {
    let summary: ExportSummary
    let thumbnail: NSImage?
    var onReveal: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            thumbnailView

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Saved").fontWeight(.semibold)
                    Spacer()
                    Button(action: onDismiss) {
                        Image(systemName: "xmark").font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }

                Text(summary.fileName)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text("\(summary.folderDisplayPath) · \(summary.sizeDescription)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)

                if let clipboard = summary.clipboardDescription {
                    Label(clipboard, systemImage: "doc.on.clipboard")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if let warning = summary.warning {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }

                HStack {
                    Spacer()
                    Button("Show in Finder", action: onReveal)
                        .controlSize(.small)
                }
                .padding(.top, 2)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if let thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12))
                )
        } else {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.secondary.opacity(0.15))
                .frame(width: 56, height: 56)
                .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
        }
    }
}

/// Renders the toast on its own, for the offscreen UI-snapshot pass.
struct ExportToastPreview: View {
    let summary: ExportSummary

    var body: some View {
        ToastView(summary: summary, thumbnail: nil, onReveal: {}, onDismiss: {})
            .padding(10)
    }
}
