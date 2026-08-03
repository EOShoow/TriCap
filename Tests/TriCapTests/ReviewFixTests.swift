import CoreGraphics
import Foundation
import Testing
@testable import CaptureCore
@testable import ExportCore
@testable import TriCapKit

// MARK: - A3: colour-space outcome survives to the editor

@Suite("Colour space propagation")
struct ColorSpacePropagationTests {

    private let wideGamut = ImageProcessing.ColorSpaceOutcome(
        sourceName: "kCGColorSpaceDisplayP3",
        converted: true,
        wasWideGamutOrHDR: true
    )
    private let plainSRGB = ImageProcessing.ColorSpaceOutcome(
        sourceName: "kCGColorSpaceSRGB",
        converted: false,
        wasWideGamutOrHDR: false
    )

    @Test("A wide-gamut recording carries a notice the editor can show")
    func wideGamutClipHasNotice() {
        // The regression: `RegionRecorder.finish()` used to read the colour space from the stream
        // output *after* teardown had already released it, so this was always nil and the notice
        // could never appear for a recording.
        let clip = TestFixtures.clip(
            frames: [RecordedFrame(pngData: Data([1]), timestamp: 0)],
            wallClockDuration: 1,
            colorSpace: wideGamut
        )
        #expect(clip.colorSpace != nil)
        let notice = try? #require(clip.colorSpaceNotice)
        #expect(notice?.contains("kCGColorSpaceDisplayP3") == true)
        #expect(notice?.contains("sRGB") == true)
    }

    @Test("A plain sRGB recording produces no notice")
    func sRGBClipHasNoNotice() {
        let clip = TestFixtures.clip(
            frames: [RecordedFrame(pngData: Data([1]), timestamp: 0)],
            wallClockDuration: 1,
            colorSpace: plainSRGB
        )
        #expect(clip.colorSpace != nil)
        #expect(clip.colorSpaceNotice == nil)
    }

    @Test("A missing outcome is distinguishable from an sRGB one")
    func missingOutcome() {
        let clip = TestFixtures.clip(
            frames: [RecordedFrame(pngData: Data([1]), timestamp: 0)],
            wallClockDuration: 1,
            colorSpace: nil
        )
        #expect(clip.colorSpace == nil)
        #expect(clip.colorSpaceNotice == nil)
    }

    @Test("Trimming a clip does not drop its colour-space outcome")
    func trimPreservesColorSpace() {
        let frames = (0..<6).map { RecordedFrame(pngData: Data([UInt8($0)]), timestamp: Double($0) / 12.0) }
        let clip = TestFixtures.clip(frames: frames, wallClockDuration: 0.5, colorSpace: wideGamut)
        let trimmed = ClipTrimmer.trim(clip: clip, first: 1, last: 4)
        #expect(trimmed.colorSpace == wideGamut)
        #expect(trimmed.colorSpaceNotice != nil)
    }

    @Test("Every wide-gamut and HDR space TriCap knows about produces a notice")
    func allWideSpacesNotice() {
        for name in [
            CGColorSpace.displayP3, CGColorSpace.displayP3_PQ, CGColorSpace.displayP3_HLG,
            CGColorSpace.itur_2020, CGColorSpace.itur_2100_PQ, CGColorSpace.itur_2100_HLG,
            CGColorSpace.extendedSRGB, CGColorSpace.adobeRGB1998,
        ] {
            let space = CGColorSpace(name: name)
            #expect(ImageProcessing.isWideGamutOrHDR(space), "expected \(name) to be flagged")
        }
        #expect(!ImageProcessing.isWideGamutOrHDR(CGColorSpace(name: CGColorSpace.sRGB)))
    }
}

// MARK: - B10: single-frame clips expose no phantom index

@Suite("Clip trim slider ranges")
struct ClipTrimUITests {

    @Test("A single-frame clip is not trimmable and offers no slider ranges")
    func singleFrameHasNoSliders() {
        #expect(!ClipTrimUI.isTrimmable(frameCount: 1))
        #expect(ClipTrimUI.handleRange(frameCount: 1) == nil)
        #expect(ClipTrimUI.scrubRange(trimStart: 0, trimEnd: 0) == nil)
    }

