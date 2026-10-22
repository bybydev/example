import AppFoundation
import SwiftUI

/// P1 approved Projects composition root; one process-wide repository.
@main
@MainActor
struct InkribeApp: App {
    @State private var themes = ThemeManager(
        catalog: .foundationDefaults,
        stateStore: UserDefaultsThemeStateStore(
            storageKey: "com.hoangbkit.inkribe.ios.theme-state"
        ),
        previewBehavior: .disabled
    )

    @State private var projects = ProjectsModel()

    var body: some Scene {
        WindowGroup {
            ProjectsView()
                .environment(projects)
                .environment(themes)
                .environment(projects.access)
                .environment(projects.access.purchases)
                .appFoundationTheme(themes)
                .synchronizesThemeAccess(themes, hasPro: projects.access.hasPro)
                .managesPurchases(projects.access.purchases)
                .onChange(of: projects.access.purchases.entitlementState, initial: true) { _, _ in
                    projects.access.scheduleExpiration()
                }
        }
    }
}
