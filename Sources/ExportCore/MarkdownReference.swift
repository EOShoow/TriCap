import Foundation
import TriCapKit

/// Builds the string TriCap puts on the clipboard after an export.
///
/// Rule (from the product spec): if the exported file lives **inside** the configured
/// Markdown/Obsidian vault root, copy a *relative* image reference; otherwise copy the plain
/// absolute file path. A relative reference is what makes the note portable, and an absolute
/// path is the only honest thing to offer when the file is outside the vault.
public enum MarkdownReference {

    /// Path components of `file` relative to `root`, or `nil` when `file` is not inside `root`.
    ///
    /// Both URLs are resolved through symlinks and standardised first, because `/tmp` is a symlink
    /// to `/private/tmp` on macOS and a naive prefix comparison would report "outside the vault"
    /// for a file that is plainly inside it. The comparison is component-wise rather than
    /// string-prefix so that `/Vault` does not appear to contain `/VaultBackup/x.png`.
    public static func relativeComponents(of file: URL, inside root: URL) -> [String]? {
        let fileComponents = normalizedComponents(file)
        let rootComponents = normalizedComponents(root)

        guard !rootComponents.isEmpty, fileComponents.count > rootComponents.count else { return nil }
        // Case-insensitivity matches APFS's default (and HFS+): a vault at /Users/x/Vault must
        // still match a file reported as /Users/x/vault/shot.png.
        for (index, component) in rootComponents.enumerated() {
            guard fileComponents[index].compare(component, options: .caseInsensitive) == .orderedSame else {
                return nil
            }
        }
        return Array(fileComponents.dropFirst(rootComponents.count))
    }

    /// Forward-slash relative path, or `nil` when the file is outside the root.
    public static func relativePath(of file: URL, inside root: URL) -> String? {
        relativeComponents(of: file, inside: root).map { $0.joined(separator: "/") }
    }

    /// The clipboard payload for an exported file.
    public static func reference(
        for file: URL,
        vaultRoot: URL?,
        style: MarkdownLinkStyle = .markdown
    ) -> String {
        guard let vaultRoot, let relative = relativePath(of: file, inside: vaultRoot) else {
            return file.standardizedFileURL.path
        }
        switch style {
        case .markdown:
            return "![\(file.deletingPathExtension().lastPathComponent)](\(percentEncodedForMarkdown(relative)))"
        case .wikiLink:
            // Obsidian resolves wiki-links itself and expects the raw, unencoded path.
            return "![[\(relative)]]"
        }
    }

    /// Percent-encode a relative path for use inside `![](...)`.
    ///
    /// `/` stays literal so the path is still readable. Parentheses are escaped because they
    /// would otherwise terminate the Markdown link target early, and spaces become `%20` because
    /// CommonMark link destinations cannot contain raw spaces.
    public static func percentEncodedForMarkdown(_ path: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "()")
        return path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
    }

    /// Path components with the volume root, `.`/`..` and symlinks resolved away.
    ///
    /// `URL.resolvingSymlinksInPath()` only rewrites the portion of a path that actually exists on
    /// disk, so calling it on a not-yet-created file leaves `/tmp` unresolved while the configured
    /// vault root (which does exist) becomes `/private/tmp` — and the containment check then fails
    /// for a file that is plainly inside the vault. Resolving the deepest existing ancestor and
    /// re-appending the remaining components makes both sides normalise the same way.
    private static func normalizedComponents(_ url: URL) -> [String] {
        let fileManager = FileManager.default
        var trailing: [String] = []
        var probe = url.standardizedFileURL

        while !fileManager.fileExists(atPath: probe.path) {
            let parent = probe.deletingLastPathComponent().standardizedFileURL
            if parent.path == probe.path { break }  // reached the volume root
            trailing.insert(probe.lastPathComponent, at: 0)
            probe = parent
        }

        let resolved = probe.resolvingSymlinksInPath().standardizedFileURL
        let existing = resolved.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        return existing + trailing.filter { $0 != "/" && !$0.isEmpty }
    }
}
