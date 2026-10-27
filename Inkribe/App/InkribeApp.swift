import AppFoundation
import SwiftUI

/// P1 approved Projects composition root; one process-wide repository.
@main
@MainActor
struct InkribeApp: App {
    @State private var themes = ThemeManager(
        catalog: InkribeThemes.catalog,
        stateStore: UserDefaultsThemeStateStore(
            storageKey: "com.hoangbkit.inkribe.ios.theme-state"
        ),
        previewBehavior: .miLoveStyle
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

/// App-owned access and ordering; palette definitions remain in AppFoundation.
private enum InkribeThemes {
    static let catalog = ThemeCatalog(
        themes: [FoundationThemes.paper.withAccess(.free)]
            + FoundationThemes.all.filter { $0.id != FoundationThemes.paper.id }
                .map { $0.withAccess(.pro) },
        fallbackThemeID: FoundationThemes.paper.id
    )
}
