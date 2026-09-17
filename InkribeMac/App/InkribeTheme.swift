import MacAppFoundation

@MainActor
enum InkribeTheme {
    static let configuration = MacAppThemeConfiguration(
        themes: MacAppThemeCatalog.allBuiltIn,
        defaultThemeID: .system,
        storageKey: "Inkribe.theme"
    )
}
