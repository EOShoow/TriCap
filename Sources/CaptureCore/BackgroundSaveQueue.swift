import Foundation

/// Runs follow-up work — like the quick screenshot's background save — *outside* the capture
/// session, delivering each outcome back to the main actor when it finishes.
///
/// Exists because of a review finding: the quick flow used to `await` its disk write inside the
/// capture pipeline, so the `CaptureSessionGate` stayed occupied for the whole save. A second
/// hot-key press during the save was silently refused, and the success toast waited for the
/// disk. The contract this type (and `QuickSaveOrchestrationTests`) pins:
///
/// - ``submit(priority:work:deliver:)`` returns as soon as the work is *scheduled*, never when
///   it completes — so the session can end, the gate can free, and the next capture can begin
///   while the work is still running;
/// - each submission's `deliver` receives that submission's own outcome, so overlapping saves
///   can finish in any order without crossing wires;
/// - `work` runs off the main actor and must capture only immutable snapshots — the compiler
///   enforces `Sendable`, the call sites keep the discipline of snapshotting settings up front.
@MainActor
public final class BackgroundSaveQueue {

    /// Submissions whose outcome has not been delivered yet.
    public private(set) var inFlightCount = 0

    public init() {}

    /// Schedule `work` off the main actor; run `deliver` with its result on the main actor when
    /// it finishes. Returns immediately.
    public func submit<Outcome: Sendable>(
        priority: TaskPriority = .utility,
        work: @escaping @Sendable () -> Outcome,
        deliver: @escaping @MainActor (Outcome) -> Void
    ) {
        inFlightCount += 1
        Task.detached(priority: priority) {
            let outcome = work()
            await MainActor.run { [weak self] in
                self?.inFlightCount -= 1
                deliver(outcome)
            }
        }
    }
}
