import Foundation

/// The ordered annotation stack plus undo/redo.
///
/// Undo is snapshot-based: each mutation pushes a copy of the previous item array. Annotation
/// items are tiny value types (a freehand stroke is the only one that can grow, and it is capped
/// by the editor's point-coalescing), so snapshots are far cheaper than a command log and they
/// cannot drift out of sync with the model the way inverse-operation undo can.
///
/// The history depth is bounded so a long editing session cannot grow without limit.
public struct AnnotationDocument: Equatable, Sendable {

    public static let defaultHistoryLimit = 100

    public private(set) var items: [AnnotationItem]
    private var undoStack: [[AnnotationItem]]
    private var redoStack: [[AnnotationItem]]
    private let historyLimit: Int

    public init(items: [AnnotationItem] = [], historyLimit: Int = AnnotationDocument.defaultHistoryLimit) {
        self.items = items
        self.undoStack = []
        self.redoStack = []
        self.historyLimit = max(1, historyLimit)
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var isEmpty: Bool { items.isEmpty }
    public var undoDepth: Int { undoStack.count }
    public var redoDepth: Int { redoStack.count }

    // MARK: - Mutations

    /// Append an item. Degenerate shapes (a click that produced a zero-size rect, an empty text
    /// box) are ignored so they never occupy an undo step the user has to press twice to get past.
    @discardableResult
    public mutating func add(_ item: AnnotationItem) -> Bool {
        guard !item.shape.isDegenerate else { return false }
        commit { $0.append(item) }
        return true
    }

    @discardableResult
    public mutating func remove(id: UUID) -> Bool {
        guard items.contains(where: { $0.id == id }) else { return false }
        commit { $0.removeAll { $0.id == id } }
        return true
    }

    /// Replace an existing item (used when the text editor commits an edited string).
    @discardableResult
    public mutating func update(_ item: AnnotationItem) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return false }
        guard items[index] != item else { return false }
        if item.shape.isDegenerate { return remove(id: item.id) }
        commit { $0[index] = item }
        return true
    }

    @discardableResult
    public mutating func removeLast() -> Bool {
        guard !items.isEmpty else { return false }
        commit { $0.removeLast() }
        return true
    }

    @discardableResult
    public mutating func clear() -> Bool {
        guard !items.isEmpty else { return false }
        commit { $0.removeAll() }
        return true
    }

    // MARK: - History

    @discardableResult
    public mutating func undo() -> Bool {
        guard let previous = undoStack.popLast() else { return false }
        redoStack.append(items)
        if redoStack.count > historyLimit { redoStack.removeFirst() }
        items = previous
        return true
    }

    @discardableResult
    public mutating func redo() -> Bool {
        guard let next = redoStack.popLast() else { return false }
        undoStack.append(items)
        if undoStack.count > historyLimit { undoStack.removeFirst() }
        items = next
        return true
    }

    /// Apply a mutation, recording the pre-state for undo and invalidating the redo branch.
    private mutating func commit(_ mutate: (inout [AnnotationItem]) -> Void) {
        undoStack.append(items)
        if undoStack.count > historyLimit { undoStack.removeFirst() }
        redoStack.removeAll()
        mutate(&items)
    }
}
