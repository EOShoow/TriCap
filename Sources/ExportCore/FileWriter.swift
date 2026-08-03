import Darwin
import Foundation
import TriCapKit

/// Filename generation and race-safe writing.
public enum OutputFileWriter {

    /// Maximum `-N` suffixes tried before falling back to a random token.
    public static let maxNumberedAttempts = 1000

    /// How a filename is claimed. All three are atomic "create only if absent" operations; they
    /// differ only in which filesystems support them.
    ///
    /// TriCap tries them in this order and remembers nothing between calls, so a save folder that
    /// moves from APFS to a USB stick just works.
    public enum ClaimStrategy: String, Sendable, CaseIterable {
        /// `link(2)` — atomic, and the final name never exists in a partial state because the
        /// bytes are already complete in the temporary file. Unsupported on exFAT/FAT and on many
        /// SMB/network mounts.
        case hardLink
        /// `renamex_np(..., RENAME_EXCL)` — atomic create-or-fail. Supported on APFS and HFS+,
        /// not guaranteed elsewhere.
        case exclusiveRename
        /// `open(O_CREAT|O_EXCL)` then write — POSIX, works everywhere including exFAT and SMB.
        /// The name is claimed atomically; the bytes are written afterwards, so an abrupt power
        /// loss mid-write can leave a short file under the final name. That is the price of a
        /// filesystem with no atomic-publish primitive, and it is the last resort.
        case exclusiveCreate
    }

    /// `TriCap-2026-08-03-141530` — sortable, filesystem-safe, no locale dependence.
    public static func baseName(prefix: String, date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let sanitized = sanitize(prefix)
        return String(
            format: "%@-%04d-%02d-%02d-%02d%02d%02d",
            sanitized,
            c.year ?? 0, c.month ?? 0, c.day ?? 0,
            c.hour ?? 0, c.minute ?? 0, c.second ?? 0
        )
    }

    /// Strip path separators, colons and control characters from a user-supplied prefix.
    public static func sanitize(_ prefix: String) -> String {
        var forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|")
        forbidden.formUnion(.controlCharacters)
        let cleaned = prefix.components(separatedBy: forbidden).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "TriCap" : String(cleaned.prefix(64))
    }

    /// Write `data` into `directory` under a name derived from `baseName`, never overwriting.
    ///
    /// Name collisions are resolved by *atomically claiming* the name, so two TriCap exports (or
    /// an unrelated process) racing on the same second cannot clobber each other — a
    /// `FileManager.fileExists` check followed by a write would have a window between the two.
    ///
    /// The bytes are written to a temporary file in the *same* directory first, so on a filesystem
    /// that supports `link(2)` or `renamex_np` a full disk or a crash mid-write can never leave a
    /// truncated file under the final name.
    ///
    /// - Parameter strategies: which claim mechanisms may be used, in preference order. The
    ///   default tries all three; tests narrow it to exercise each fallback deliberately, since
    ///   this machine has no exFAT or SMB volume to reproduce the real trigger on.
    @discardableResult
    public static func write(
        _ data: Data,
        to directory: URL,
        baseName: String,
        fileExtension: String,
        strategies: [ClaimStrategy] = ClaimStrategy.allCases
    ) throws -> URL {
        try writeReportingStrategy(
            data, to: directory, baseName: baseName, fileExtension: fileExtension, strategies: strategies
        ).url
    }

    /// What a write produced, including which claim strategy actually worked.
    public struct WriteOutcome: Sendable, Equatable {
        public let url: URL
        public let strategy: ClaimStrategy
    }

    /// As ``write(_:to:baseName:fileExtension:strategies:)`` but also reports which strategy
    /// claimed the name. Used by the tests that exercise each fallback in isolation.
    public static func writeReportingStrategy(
        _ data: Data,
        to directory: URL,
        baseName: String,
        fileExtension: String,
        strategies: [ClaimStrategy] = ClaimStrategy.allCases
    ) throws -> WriteOutcome {
        guard !strategies.isEmpty else {
            throw TriCapError.writeFailed("No filename claim strategy is available.")
        }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw TriCapError.writeFailed("Could not create \(directory.path): \(error.localizedDescription)")
        }

        let temporaryURL = directory.appendingPathComponent(".tricap-\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporaryURL, options: [.atomic])
        } catch {
            throw TriCapError.writeFailed(describe(error, path: temporaryURL.path))
        }
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        var lastUnsupportedDetail: String?

        for candidate in candidateURLs(in: directory, baseName: baseName, fileExtension: fileExtension) {
            var taken = false

            for strategy in strategies {
                switch claim(candidate, from: temporaryURL, data: data, using: strategy) {
                case .claimed:
                    return WriteOutcome(url: candidate, strategy: strategy)
                case .nameTaken:
                    taken = true
                case .unsupported(let detail):
                    // This filesystem cannot do it; try the next, weaker strategy for this name.
                    lastUnsupportedDetail = detail
                    continue
                case .failed(let code):
                    throw TriCapError.writeFailed(
                        "Could not create \(candidate.lastPathComponent): \(String(cString: strerror(code)))"
                    )
                }
                if taken { break }
            }

            if taken { continue }

            // Every strategy reported "unsupported" for this volume.
            throw TriCapError.writeFailed(
                "This volume supports none of TriCap's safe file-creation methods"
                    + (lastUnsupportedDetail.map { " (\($0))" } ?? "")
                    + "."
            )
        }

