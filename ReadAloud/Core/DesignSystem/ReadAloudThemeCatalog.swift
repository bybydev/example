import AppFoundation

enum ReadAloudThemeCatalog {
    static let catalog = ThemeCatalog(
        themes: [
            FoundationThemes.midnight
                .withAccess(.free),
            FoundationThemes.paper
                .withAccess(.free),
            FoundationThemes.rose
                .withAccess(.pro),
            FoundationThemes.sunset
                .withAccess(.pro),
            FoundationThemes.lavender
                .withAccess(.pro),
            FoundationThemes.champagne
                .withAccess(.pro),
        ],
        fallbackThemeID:
            FoundationThemes.midnight.id
    )
}
