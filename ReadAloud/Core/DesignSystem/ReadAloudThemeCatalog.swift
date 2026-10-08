import AppFoundation

enum ReadAloudThemeCatalog {
    static let light = AppTheme(
        id: "readaloud.light",
        title: "ReadAloud Light",
        symbolName: "sun.max.fill",
        access: .free,
        appearance: ThemeAppearance(
            background: ThemeColor(hex: 0xF6F0E4),
            gradientStart: ThemeColor(hex: 0xF4E7CF),
            gradientEnd: ThemeColor(hex: 0xD9E9E3),
            accent: ThemeColor(hex: 0xA64A20),
            primaryForeground: ThemeColor(hex: 0x153D40),
            secondaryForeground: ThemeColor(hex: 0x536D6B),
            surface: ThemeColor(hex: 0xFFFCF5),
            elevatedSurface: ThemeColor(hex: 0xFFFFFF),
            border: ThemeColor(hex: 0x153D40, alpha: 0.14),
            shadow: ThemeColor(hex: 0x103F43, alpha: 0.12),
            preferredColorScheme: .light
        )
    )

    static let dark = AppTheme(
        id: "readaloud.dark",
        title: "ReadAloud Dark",
        symbolName: "moon.fill",
        access: .free,
        appearance: ThemeAppearance(
            background: ThemeColor(hex: 0x092E32),
            gradientStart: ThemeColor(hex: 0x103F43),
            gradientEnd: ThemeColor(hex: 0x185055),
            accent: ThemeColor(hex: 0xED995D),
            primaryForeground: ThemeColor(hex: 0xF4E7CF),
            secondaryForeground: ThemeColor(hex: 0xADC9C4),
            surface: ThemeColor(hex: 0x103F43),
            elevatedSurface: ThemeColor(hex: 0x185055),
            border: ThemeColor(hex: 0xF4E7CF, alpha: 0.16),
            shadow: .black.withAlpha(0.28),
            preferredColorScheme: .dark
        )
    )

    static let catalog = ThemeCatalog(
        themes: [
            light,
            dark,
            FoundationThemes.rose.withAccess(.pro),
            FoundationThemes.sunset.withAccess(.pro),
            FoundationThemes.lavender.withAccess(.pro),
            FoundationThemes.champagne.withAccess(.pro),
        ],
        fallbackThemeID: dark.id
    )

    static func makeStateStore() -> UserDefaultsThemeStateStore {
        let store = UserDefaultsThemeStateStore(
            storageKey: "com.hoangbkit.readaloud.theme-state"
        )
        let original = store.load()
        var migrated = original
        let replacements = [
            FoundationThemes.midnight.id: dark.id,
            FoundationThemes.paper.id: light.id,
        ]

        if let id = original.selectedThemeID, let replacement = replacements[id] {
            migrated.selectedThemeID = replacement
        }
        if let id = original.committedThemeID, let replacement = replacements[id] {
            migrated.committedThemeID = replacement
        }
        if migrated != original {
            store.save(migrated)
        }
        return store
    }
}
