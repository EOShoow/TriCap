import Foundation

/// TriCap's view of `SMAppService.mainApp.status`.
///
/// The system's status is the **only** source of truth for "launch at login" — there is
/// deliberately no mirror Bool in `AppSettings`, because the user can flip the real switch in
/// System Settings › General › Login Items at any time and a cached copy would immediately lie.
/// TriCap reads the live status whenever the settings pane needs it and after every toggle.
///
/// This enum exists (rather than using `SMAppService.Status` directly) so the presentation and
/// toggle-decision rules below are pure `TriCapKit` logic, testable without ServiceManagement,
/// a bundle identity, or a login session.
public enum LoginItemStatus: Equatable, Sendable {
    /// Not registered: launch at login is off. The shipped default.
    case notRegistered
    /// Registered and active.
    case enabled
    /// Registered, but the user must approve it in System Settings › Login Items.
    case requiresApproval
    /// The system cannot find the service — typically the app is not running from a proper,
    /// stably-located bundle (a bare SwiftPM binary, a build directory, a translocated copy).
    case notFound
}

/// What the settings pane shows for a given status, plus which actions make sense.
///
/// Pure and exhaustive, so every status maps to *some* honest UI and a test can walk all of them.
public struct LoginItemPresentation: Equatable, Sendable {
    /// Whether the toggle renders as on. `requiresApproval` counts as on: TriCap has asked, and
    /// the block lives in System Settings — showing "off" would invite a pointless re-register.
    public let toggleIsOn: Bool
    /// The inline line under the toggle, or `nil` when the state speaks for itself.
    public let statusText: String?
    /// Whether `statusText` is a problem (orange/red styling) rather than plain information.
    public let isWarning: Bool
    /// Whether to offer an "Open Login Items Settings…" button.
    public let offersSystemSettings: Bool

    public init(toggleIsOn: Bool, statusText: String?, isWarning: Bool, offersSystemSettings: Bool) {
        self.toggleIsOn = toggleIsOn
        self.statusText = statusText
        self.isWarning = isWarning
        self.offersSystemSettings = offersSystemSettings
    }

    public static func presentation(for status: LoginItemStatus) -> LoginItemPresentation {
        switch status {
        case .notRegistered:
            return LoginItemPresentation(
                toggleIsOn: false, statusText: nil, isWarning: false, offersSystemSettings: false
            )
        case .enabled:
            return LoginItemPresentation(
                toggleIsOn: true, statusText: nil, isWarning: false, offersSystemSettings: false
            )
        case .requiresApproval:
            return LoginItemPresentation(
                toggleIsOn: true,
                statusText: "Waiting for approval. Allow TriCap under System Settings › General › Login Items.",
                isWarning: true,
                offersSystemSettings: true
            )
        case .notFound:
            return LoginItemPresentation(
                toggleIsOn: false,
                statusText: "The system can't find TriCap as a login item. This usually means the app isn't running from a fixed location — move TriCap.app to the Applications folder and try again.",
                isWarning: true,
                offersSystemSettings: false
            )
        }
    }
}

/// What toggling the switch should actually do, given the live status.
///
/// Register and unregister are idempotent by construction: asking for a state the system is
/// already in is `.none`, so a double-toggle or a stale UI cannot stack registrations or turn an
/// error into fake progress.
public enum LoginItemAction: Equatable, Sendable {
    case register
    case unregister
    case none

    public static func action(forDesired desired: Bool, current: LoginItemStatus) -> LoginItemAction {
        switch (desired, current) {
        case (true, .enabled), (true, .requiresApproval):
            // Already registered — approval, if pending, happens in System Settings, and
            // re-registering does not hurry it along.
            return .none
        case (true, .notRegistered), (true, .notFound):
            // From `.notFound`, registering is allowed to *try*: it either fixes a stale state or
            // throws a real error for the UI to show. Pretending it cannot work would hide the
            // actual diagnostic.
            return .register
        case (false, .enabled), (false, .requiresApproval):
            return .unregister
        case (false, .notRegistered), (false, .notFound):
            return .none
        }
    }
}
