import SwiftUI

/// Renders just the Quality tab, with the advanced section expanded, for the UI-snapshot pass.
///
/// `TabView` does not render its tab strip through `CALayer.render(in:)`, so the offscreen
/// renderer cannot page to a tab; hosting the tab's own view is how the snapshot shows it.
struct SettingsQualityPreview: View {
    @ObservedObject var store: SettingsStore
    let expandAdvanced: Bool

    var body: some View {
        SettingsView(store: store, initiallyExpandAdvancedQuality: expandAdvanced).qualityTab
    }
}
