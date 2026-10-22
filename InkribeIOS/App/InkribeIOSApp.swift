import AppFoundation
import SwiftUI

/// P1 approved Projects composition root; one process-wide repository.
@main
@MainActor
struct InkribeIOSApp: App {
    @State private var themes = ThemeManager(
        catalog: .foundationDefaults,
        stateStore: UserDefaultsThemeStateStore(
            storageKey: "com.hoangbkit.inkribe.ios.theme-state"
        )
    )

    @State private var projects = IOSProjectsModel()

    var body: some Scene {
        WindowGroup {
            IOSProjectsView()
                .environment(projects)
                .environment(themes)
                .appFoundationTheme(themes)
        }
    }
}
