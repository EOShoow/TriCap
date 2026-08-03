import AppKit
import CaptureCore
import TriCapKit

/// The AppKit implementation of ``RecordingChrome``: the countdown panel, the stop HUD, the region
/// outline, and the system-wide cancel key that spans both phases.
///
/// **Why a global hot key for Escape.** The obvious implementation —
/// `NSEvent.addLocalMonitorForEvents` — only sees keys delivered to TriCap, so the moment the user
/// clicks into the application they are recording, Escape stops working. A *global* `NSEvent`
/// monitor would need Accessibility permission, which is a second TCC prompt TriCap refuses to
/// ask for. Carbon's `RegisterEventHotKey` accepts a modifier-less key code and needs no
/// permission at all (verified: `RegisterEventHotKey(kVK_Escape, 0, …)` returns `noErr` with
/// `AXIsProcessTrusted() == false`).
///
/// **The claim spans the countdown too.** The countdown is the phase a user is most likely to
/// abandon — they started a recording and immediately realised the window was wrong — and it is
/// also the phase where TriCap is least likely to be frontmost, because the point of a countdown
/// is to give them time to arrange something else. So the key is claimed before the first tick and
/// held until the recording ends, with the action rebound in place rather than surrendered and
/// re-taken. `TransientHotKeyClaim` holds those rules; ``dismiss()`` releases on every exit path.
///
/// The trade is explicit: while a recording is being set up or is running — at most the countdown
/// plus `RecordingLimits.maxDuration` — Escape is intercepted system-wide and does not reach the
/// focused app. That ends the instant the recording does. The configurable capture shortcut lives
/// in a different slot and is never touched.
@MainActor
final class RecordingChromeController: RecordingChrome {

    private let hud = RecordingHUD()
    private var dismissed = false
    private var countdownCancelled = false

    private lazy var escapeClaim = TransientHotKeyClaim(
        combo: .bareEscape,
        register: { combo, action in
            GlobalHotKeyMonitor.shared.register(
                combo, in: .recordingCancel, allowingNoModifiers: true, action: action
            )
        },
        unregister: { GlobalHotKeyMonitor.shared.unregister(.recordingCancel) }
    )

    // MARK: - Countdown

    /// Run the pre-roll countdown. Returns `false` if the user cancelled during it.
    ///
    /// Escape is claimed here rather than in ``present(region:onStop:onCancel:)`` so that it works
    /// throughout, and is *kept* when the countdown completes so the hand-off to the recording has
    /// no window in which the key is unclaimed.
    func runCountdown(seconds: Int, over region: CaptureRegion) async -> Bool {
        countdownCancelled = false

        // Claim before the first tick, even when there is no countdown to show, so the recording
        // phase inherits an already-live claim.
        let claimed = escapeClaim.claim { [weak self] in
            // Setting a flag is idempotent, so a user leaning on Escape cancels exactly once.
            self?.countdownCancelled = true
        }

        guard seconds > 0 else { return !countdownCancelled }

        hud.showCountdown(seconds: seconds, over: region)
        if !claimed {
            TriCapLog.app.error("could not claim a global Escape for the countdown")
            hud.showCountdownEscapeUnavailable()
        }
        defer { hud.dismissCountdown() }

        for remaining in stride(from: seconds, through: 1, by: -1) {
            if countdownCancelled { return false }
            hud.updateCountdown(remaining: remaining)
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } catch {
                return false
            }
        }
        return !countdownCancelled
    }

    // MARK: - RecordingChrome

    func present(
        region: CaptureRegion,
        onStop: @escaping @MainActor () -> Void,
        onCancel: @escaping @MainActor () -> Void
    ) {
        dismissed = false
        hud.showRecordingHUD(region: region, onStop: onStop)

        // Rebind rather than re-register: the claim is normally already live from the countdown,
        // and re-registering the same combination would fail with `eventHotKeyExistsErr`.
        let claimed = escapeClaim.claim { onCancel() }
        if !claimed {
            // Another application already owns a bare Escape hot key. The Stop button still works;
            // say so rather than pretending Escape is wired up.
            TriCapLog.app.error("could not claim a global Escape for recording cancel")
            hud.showEscapeUnavailableNotice()
        }
    }

    func update(progress: RecordingProgress, limits: RecordingLimits) {
        hud.update(progress: progress, limits: limits)
    }

    func dismiss() {
        guard !dismissed else { return }
        dismissed = true
        escapeClaim.release()
        hud.dismissCountdown()
        hud.dismiss()
    }
}
