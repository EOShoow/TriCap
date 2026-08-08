/// FIFO policy for transient notices that must not replace a notice already on screen.
///
/// The presenter owns the visible notice; this value only decides whether a new notice may be
/// shown immediately or must wait. Keeping that decision outside AppKit makes the ordering
/// contract deterministic and testable.
public struct TransientNoticeQueue<Notice: Sendable>: Sendable {
    private var pending: [Notice] = []

    public init() {}

    public var pendingCount: Int { pending.count }

    /// Returns `notice` when it may be presented now. If another notice is visible, stores it and
    /// returns `nil`; the caller obtains it later with ``next()``.
    public mutating func enqueue(_ notice: Notice, presenterIsBusy: Bool) -> Notice? {
        guard presenterIsBusy else { return notice }
        pending.append(notice)
        return nil
    }

    /// The oldest waiting notice, if any.
    public mutating func next() -> Notice? {
        guard !pending.isEmpty else { return nil }
        return pending.removeFirst()
    }
}