        throw TriCapError.writeFailed("Could not find a free filename for \(baseName).\(fileExtension).")
    }

    // MARK: - Claiming a name

    enum ClaimResult: Equatable {
        case claimed
        case nameTaken
        /// The filesystem does not implement this primitive; try the next strategy.
        case unsupported(String)
        case failed(Int32)
    }

    /// `errno` values that mean "this filesystem does not do that", as opposed to a real failure.
    private static let unsupportedErrors: Set<Int32> = [
        ENOTSUP,   // == EOPNOTSUPP on Darwin
        EPERM,     // FAT/exFAT report EPERM for link(2)
        EXDEV,     // different filesystems (should not happen — same directory — but harmless)
        EMLINK,    // link count exhausted
        EINVAL,    // renamex_np with unsupported flags
    ]

    private static func claim(
        _ candidate: URL,
        from temporaryURL: URL,
        data: Data,
        using strategy: ClaimStrategy
    ) -> ClaimResult {
        switch strategy {
        case .hardLink:
            return posixClaim(candidate, from: temporaryURL) { source, destination in
                link(source, destination)
            }
        case .exclusiveRename:
            return posixClaim(candidate, from: temporaryURL) { source, destination in
                renamex_np(source, destination, UInt32(RENAME_EXCL))
            }
        case .exclusiveCreate:
            return exclusiveCreateClaim(candidate, data: data)
        }
    }

    private static func posixClaim(
        _ candidate: URL,
        from temporaryURL: URL,
        _ operation: (UnsafePointer<CChar>, UnsafePointer<CChar>) -> Int32
    ) -> ClaimResult {
        let code = temporaryURL.withUnsafeFileSystemRepresentation { source -> Int32 in
            candidate.withUnsafeFileSystemRepresentation { destination -> Int32 in
                guard let source, let destination else { return EINVAL }
                return operation(source, destination) == 0 ? 0 : errno
            }
        }
        if code == 0 { return .claimed }
        if code == EEXIST { return .nameTaken }
        if unsupportedErrors.contains(code) { return .unsupported(String(cString: strerror(code))) }
        return .failed(code)
    }

    /// Claim the name with `O_EXCL`, then write the bytes into the descriptor we just created.
    private static func exclusiveCreateClaim(_ candidate: URL, data: Data) -> ClaimResult {
        let descriptor = candidate.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        }
        if descriptor < 0 {
            let code = errno
            if code == EEXIST { return .nameTaken }
            return .failed(code)
        }
        var written = 0
        let result: Int32? = data.withUnsafeBytes { raw -> Int32? in
            guard let base = raw.baseAddress else { return nil }
            while written < raw.count {
                let n = Darwin.write(descriptor, base.advanced(by: written), raw.count - written)
                if n <= 0 {
                    if errno == EINTR { continue }
                    return errno
                }
                written += n
            }
            return nil
        }
        if let result {
            // Do not leave a half-written file under the final name.
            _ = Darwin.close(descriptor)
            try? FileManager.default.removeItem(at: candidate)
            return .failed(result)
        }
        return finalizeExclusiveCreate(descriptor: descriptor, candidate: candidate)
    }

    /// Flush and close an `O_EXCL` claim before reporting success. Some filesystems defer write
    /// failures until `fsync(2)` or `close(2)` (network volumes and a disk becoming full are common
    /// examples). The final name is removed on either error so callers never receive a path whose
    /// durability the operating system rejected.
    static func finalizeExclusiveCreate(
        descriptor: Int32,
        candidate: URL,
        syncOperation: (Int32) -> Int32 = { Darwin.fsync($0) },
        closeOperation: (Int32) -> Int32 = { Darwin.close($0) }
    ) -> ClaimResult {
        if syncOperation(descriptor) != 0 {
            let code = errno
            _ = closeOperation(descriptor)
            try? FileManager.default.removeItem(at: candidate)
            return .failed(code)
        }
        if closeOperation(descriptor) != 0 {
            let code = errno
            try? FileManager.default.removeItem(at: candidate)
            return .failed(code)
        }
        return .claimed
    }

    /// `base.ext`, `base-1.ext`, … `base-1000.ext`, then one random-token name as a last resort.
    static func candidateURLs(in directory: URL, baseName: String, fileExtension: String) -> [URL] {
        var urls = [directory.appendingPathComponent("\(baseName).\(fileExtension)")]
        for n in 1...maxNumberedAttempts {
            urls.append(directory.appendingPathComponent("\(baseName)-\(n).\(fileExtension)"))
        }
        let token = UUID().uuidString.prefix(8)
        urls.append(directory.appendingPathComponent("\(baseName)-\(token).\(fileExtension)"))
        return urls
    }

    /// Turn Foundation's write errors into copy a user can act on.
    private static func describe(_ error: Error, path: String) -> String {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case NSFileWriteOutOfSpaceError:
                return "the volume containing \(path) is full."
            case NSFileWriteNoPermissionError:
                return "TriCap does not have permission to write to \(path)."
            case NSFileWriteVolumeReadOnlyError:
                return "the volume containing \(path) is read-only."
            default:
                break
            }
        }
        return "\(nsError.localizedDescription) (\(path))"
    }
}
