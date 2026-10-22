import AppFoundation
import SwiftUI

/// P0 composition root only. Navigation and feature views belong to P1 and later.
@main
@MainActor
struct InkribeIOSApp: App {
    @State private var themes = ThemeManager(
        catalog: .foundationDefaults,
        stateStore: UserDefaultsThemeStateStore(
            storageKey: "com.hoangbkit.inkribe.ios.theme-state"
        )
    )

    var body: some Scene {
        WindowGroup {
            // Intentionally no feature UI until its phase-specific design is approved.
            EmptyView()
                .environment(themes)
                .appFoundationTheme(themes)
        }
    }
}
