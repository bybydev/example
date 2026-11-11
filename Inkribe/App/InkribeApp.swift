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

/// App-owned ordering/access plus Graphite; existing palettes come from AppFoundation.
private enum InkribeThemes {
    static let graphite = AppTheme(
        id: "graphite",
        title: "Graphite",
        symbolName: "moon.fill",
        access: .pro,
        appearance: ThemeAppearance(
            background: ThemeColor(hex: 0x141414),
            gradientStart: ThemeColor(hex: 0x20262D),
            gradientEnd: ThemeColor(hex: 0x16384A),
            accent: ThemeColor(hex: 0x279ED2),
            primaryForeground: ThemeColor(hex: 0xF2F2F2),
            secondaryForeground: .white.withAlpha(0.72),
            surface: .white.withAlpha(0.065),
            elevatedSurface: .white.withAlpha(0.10),
            border: .white.withAlpha(0.13),
            shadow: .black.withAlpha(0.42),
            preferredColorScheme: .dark
        )
    )

    static let catalog = ThemeCatalog(
        themes: [FoundationThemes.sunset.withAccess(.free), FoundationThemes.paper, graphite]
            + FoundationThemes.all
                .filter { $0.id != FoundationThemes.sunset.id && $0.id != FoundationThemes.paper.id }
                .map { $0.withAccess(.pro) },
        fallbackThemeID: FoundationThemes.sunset.id
    )
}
