import Foundation
import Testing
@testable import ExportCore
@testable import TriCapKit

/// Creates and removes a scratch directory for each test.
private struct TemporaryDirectory: ~Copyable {
    let url: URL

    init() throws {
        url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tricap-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

@Suite("Output file writing")
struct OutputFileWriterTests {

    @Test("The base name is a sortable timestamp with the configured prefix")
    func baseNameFormat() {
        let date = Date(timeIntervalSince1970: 1_754_200_530)  // 2025-08-03 05:55:30 UTC
        let name = OutputFileWriter.baseName(
            prefix: "TriCap",
            date: date,
            timeZone: TimeZone(identifier: "UTC")!
        )
        #expect(name == "TriCap-2025-08-03-055530")
    }

    @Test("Path separators and other unsafe characters are stripped from the prefix")
    func sanitizesPrefix() {
        #expect(OutputFileWriter.sanitize("a/b:c*d?e\"f<g>h|i") == "abcdefghi")
        #expect(OutputFileWriter.sanitize("   ") == "TriCap")
        #expect(OutputFileWriter.sanitize("") == "TriCap")
        #expect(OutputFileWriter.sanitize("../../etc/passwd") == "....etcpasswd")
        #expect(OutputFileWriter.sanitize(String(repeating: "x", count: 200)).count == 64)
    }

    @Test("The first write uses the plain name")
    func firstWriteUsesPlainName() throws {
        let dir = try TemporaryDirectory()
        let url = try OutputFileWriter.write(Data("one".utf8), to: dir.url, baseName: "shot", fileExtension: "png")
        #expect(url.lastPathComponent == "shot.png")
        #expect(try Data(contentsOf: url) == Data("one".utf8))
    }

    @Test("Colliding names get -1, -2, … and never overwrite an existing file")
    func resolvesCollisions() throws {
        let dir = try TemporaryDirectory()
        let first = try OutputFileWriter.write(Data("one".utf8), to: dir.url, baseName: "shot", fileExtension: "png")
        let second = try OutputFileWriter.write(Data("two".utf8), to: dir.url, baseName: "shot", fileExtension: "png")
        let third = try OutputFileWriter.write(Data("three".utf8), to: dir.url, baseName: "shot", fileExtension: "png")

        #expect(first.lastPathComponent == "shot.png")
        #expect(second.lastPathComponent == "shot-1.png")
        #expect(third.lastPathComponent == "shot-2.png")
        #expect(try Data(contentsOf: first) == Data("one".utf8))
        #expect(try Data(contentsOf: second) == Data("two".utf8))
    }

    @Test("A pre-existing unrelated file with the target name is not clobbered")
    func doesNotClobberForeignFile() throws {
        let dir = try TemporaryDirectory()
        let existing = dir.url.appendingPathComponent("shot.png")
        try Data("precious".utf8).write(to: existing)

        let url = try OutputFileWriter.write(Data("new".utf8), to: dir.url, baseName: "shot", fileExtension: "png")
        #expect(url.lastPathComponent == "shot-1.png")
        #expect(try Data(contentsOf: existing) == Data("precious".utf8))
    }

    @Test("The destination directory is created when missing")
    func createsDirectory() throws {
        let dir = try TemporaryDirectory()
        let nested = dir.url.appendingPathComponent("a/b/c", isDirectory: true)
        let url = try OutputFileWriter.write(Data("x".utf8), to: nested, baseName: "shot", fileExtension: "webp")
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("No temporary files are left behind")
    func cleansUpTemporaries() throws {
        let dir = try TemporaryDirectory()
        _ = try OutputFileWriter.write(Data("x".utf8), to: dir.url, baseName: "shot", fileExtension: "png")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.url.path)
            .filter { $0.hasPrefix(".tricap-") }
        #expect(leftovers.isEmpty)
    }

    @Test("Writing to a read-only directory reports a write failure rather than crashing")
    func readOnlyDirectory() throws {
        let dir = try TemporaryDirectory()
        let locked = dir.url.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path) }

        #expect(throws: TriCapError.self) {
            try OutputFileWriter.write(Data("x".utf8), to: locked, baseName: "shot", fileExtension: "png")
        }
    }

    @Test("Concurrent writers each get a distinct filename")
    func concurrentWritesAreUnique() async throws {
        let dir = try TemporaryDirectory()
        let directory = dir.url

        let urls = await withTaskGroup(of: URL?.self) { group -> [URL] in
            for i in 0..<16 {
                group.addTask {
                    try? OutputFileWriter.write(
                        Data("payload-\(i)".utf8),
                        to: directory,
                        baseName: "race",
                        fileExtension: "png"
                    )
                }
            }
            var collected: [URL] = []
            for await url in group { if let url { collected.append(url) } }
            return collected
        }

        #expect(urls.count == 16)
        #expect(Set(urls.map(\.lastPathComponent)).count == 16)
    }
}
