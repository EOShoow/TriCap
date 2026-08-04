import Foundation
import ServiceManagement
import SwiftUI
import TriCapKit

/// The ServiceManagement side of "launch at login", behind a protocol so the settings pane can be
/// rendered — and its states snapshotted — without a real bundle identity.
@MainActor
protocol LoginItemService {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

/// The real thing: `SMAppService.mainApp`. Public API, macOS 13+; TriCap targets 14+.
/// No LaunchAgent, no helper app — the main app itself is the login item.
@MainActor
struct MainAppLoginItemService: LoginItemService {
    var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .notRegistered: return .notRegistered
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        @unknown default: return .notFound
        }
    }

    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}

/// Owns the settings pane's view of the login item.
///
/// `status` is re-read from the system after every action and every pane appearance — never
/// assumed from what the user just asked for. A failed register/unregister therefore leaves the
/// toggle where the system says it is, with the error shown inline, rather than dressing the
/// failure up as success.
@MainActor
final class LoginItemController: ObservableObject {

    @Published private(set) var status: LoginItemStatus
    @Published private(set) var lastError: String?

    private let service: any LoginItemService

    init(service: any LoginItemService = MainAppLoginItemService()) {
        self.service = service
        self.status = service.status
    }

    var presentation: LoginItemPresentation { .presentation(for: status) }

    /// Re-read the live status — the user may have flipped it in System Settings meanwhile.
    func refresh() {
        status = service.status
    }

    /// Drive the system toward `desired`. Idempotent: asking for the current state does nothing.
    func setEnabled(_ desired: Bool) {
        lastError = nil
        switch LoginItemAction.action(forDesired: desired, current: service.status) {
        case .none:
            break
        case .register:
            do {
                try service.register()
                TriCapLog.app.info("login item registered")
            } catch {
                lastError = error.localizedDescription
                TriCapLog.app.error("login item register failed: \(error.localizedDescription, privacy: .public)")
            }
        case .unregister:
            do {
                try service.unregister()
                TriCapLog.app.info("login item unregistered")
            } catch {
                lastError = error.localizedDescription
                TriCapLog.app.error("login item unregister failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        // Whatever happened, the system's answer is the answer.
        status = service.status
    }

    func openSystemSettings() {
        service.openSystemSettings()
    }
}
