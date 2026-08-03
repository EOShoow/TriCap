import AppKit
import CaptureCore
import TriCapKit

/// The AppKit implementation of ``RecordingChrome``: the stop HUD, the region outline, and the
/// temporary system-wide cancel key.
///
/// **Why a global hot key for Escape.** The obvious implementation —
/// `NSEvent.addLocalMonitorForEvents` — only sees keys delivered to TriCap, so the moment the user
/// clicks into the application they are recording, Escape stops working. A *global* `NSEvent`
/// monitor would need Accessibility permission, which is a second TCC prompt TriCap refuses to
/// ask for. Carbon's `RegisterEventHotKey` accepts a modifier-less key code and needs no
/// permission at all (verified: `RegisterEventHotKey(kVK_Escape, 0, …)` returns `noErr` with
/// `AXIsProcessTrusted() == false`), so TriCap claims a bare Escape for the lifetime of the
/// recording and releases it immediately afterwards.
///
/// The trade this makes is explicit: while a recording is running — at most
/// `RecordingLimits.maxDuration` — Escape is intercepted system-wide and does not reach the
/// focused app. That is the behaviour the user asked for by starting a recording, and it ends the
/// instant the recording does. The configurable capture shortcut lives in a different slot and is
/// never touched.
@MainActor
final class RecordingChromeController: RecordingChrome {

    private let hud = RecordingHUD()
    private var didClaimEscape = false
    private var dismissed = false

    func present(
        region: CaptureRegion,
        onStop: @escaping @MainActor () -> Void,
        onCancel: @escaping @MainActor () -> Void
    ) {
        dismissed = false
        hud.showRecordingHUD(region: region, onStop: onStop)

        didClaimEscape = GlobalHotKeyMonitor.shared.register(
            .bareEscape,
            in: .recordingCancel,
            allowingNoModifiers: true
        ) {
            onCancel()
        }
        if !didClaimEscape {
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
        if didClaimEscape {
            GlobalHotKeyMonitor.shared.unregister(.recordingCancel)
            didClaimEscape = false
        }
        hud.dismiss()
    }

    /// Run the pre-roll countdown. Returns `false` if the user pressed Escape during it.
    func runCountdown(seconds: Int, over region: CaptureRegion) async -> Bool {
        await hud.runCountdown(seconds: seconds, over: region)
    }
}