    @Test("An empty clip is not trimmable either")
    func emptyClip() {
        #expect(!ClipTrimUI.isTrimmable(frameCount: 0))
        #expect(ClipTrimUI.handleRange(frameCount: 0) == nil)
    }

    @Test("A multi-frame clip's handle range stops at the last real index")
    func handleRangeStopsAtLastIndex() {
        // The bug this pins: the range used to be padded with `max(1, count - 1)`, so a
        // one-frame clip advertised index 1 and a two-frame clip was indistinguishable from it.
        #expect(ClipTrimUI.isTrimmable(frameCount: 2))
        #expect(ClipTrimUI.handleRange(frameCount: 2) == 0...1)
        #expect(ClipTrimUI.handleRange(frameCount: 12) == 0...11)
    }

    @Test("The scrub range never extends past the trim handles")
    func scrubRangeStaysInsideTrim() {
        #expect(ClipTrimUI.scrubRange(trimStart: 2, trimEnd: 9) == 2...9)
        // Collapsed trim: no scrubbing, and certainly not to trimStart + 1.
        #expect(ClipTrimUI.scrubRange(trimStart: 5, trimEnd: 5) == nil)
        #expect(ClipTrimUI.scrubRange(trimStart: 7, trimEnd: 3) == nil)
    }
}

// MARK: - B6: hot-key registration roll-back

@Suite("Hot key registration roll-back")
struct HotKeyRegistrationPolicyTests {

    let old = HotKeyCombo(keyCode: 23, carbonModifiers: HotKeyCombo.CarbonModifier.option.rawValue
        | HotKeyCombo.CarbonModifier.shift.rawValue)
    let new = HotKeyCombo(keyCode: 17, carbonModifiers: HotKeyCombo.CarbonModifier.command.rawValue
        | HotKeyCombo.CarbonModifier.control.rawValue)

    @Test("A shortcut that registers is simply applied")
    func successfulRegistration() {
        var attempts: [HotKeyCombo] = []
        let result = HotKeyRegistrationPolicy.apply(desired: new, previous: old) { combo in
            attempts.append(combo)
            return true
        }
        #expect(result.active == new)
        #expect(!result.rolledBack)
        #expect(!result.lostShortcut)
        #expect(attempts == [new])
    }

    @Test("A rejected shortcut rolls back to the previous one")
    func rollbackToPrevious() {
        // The regression: registration releases the old key before claiming the new one, so a
        // rejected new combination used to leave TriCap with no working shortcut at all.
        var attempts: [HotKeyCombo] = []
        let result = HotKeyRegistrationPolicy.apply(desired: new, previous: old) { combo in
            attempts.append(combo)
            return combo == old
        }
        #expect(result.active == old)
        #expect(result.rolledBack)
        #expect(!result.lostShortcut)
        #expect(attempts == [new, old])
    }

    @Test("With no previous shortcut a rejection is reported as a lost shortcut")
    func noPreviousToRollBackTo() {
        let result = HotKeyRegistrationPolicy.apply(desired: new, previous: nil) { _ in false }
        #expect(result.active == nil)
        #expect(result.lostShortcut)
        #expect(!result.rolledBack)
    }

    @Test("When both the new and the old shortcut fail, that is reported rather than hidden")
    func bothFail() {
        var attempts: [HotKeyCombo] = []
        let result = HotKeyRegistrationPolicy.apply(desired: new, previous: old) { combo in
            attempts.append(combo)
            return false
        }
        #expect(result.active == nil)
        #expect(result.lostShortcut)
        #expect(attempts == [new, old])
    }

    @Test("Re-applying the same shortcut does not attempt it twice")
    func sameComboIsNotRetried() {
        var attempts: [HotKeyCombo] = []
        let result = HotKeyRegistrationPolicy.apply(desired: old, previous: old) { combo in
            attempts.append(combo)
            return false
        }
        #expect(attempts == [old])
        #expect(result.lostShortcut)
    }

