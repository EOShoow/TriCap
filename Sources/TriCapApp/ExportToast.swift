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

    static let width: CGFloat = 380
    /// Floor for the no-warning case, so a short toast still looks deliberate.
    static let minimumHeight: CGFloat = 132

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

        // Fix the width, then let the content decide the height: a colour-space or
        // motionless-recording warning wraps to two or three lines and must not be clipped.
        let hosting = NSHostingView(rootView: content)
        hosting.frame = NSRect(x: 0, y: 0, width: Self.width, height: 1)
        let fittingHeight = hosting.fittingSize.height
        hosting.frame = NSRect(
            x: 0, y: 0,
            width: Self.width,
            height: max(Self.minimumHeight, fittingHeight)
        )

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

    /// A one-line notice with no file behind it — "pinned", "the clipboard has no image".
    ///
    /// Shares the toast's placement and auto-dismiss so every transient message in TriCap appears
    /// in the same corner, but carries no thumbnail and no Show-in-Finder action because there is
    /// nothing to reveal.
    func showNotice(_ message: String, systemImage: String, isWarning: Bool) {
        dismiss()

        let hosting = NSHostingView(rootView: NoticeView(message: message, systemImage: systemImage, isWarning: isWarning))
        hosting.frame = NSRect(x: 0, y: 0, width: Self.width, height: 1)
        hosting.frame = NSRect(x: 0, y: 0, width: Self.width, height: max(52, hosting.fittingSize.height))

        let panel = makePanel(contentView: hosting)
        position(panel)
        panel.orderFrontRegardless()
        window = panel

        let timer = Timer(timeInterval: 3, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.dismiss() }
        }
        RunLoop.main.add(timer, forMode: .common)
        dismissTimer = timer
    }

    private func makePanel(contentView: NSView) -> NSPanel {
        let panel = NSPanel(
            contentRect: contentView.frame,
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.contentView = contentView
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.sharingType = .none
        panel.hidesOnDeactivate = false
        return panel
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

                // What was actually produced: dimensions, format, and for a clip its frame count
                // and playback length. Without this the confirmation cannot answer "did I get the
                // whole recording?" — which is the main thing a user wants to know.
                Text(summary.detailDescription)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

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
                        .lineLimit(3)
                        // Let the label grow the panel instead of being cut off; the panel is
                        // sized from its content below.
                        .fixedSize(horizontal: false, vertical: true)
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

/// A transient one-line message with no artefact behind it.
private struct NoticeView: View {
    let message: String
    let systemImage: String
    let isWarning: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage)
                .foregroundStyle(isWarning ? Color.orange : Color.accentColor)
            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
    }
}
