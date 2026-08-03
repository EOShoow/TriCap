import Foundation
import TriCapKit

/// Builds the string TriCap puts on the clipboard after an export.
///
/// Rule (from the product spec): if the exported file lives **inside** the configured
/// Markdown/Obsidian vault root, copy a *relative* image reference; otherwise copy the plain
/// absolute file path. A relative reference is what makes the note portable, and an absolute
/// path is the only honest thing to offer when the file is outside the vault.
public enum MarkdownReference {

    /// How two path components should be compared.
    ///
    /// This is not cosmetic. On a case-sensitive volume `Vault/shot.png` and `vault/shot.png` are
    /// two different files, so comparing case-insensitively there would emit a relative reference
    /// that does not resolve. APFS is case-*insensitive* by default but can be formatted
    /// case-sensitive, and network mounts vary, so the answer has to come from the volume rather
    /// than from an assumption.
    public enum CaseSensitivity: String, Sendable, Equatable {
        case sensitive
        case insensitive
    }

    // MARK: - Containment

    /// Path components of `file` relative to `root`, or `nil` when `file` is not inside `root`.
    ///
    /// Both paths are resolved through symlinks and standardised first, because `/tmp` is a
    /// symlink to `/private/tmp` on macOS and a naive prefix comparison would report "outside the
    /// vault" for a file that is plainly inside it. The comparison is component-wise rather than
    /// string-prefix so that `/Vault` does not appear to contain `/VaultBackup/x.png`.
    ///
    /// Pure: the caller supplies the comparison rule.
    public static func relativeComponents(
        of file: URL,
        inside root: URL,
        caseSensitivity: CaseSensitivity
    ) -> [String]? {
        let fileComponents = normalizedComponents(file)
        let rootComponents = normalizedComponents(root)
        return relativeComponents(
            fileComponents: fileComponents,
            rootComponents: rootComponents,
            caseSensitivity: caseSensitivity
        )
    }

    /// The comparison itself, on already-normalised components. Split out so the rule can be
    /// tested exhaustively without needing a case-sensitive volume to exist.
    public static func relativeComponents(
        fileComponents: [String],
        rootComponents: [String],
        caseSensitivity: CaseSensitivity
    ) -> [String]? {
        guard !rootComponents.isEmpty, fileComponents.count > rootComponents.count else { return nil }
        for (index, component) in rootComponents.enumerated() {
            let candidate = fileComponents[index]
            let matches: Bool
            switch caseSensitivity {
            case .sensitive:
                matches = candidate == component
            case .insensitive:
                matches = candidate.compare(component, options: .caseInsensitive) == .orderedSame
            }
            guard matches else { return nil }
        }
        return Array(fileComponents.dropFirst(rootComponents.count))
    }

    /// Convenience overload that asks the volume how it compares names.
    public static func relativeComponents(of file: URL, inside root: URL) -> [String]? {
        relativeComponents(of: file, inside: root, caseSensitivity: volumeCaseSensitivity(for: root))
    }

    /// Forward-slash relative path, or `nil` when the file is outside the root.
    public static func relativePath(of file: URL, inside root: URL) -> String? {
        relativeComponents(of: file, inside: root).map { $0.joined(separator: "/") }
    }

    public static func relativePath(
        of file: URL,
        inside root: URL,
        caseSensitivity: CaseSensitivity
    ) -> String? {
        relativeComponents(of: file, inside: root, caseSensitivity: caseSensitivity)
            .map { $0.joined(separator: "/") }
    }

    /// Ask the volume containing `url` whether it distinguishes case in file names.
    ///
    /// Uses the public `URLResourceKey.volumeSupportsCaseSensitiveNamesKey`. When the answer is
    /// unavailable (the path does not exist yet, or the volume does not report the attribute) it
    /// falls back to `.sensitive`. That may conservatively produce an absolute path on an unusual
    /// case-insensitive volume, but it cannot emit a relative reference that fails to resolve on a
    /// case-sensitive network volume.
    public static func volumeCaseSensitivity(for url: URL) -> CaseSensitivity {
        let standardized = url.standardizedFileURL
        guard FileManager.default.fileExists(atPath: standardized.path) else { return .sensitive }
        let values = try? standardized.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        return caseSensitivity(reportedByVolume: values?.volumeSupportsCaseSensitiveNames)
    }

    /// Convert the optional volume capability into a containment rule. `nil` is deliberately
    /// conservative: rejecting a relative path is recoverable (the absolute path still works),
    /// while accepting one under the wrong case rule produces a broken Markdown reference.
    static func caseSensitivity(reportedByVolume value: Bool?) -> CaseSensitivity {
        guard let value else { return .sensitive }
        return value ? .sensitive : .insensitive
    }

    // MARK: - Reference strings

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

    // MARK: - Path normalisation

    /// Path components with the volume root, `.`/`..` and symlinks resolved away.
    ///
    /// `URL.resolvingSymlinksInPath()` only rewrites the portion of a path that actually exists on
    /// disk, so calling it on a not-yet-created file leaves `/tmp` unresolved while the configured
    /// vault root (which does exist) becomes `/private/tmp` — and the containment check then fails
    /// for a file that is plainly inside the vault. Resolving the deepest existing ancestor and
    /// re-appending the remaining components makes both sides normalise the same way.
    public static func normalizedComponents(_ url: URL) -> [String] {
        let standardized = url.standardizedFileURL
        var trailing: [String] = []
        var probe = standardized
        let fileManager = FileManager.default

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

    /// The deepest ancestor of `url` (including itself) that exists on disk.
    static func deepestExistingAncestor(of url: URL) -> URL? {
        var probe = url.standardizedFileURL
        let fileManager = FileManager.default
        while !fileManager.fileExists(atPath: probe.path) {
            let parent = probe.deletingLastPathComponent().standardizedFileURL
            if parent.path == probe.path { return nil }
            probe = parent
        }
        return probe
    }
}