    @Test("A bare Escape is never valid as the configurable shortcut")
    func bareEscapeIsNotAValidUserShortcut() {
        // It is registrable only through the explicit `allowingNoModifiers` opt-in used by the
        // transient recording-cancel slot.
        #expect(!HotKeyCombo(keyCode: 53, carbonModifiers: 0).isValid)
        #expect(HotKeyCombo.default.isValid)
    }
}

// MARK: - B7: case sensitivity follows the volume

@Suite("Markdown containment case sensitivity")
struct MarkdownCaseSensitivityTests {

    let vault = URL(fileURLWithPath: "/Users/someone/Documents/Vault", isDirectory: true)

    @Test("On a case-sensitive volume a differing case is outside the vault")
    func caseSensitiveRejectsDifferentCase() {
        // The regression: containment was unconditionally case-insensitive, so on a
        // case-sensitive volume TriCap would emit a relative reference that does not resolve.
        let file = URL(fileURLWithPath: "/Users/someone/documents/vault/assets/shot.png")
        #expect(MarkdownReference.relativePath(of: file, inside: vault, caseSensitivity: .sensitive) == nil)
        #expect(
            MarkdownReference.relativePath(of: file, inside: vault, caseSensitivity: .insensitive)
                == "assets/shot.png"
        )
    }

    @Test("On a case-sensitive volume an exactly matching path is still inside")
    func caseSensitiveAcceptsExactMatch() {
        let file = vault.appendingPathComponent("assets/shot.png")
        #expect(
            MarkdownReference.relativePath(of: file, inside: vault, caseSensitivity: .sensitive)
                == "assets/shot.png"
        )
    }

    @Test("The comparison rule is exercised directly on components")
    func componentRule() {
        let root = ["Users", "x", "Vault"]
        let file = ["Users", "x", "vault", "a.png"]

        #expect(
            MarkdownReference.relativeComponents(
                fileComponents: file, rootComponents: root, caseSensitivity: .insensitive
            ) == ["a.png"]
        )
        #expect(
            MarkdownReference.relativeComponents(
                fileComponents: file, rootComponents: root, caseSensitivity: .sensitive
            ) == nil
        )
        // A sibling that merely shares a prefix is outside under either rule.
        #expect(
            MarkdownReference.relativeComponents(
                fileComponents: ["Users", "x", "VaultBackup", "a.png"],
                rootComponents: root,
                caseSensitivity: .insensitive
            ) == nil
        )
        // The root itself is not a file inside the root.
        #expect(
            MarkdownReference.relativeComponents(
                fileComponents: root, rootComponents: root, caseSensitivity: .insensitive
            ) == nil
        )
    }

    @Test("The volume is asked, and this machine's answer is used consistently")
    func volumeDetectionIsUsed() throws {
        // This machine's temporary directory is on the boot volume; whatever it reports, the
        // convenience overload must agree with the explicit one.
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tricap-case-\(UUID().uuidString)", isDirectory: true)
        let assets = scratch.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let file = assets.appendingPathComponent("shot.png")
        try Data("x".utf8).write(to: file)

        let detected = MarkdownReference.volumeCaseSensitivity(for: scratch)
        #expect(detected == .sensitive || detected == .insensitive)
        #expect(
            MarkdownReference.relativePath(of: file, inside: scratch)
                == MarkdownReference.relativePath(of: file, inside: scratch, caseSensitivity: detected)
        )
        // An exact-case path is inside the vault regardless of which rule the volume uses.
        #expect(MarkdownReference.relativePath(of: file, inside: scratch) == "assets/shot.png")
    }

    @Test("An unknown path falls back to case-insensitive, the macOS default")
    func unknownPathFallsBack() {
        let missing = URL(fileURLWithPath: "/definitely/not/a/real/volume/\(UUID().uuidString)")
        #expect(MarkdownReference.volumeCaseSensitivity(for: missing) == .insensitive)
    }
}

// MARK: - B8: filename claiming on volumes without hard links

@Suite("Output file claim strategies")
struct FileClaimStrategyTests {

