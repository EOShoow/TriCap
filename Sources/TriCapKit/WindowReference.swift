import CoreGraphics
import Foundation

/// What Claude needs to find the window the user means: the app and the window's identity.
///
/// No screenshot and no coordinates. Claude's computer-use tools list and read the live window
/// themselves, and their `window_id` is this same macOS CGWindowID.
public struct WindowReference: Equatable, Sendable {
    public let applicationName: String?
    public let bundleIdentifier: String
    public let processID: Int32
    /// The macOS CGWindowID.
    public let windowID: UInt32
    public let windowTitle: String?

    public init?(window: WindowCandidate) {
        guard let bundle = window.bundleIdentifier, !bundle.isEmpty,
              let pid = window.processID, pid > 0, window.id != 0 else { return nil }
        applicationName = Self.visibleText(window.applicationName)
        bundleIdentifier = bundle
        processID = pid
        windowID = window.id
        windowTitle = Self.visibleText(window.title)
    }

    /// Drops invisible format characters (Unicode category Cf: zero-width spaces and joiners,
    /// BOMs, bidi controls). Feishu prefixes document titles with dozens of them, likely a
    /// watermark; Claude's tools then withhold the title, and they would be pasted verbatim.
    static func visibleText(_ text: String?) -> String? {
        guard let text else { return nil }
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: text.unicodeScalars.filter { $0.properties.generalCategory != .format })
        let cleaned = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Smaller than this, a window is a floating accessory — a screen-sharing badge, a tooltip, a
    /// toolbar strip — not what the user means by "this window". Feishu's sharing button, a 66×20 pt
    /// window stacked above its document window, is what made this rule necessary.
    public static let minimumWindowSize = CGSize(width: 200, height: 100)

    /// The window Command-Command means: the front app's topmost ordinary window, skipping floating
    /// accessories smaller than ``minimumWindowSize`` unless the app has nothing larger.
    ///
    /// - Parameter frontmostProcessID: the front app's PID, or `nil` when TriCap itself is in
    ///   front (its menu or Settings), in which case the topmost window of any other app is used.
    /// - Returns: `nil` when the front app has no ordinary window; never another app's window.
    public static func frontWindow(
        in windows: [WindowCandidate],
        frontmostProcessID: Int32?,
        ownBundleIdentifier: String?
    ) -> WindowCandidate? {
        let ordered = WindowPicker.selectableWindows(in: windows, ownBundleIdentifier: ownBundleIdentifier)
        let candidates = frontmostProcessID.map { pid in ordered.filter { $0.processID == pid } } ?? ordered
        let isFullSize = { (window: WindowCandidate) in
            window.frame.width >= minimumWindowSize.width && window.frame.height >= minimumWindowSize.height
        }
        return candidates.first(where: isFullSize) ?? candidates.first
    }

    /// A short label for the confirmation toast.
    public var displayName: String {
        let app = applicationName ?? bundleIdentifier
        guard let title = windowTitle, !title.isEmpty, title != app else { return app }
        return "\(title) — \(app)"
    }

    /// What goes on the clipboard: one line of JSON and nothing else, so the user pastes it next to
    /// their own request. Window titles are untrusted data: JSON escaping keeps quotes and newlines
    /// inside the string, and backticks are escaped so a title cannot open a Markdown code block.
    public func json() throws -> String {
        struct Payload: Encodable {
            let app: String?
            let bundleId: String
            let pid: Int32
            let windowId: UInt32
            let title: String?
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(Payload(
            app: applicationName, bundleId: bundleIdentifier, pid: processID,
            windowId: windowID, title: windowTitle
        ))
        return String(decoding: data, as: UTF8.self).replacingOccurrences(of: "`", with: "\\u0060")
    }
}
