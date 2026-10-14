import AppKit
import Foundation

/// A temporary file representation for receivers that only paste files (including Chromium).
/// No file ever goes to the user's Save folder. Replaced clipboard files are removed promptly;
/// the active file stays readable even if TriCap quits before the user pastes it.
@MainActor
public enum AnimationClipboardFileStore {
    public static var directory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("app.tricap-clipboard", isDirectory: true)
    }

    /// Let a receiver finish importing an attachment after the user replaces the clipboard.
    public static let retirementGraceInterval: TimeInterval = 300

    private final class Entry {
        let board: NSPasteboard
        let changeCount: Int
        let url: URL
        var retiredAt: Date?

        init(board: NSPasteboard, changeCount: Int, url: URL) {
            self.board = board
            self.changeCount = changeCount
            self.url = url
        }
    }
    private static var entries: [Entry] = []
    private static var cleanupTimer: Timer?

    static func stage(_ data: Data) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent("TriCap-\(UUID().uuidString).gif")
        do {
            try data.write(to: url, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            try? fm.removeItem(at: url)
            throw error
        }
        return url
    }

    static func retain(_ url: URL, for board: NSPasteboard) {
        entries.append(Entry(board: board, changeCount: board.changeCount, url: url))
        removeExpiredFiles()
        if board.name == .general { removeOrphanedFiles() }
        if cleanupTimer == nil {
            cleanupTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
                Task { @MainActor in removeExpiredFiles() }
            }
        }
    }

    /// Only files that TriCap created for a clipboard item are eligible for cleanup.
    public static func removeExpiredFiles(now: Date = Date()) {
        entries.removeAll { entry in
            guard entry.board.changeCount != entry.changeCount else {
                entry.retiredAt = nil
                return false
            }
            // Another application can rewrite the clipboard while retaining this same file.
            guard entry.board.string(forType: .fileURL) != entry.url.absoluteString else {
                entry.retiredAt = nil
                return false
            }
            if entry.retiredAt == nil { entry.retiredAt = now }
            guard now.timeIntervalSince(entry.retiredAt ?? now) >= retirementGraceInterval else { return false }
            try? FileManager.default.removeItem(at: entry.url)
            return true
        }
        if entries.isEmpty {
            cleanupTimer?.invalidate()
            cleanupTimer = nil
        }
    }

    /// Clean old cache entries left by an earlier app launch, preserving the active clipboard.
    public static func removeOrphanedFiles() {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]
        ) else { return }
        let activeURL = NSPasteboard.general.string(forType: .fileURL)
        let tracked = Set(entries.map(\.url))
        for url in urls where url.lastPathComponent.hasPrefix("TriCap-") && url.pathExtension == "gif" {
            guard !tracked.contains(url), url.absoluteString != activeURL,
                  let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  Date().timeIntervalSince(modified) > 86_400 else { continue }
            try? fm.removeItem(at: url)
        }
    }
}
