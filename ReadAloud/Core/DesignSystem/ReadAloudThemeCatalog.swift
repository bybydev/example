import AppFoundation

enum ReadAloudThemeCatalog {
    static let catalog = ThemeCatalog(
        themes: [
            FoundationThemes.midnight.withAccess(.free),
            FoundationThemes.paper.withAccess(.free),
        ],
        fallbackThemeID: FoundationThemes.midnight.id
    )
}
