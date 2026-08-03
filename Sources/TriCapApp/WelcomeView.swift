import AppKit
import CaptureCore
import SwiftUI
import TriCapKit

/// Shown once, the first time TriCap launches.
///
/// A menu-bar app with no Dock icon and no window is invisible on first launch: nothing tells a
/// new user that it started, where it lives, what the shortcut is, or that it needs permission
/// before it can do anything at all. This window answers those four questions and then gets out
/// of the way. It can be reopened from Settings → About.
struct WelcomeView: View {
    let shortcut: HotKeyCombo
    let pinShortcut: HotKeyCombo
    let permissionStatus: ScreenRecordingAuthorization

    var onGrantPermission: () -> Void
    var onOpenSystemSettings: () -> Void
    var onTryCapture: () -> Void
    var onOpenSettings: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            steps
            Divider()
            footer
        }
        .frame(width: 460)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "viewfinder.rectangular")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tint)
                .frame(width: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text("TriCap is running").font(.title2.bold())
                Text("Look for the viewfinder icon in the menu bar. TriCap has no Dock icon — that icon is the app.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 16) {
            step(
                number: 1,
                title: "Allow screen recording",
                systemImage: permissionStatus == .authorized ? "checkmark.circle.fill" : "lock.shield",
                tint: permissionStatus == .authorized ? .green : .orange
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(permissionBody).fixedSize(horizontal: false, vertical: true)
                    switch permissionStatus {
                    case .authorized:
                        EmptyView()
                    case .notDetermined:
                        Button("Ask macOS now", action: onGrantPermission)
                    case .denied:
                        Button("Open System Settings", action: onOpenSystemSettings)
                    }
                }
            }

            step(number: 2, title: "Press \(shortcut.displayString)", systemImage: "keyboard", tint: .secondary) {
                Text("Anywhere, in any app. The screen dims — **click a window** to grab just that window, or drag out any area. Press **R** to record a clip instead, **S** to go back to a screenshot, **Esc** to cancel.")
                    .fixedSize(horizontal: false, vertical: true)
            }

            step(number: 3, title: "Paste it", systemImage: "doc.on.clipboard", tint: .secondary) {
                Text("A screenshot goes straight to the clipboard — nothing is written to disk unless you ask. To annotate with arrows, boxes, text, pen and mosaic, use **Screenshot and Edit…** in the menu, or change the default in Settings.")
                    .fixedSize(horizontal: false, vertical: true)
            }

            step(number: 4, title: "Press \(pinShortcut.displayString) to pin", systemImage: "pin", tint: .secondary) {
                Text("Floats the clipboard image above your other windows so you can keep a reference in view. **Esc** closes it.")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.callout)
        .padding(20)
    }

    private func step<Content: View>(
        number: Int,
        title: String,
        systemImage: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 17))
                .foregroundStyle(tint)
                .frame(width: 24, alignment: .center)
            VStack(alignment: .leading, spacing: 5) {
                Text("\(number). \(title)").fontWeight(.semibold)
                content().foregroundStyle(.secondary)
            }
        }
    }

    private var permissionBody: String {
        switch permissionStatus {
        case .authorized:
            return "Granted. Everything stays on this Mac — TriCap has no network code at all."
        case .notDetermined:
            return "macOS asks once. Without it TriCap cannot see the screen."
        case .denied:
            return "Currently off. Enable TriCap under Privacy & Security → Screen & System Audio Recording, then quit and reopen TriCap."
        }
    }

    private var footer: some View {
        HStack {
            Button("Settings…", action: onOpenSettings)
            Spacer()
            Button("Close", action: onDismiss)
            Button("Take a Screenshot", action: onTryCapture)
                .keyboardShortcut(.defaultAction)
                .disabled(permissionStatus == .denied)
        }
        .padding(20)
    }
}
