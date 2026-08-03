import Darwin
import Foundation
import TriCapKit

/// Filename generation and race-safe writing.
public enum OutputFileWriter {

    /// Maximum `-N` suffixes tried before falling back to a random token.
    public static let maxNumberedAttempts = 1000

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
    /// Name collisions are resolved by claiming the name with `link(2)`, which fails atomically
    /// with `EEXIST`. Two TriCap exports (or an unrelated process) racing on the same second
    /// therefore cannot clobber each other — a `FileManager.fileExists` check followed by a write
    /// would have a window between the two.
    ///
    /// The bytes are written to a temporary file in the *same* directory first, so a full disk or
    /// a crash mid-write can never leave a truncated file under the final name.
    @discardableResult
    public static func write(
        _ data: Data,
        to directory: URL,
        baseName: String,
        fileExtension: String
    ) throws -> URL {
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

        for candidate in candidateURLs(in: directory, baseName: baseName, fileExtension: fileExtension) {
            let result = temporaryURL.withUnsafeFileSystemRepresentation { source -> Int32 in
                candidate.withUnsafeFileSystemRepresentation { destination -> Int32 in
                    guard let source, let destination else { return -1 }
                    return link(source, destination) == 0 ? 0 : errno
                }
            }
            if result == 0 { return candidate }
            if result == EEXIST { continue }
            throw TriCapError.writeFailed(
                "Could not create \(candidate.lastPathComponent): \(String(cString: strerror(result)))"
            )
        }

        throw TriCapError.writeFailed("Could not find a free filename for \(baseName).\(fileExtension).")
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