    private func scratchDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tricap-claim-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Each strategy in isolation must satisfy the same contract: never overwrite, always land the
    /// full bytes, and pick a fresh name on collision. exFAT and SMB volumes reject `link(2)`, and
    /// there is no such volume on this machine to reproduce that on — forcing the strategy list is
    /// how the fallbacks get covered.
    @Test("Every claim strategy writes, never overwrites, and resolves collisions", arguments: OutputFileWriter.ClaimStrategy.allCases)
    func strategyContract(strategy: OutputFileWriter.ClaimStrategy) throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let first = try OutputFileWriter.writeReportingStrategy(
            Data("one".utf8), to: dir, baseName: "shot", fileExtension: "png", strategies: [strategy]
        )
        #expect(first.strategy == strategy)
        #expect(first.url.lastPathComponent == "shot.png")
        #expect(try Data(contentsOf: first.url) == Data("one".utf8))

        let second = try OutputFileWriter.writeReportingStrategy(
            Data("two".utf8), to: dir, baseName: "shot", fileExtension: "png", strategies: [strategy]
        )
        #expect(second.url.lastPathComponent == "shot-1.png")
        #expect(try Data(contentsOf: first.url) == Data("one".utf8))
        #expect(try Data(contentsOf: second.url) == Data("two".utf8))

        // A pre-existing foreign file must survive untouched.
        let foreign = dir.appendingPathComponent("shot-2.png")
        try Data("precious".utf8).write(to: foreign)
        let third = try OutputFileWriter.writeReportingStrategy(
            Data("three".utf8), to: dir, baseName: "shot", fileExtension: "png", strategies: [strategy]
        )
        #expect(third.url.lastPathComponent == "shot-3.png")
        #expect(try Data(contentsOf: foreign) == Data("precious".utf8))
    }

    @Test("Large payloads survive the exclusive-create path in full")
    func exclusiveCreateWritesEveryByte() throws {
        // The O_EXCL fallback writes the bytes itself rather than publishing a finished temp file,
        // so its write loop needs to handle partial writes.
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        var payload = Data()
        payload.reserveCapacity(3 * 1024 * 1024)
        for i in 0..<(3 * 1024 * 1024) { payload.append(UInt8(i % 251)) }

        let outcome = try OutputFileWriter.writeReportingStrategy(
            payload, to: dir, baseName: "big", fileExtension: "webp", strategies: [.exclusiveCreate]
        )
        #expect(outcome.strategy == .exclusiveCreate)
        #expect(try Data(contentsOf: outcome.url) == payload)
    }

    @Test("Concurrent writers get distinct names under every strategy", arguments: OutputFileWriter.ClaimStrategy.allCases)
    func concurrentClaimsAreUnique(strategy: OutputFileWriter.ClaimStrategy) async throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let urls = await withTaskGroup(of: URL?.self) { group -> [URL] in
            for i in 0..<16 {
                group.addTask {
                    try? OutputFileWriter.write(
                        Data("payload-\(i)".utf8),
                        to: dir,
                        baseName: "race",
                        fileExtension: "png",
                        strategies: [strategy]
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

    @Test("The default preference order uses hard links on this volume")
    func defaultPrefersHardLink() throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let outcome = try OutputFileWriter.writeReportingStrategy(
            Data("x".utf8), to: dir, baseName: "shot", fileExtension: "png"
        )
        // APFS supports link(2); the weaker fallbacks exist for volumes that do not.
        #expect(outcome.strategy == .hardLink)
    }

    @Test("An empty strategy list is rejected rather than silently doing nothing")
    func emptyStrategyList() throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: TriCapError.self) {
            try OutputFileWriter.write(
                Data("x".utf8), to: dir, baseName: "shot", fileExtension: "png", strategies: []
            )
        }
    }

    @Test("No temporary files are left behind by any strategy", arguments: OutputFileWriter.ClaimStrategy.allCases)
    func noLeftovers(strategy: OutputFileWriter.ClaimStrategy) throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try OutputFileWriter.write(
            Data("x".utf8), to: dir, baseName: "shot", fileExtension: "png", strategies: [strategy]
        )
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix(".tricap-") }
        #expect(leftovers.isEmpty)
    }
}
