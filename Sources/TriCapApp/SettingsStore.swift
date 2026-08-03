import Foundation
import SwiftUI
import TriCapKit

/// Observable wrapper around ``AppSettings`` backed by `UserDefaults`.
///
/// The whole settings blob is stored as one JSON value: it keeps `AppSettings` the single source
/// of truth, makes adding a field a one-line change, and lets the decoder tolerate blobs written
/// by older builds (see `AppSettings.init(from:)`).
@MainActor
public final class SettingsStore: ObservableObject {

    static let defaultsKey = "app.tricap.settings"

    /// Called whenever the persisted settings change, so the app can react immediately (the hot
    /// key has to be re-registered the moment the user picks a new combination, not when the
    /// settings window happens to close).
    public var onChange: ((AppSettings, AppSettings) -> Void)?

    @Published public var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            persist()
            onChange?(oldValue, settings)
        }
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = decoded
        } else {
            settings = AppSettings()
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    /// Ensure the configured save directory exists; returns the error text if it cannot be created.
    @discardableResult
    public func prepareSaveDirectory() -> String? {
        do {
            try FileManager.default.createDirectory(
                at: settings.saveDirectoryURL,
                withIntermediateDirectories: true
            )
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    public func resetToDefaults() {
        settings = AppSettings()
    }
}
