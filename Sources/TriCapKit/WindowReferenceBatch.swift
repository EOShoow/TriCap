import Foundation

/// Lets several ⌘⌘ presses build one clipboard of window references, one JSON line per window,
/// so the user can reference a few windows and paste them into Claude at once.
///
/// A press continues the current batch only while that batch is still what the clipboard holds
/// (nobody copied anything since) and the previous press was recent. macOS cannot say whether the
/// clipboard was pasted, so the time limit is what eventually starts a fresh batch.
public struct WindowReferenceBatch: Sendable {
    /// How long after one press the next still adds to the same batch.
    public static let continuationWindow: TimeInterval = 60

    public enum Outcome: Equatable, Sendable {
        /// The clipboard now holds only this window.
        case started
        /// The window was added after the ones already copied.
        case appended
        /// The window was already in the batch; its entry was refreshed in place.
        case alreadyIncluded
    }

    public private(set) var references: [WindowReference] = []
    private var lastAddedAt: Date?
    private var writtenChangeCount: Int?

    public init() {}

    /// Add `reference`, continuing the current batch or starting a new one.
    /// - Parameter changeCount: the clipboard's change count *before* TriCap writes this press.
    @discardableResult
    public mutating func add(_ reference: WindowReference, at now: Date, changeCount: Int) -> Outcome {
        let isRecent = lastAddedAt.map { now.timeIntervalSince($0) <= Self.continuationWindow } ?? false
        lastAddedAt = now
        guard isRecent, changeCount == writtenChangeCount, !references.isEmpty else {
            references = [reference]
            return .started
        }
        if let index = references.firstIndex(where: {
            $0.windowID == reference.windowID && $0.processID == reference.processID
        }) {
            references[index] = reference
            return .alreadyIncluded
        }
        references.append(reference)
        return .appended
    }

    /// Record the clipboard's change count right after TriCap wrote ``text()`` to it.
    public mutating func didWrite(changeCount: Int) {
        writtenChangeCount = changeCount
    }

    /// One JSON object per line, in the order the windows were referenced.
    public func text() throws -> String {
        try references.map { try $0.json() }.joined(separator: "\n")
    }
}
