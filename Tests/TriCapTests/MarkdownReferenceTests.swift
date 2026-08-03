import Foundation
import Testing
@testable import ExportCore
@testable import TriCapKit

@Suite("Markdown reference")
struct MarkdownReferenceTests {

    let vault = URL(fileURLWithPath: "/Users/someone/Documents/Vault", isDirectory: true)

    @Test("A file directly inside the vault gets a bare relative reference")
    func directChild() {
        let file = vault.appendingPathComponent("shot.png")
        #expect(MarkdownReference.relativePath(of: file, inside: vault) == "shot.png")
        #expect(MarkdownReference.reference(for: file, vaultRoot: vault) == "![shot](shot.png)")
    }

    @Test("A nested file gets a multi-component relative path")
    func nestedChild() {
        let file = vault.appendingPathComponent("assets/screens/shot.png")
        #expect(MarkdownReference.relativePath(of: file, inside: vault) == "assets/screens/shot.png")
        #expect(
            MarkdownReference.reference(for: file, vaultRoot: vault)
                == "![shot](assets/screens/shot.png)"
        )
    }

    @Test("A file outside the vault falls back to the absolute path with no Markdown syntax")
    func outsideVault() {
        let file = URL(fileURLWithPath: "/Users/someone/Pictures/TriCap/shot.png")
        #expect(MarkdownReference.relativePath(of: file, inside: vault) == nil)
        #expect(MarkdownReference.reference(for: file, vaultRoot: vault) == "/Users/someone/Pictures/TriCap/shot.png")
    }

    @Test("With no vault configured the absolute path is always used")
    func noVaultConfigured() {
        let file = vault.appendingPathComponent("shot.png")
        #expect(MarkdownReference.reference(for: file, vaultRoot: nil) == "/Users/someone/Documents/Vault/shot.png")
    }

    @Test("A sibling directory sharing the vault's name prefix is not treated as inside it")
    func siblingPrefixIsNotInside() {
        let file = URL(fileURLWithPath: "/Users/someone/Documents/VaultBackup/shot.png")
        #expect(MarkdownReference.relativePath(of: file, inside: vault) == nil)
    }

    @Test("The vault root itself is not a file inside the vault")
    func rootIsNotInside() {
        #expect(MarkdownReference.relativePath(of: vault, inside: vault) == nil)
    }

    @Test("`..` in the path is resolved before the containment check")
    func dotDotIsResolved() {
        let sneaky = URL(fileURLWithPath: "/Users/someone/Documents/Vault/assets/../../Other/shot.png")
        #expect(MarkdownReference.relativePath(of: sneaky, inside: vault) == nil)
    }

    @Test("Containment is case-insensitive, matching APFS's default behaviour")
    func caseInsensitiveMatching() {
        let file = URL(fileURLWithPath: "/Users/someone/documents/vault/assets/shot.png")
        #expect(MarkdownReference.relativePath(of: file, inside: vault) == "assets/shot.png")
    }

    @Test("Symlinked roots resolve so /tmp and /private/tmp agree")
    func symlinkResolution() throws {
        // /tmp is a symlink to /private/tmp on macOS. The vault root is given through the
        // symlink and the file through the real path; a naive prefix compare would say the file
        // is outside the vault.
        let name = "tricap-symlink-test-\(UUID().uuidString)"
        let root = URL(fileURLWithPath: "/tmp/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let real = URL(fileURLWithPath: "/private/tmp/\(name)/assets/shot.png")
        try FileManager.default.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: real)

        #expect(MarkdownReference.relativePath(of: real, inside: root) == "assets/shot.png")
    }

    @Test("A file that does not exist yet still resolves against a symlinked root")
    func symlinkResolutionForUncreatedFile() throws {
        let name = "tricap-symlink-pending-\(UUID().uuidString)"
        let root = URL(fileURLWithPath: "/tmp/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let pending = URL(fileURLWithPath: "/private/tmp/\(name)/not-written-yet.png")
        #expect(MarkdownReference.relativePath(of: pending, inside: root) == "not-written-yet.png")
    }

    @Test("Spaces and parentheses are percent-encoded so the Markdown link stays intact")
    func percentEncoding() {
        let file = vault.appendingPathComponent("my notes/screen (final).png")
        let reference = MarkdownReference.reference(for: file, vaultRoot: vault)
        #expect(reference == "![screen (final)](my%20notes/screen%20%28final%29.png)")
        // Slashes must stay literal or the path stops being a path.
        #expect(reference.contains("%2F") == false)
    }

    @Test("Non-ASCII path components are percent-encoded")
    func unicodeEncoding() {
        let file = vault.appendingPathComponent("截图/示例.png")
        let relative = MarkdownReference.percentEncodedForMarkdown("截图/示例.png")
        #expect(relative.contains("%"))
        #expect(relative.contains("/"))
        #expect(MarkdownReference.reference(for: file, vaultRoot: vault).hasPrefix("!["))
    }

    @Test("Obsidian wiki-link style emits the raw, unencoded relative path")
    func wikiLinkStyle() {
        let file = vault.appendingPathComponent("my notes/screen.png")
        #expect(
            MarkdownReference.reference(for: file, vaultRoot: vault, style: .wikiLink)
                == "![[my notes/screen.png]]"
        )
    }

    @Test("Wiki-link style still falls back to the absolute path outside the vault")
    func wikiLinkOutsideVault() {
        let file = URL(fileURLWithPath: "/Users/someone/Desktop/shot.png")
        #expect(
            MarkdownReference.reference(for: file, vaultRoot: vault, style: .wikiLink)
                == "/Users/someone/Desktop/shot.png"
        )
    }

    @Test("A trailing slash on the configured root does not break containment")
    func trailingSlashRoot() {
        let rootWithSlash = URL(fileURLWithPath: "/Users/someone/Documents/Vault/", isDirectory: true)
        let file = URL(fileURLWithPath: "/Users/someone/Documents/Vault/shot.png")
        #expect(MarkdownReference.relativePath(of: file, inside: rootWithSlash) == "shot.png")
    }
}
