import AppFoundation

@MainActor
enum BYOKchatThemes {
  static let paper = FoundationThemes.paper.withAccess(.free)

  static let linen = AppTheme(
    id: "linen",
    title: "Linen",
    symbolName: "text.page",
    access: .free,
    appearance: ThemeAppearance(
      background: ThemeColor(hex: 0xFBF7EF),
      gradientStart: ThemeColor(hex: 0xFFFDF8),
      gradientEnd: ThemeColor(hex: 0xE8D9C6),
      accent: ThemeColor(hex: 0x8A6348),
      primaryForeground: ThemeColor(hex: 0x2B241F),
      secondaryForeground: ThemeColor(hex: 0x2B241F, alpha: 0.66),
      surface: ThemeColor.white.withAlpha(0.70),
      elevatedSurface: ThemeColor.white.withAlpha(0.90),
      border: ThemeColor(hex: 0x765A45, alpha: 0.14),
      shadow: ThemeColor(hex: 0x4D3929, alpha: 0.16),
      preferredColorScheme: .light
    )
  )

  static let sage = AppTheme(
    id: "sage",
    title: "Sage",
    symbolName: "leaf.fill",
    access: .free,
    appearance: ThemeAppearance(
      background: ThemeColor(hex: 0xEEF3ED),
      gradientStart: ThemeColor(hex: 0xF8FBF7),
      gradientEnd: ThemeColor(hex: 0xCBD9CC),
      accent: ThemeColor(hex: 0x52735E),
      primaryForeground: ThemeColor(hex: 0x1F2A22),
      secondaryForeground: ThemeColor(hex: 0x1F2A22, alpha: 0.66),
      surface: ThemeColor.white.withAlpha(0.68),
      elevatedSurface: ThemeColor.white.withAlpha(0.88),
      border: ThemeColor(hex: 0x496352, alpha: 0.14),
      shadow: ThemeColor(hex: 0x24382A, alpha: 0.15),
      preferredColorScheme: .light
    )
  )

  static let midnight = FoundationThemes.midnight.withAccess(.free)

  static let graphite = AppTheme(
    id: "graphite",
    title: "Graphite",
    symbolName: "circle.lefthalf.filled",
    access: .free,
    appearance: ThemeAppearance(
      background: ThemeColor(hex: 0x111315),
      gradientStart: ThemeColor(hex: 0x262A2E),
      gradientEnd: ThemeColor(hex: 0x111315),
      accent: ThemeColor(hex: 0xA9B4BE),
      primaryForeground: ThemeColor(hex: 0xF2F4F5),
      secondaryForeground: ThemeColor(hex: 0xF2F4F5, alpha: 0.68),
      surface: ThemeColor.white.withAlpha(0.07),
      elevatedSurface: ThemeColor.white.withAlpha(0.11),
      border: ThemeColor.white.withAlpha(0.13),
      shadow: ThemeColor.black.withAlpha(0.42),
      preferredColorScheme: .dark
    )
  )

  static let ocean = AppTheme(
    id: "ocean",
    title: "Ocean",
    symbolName: "water.waves",
    access: .free,
    appearance: ThemeAppearance(
      background: ThemeColor(hex: 0x07131E),
      gradientStart: ThemeColor(hex: 0x12314A),
      gradientEnd: ThemeColor(hex: 0x07131E),
      accent: ThemeColor(hex: 0x62A8D9),
      primaryForeground: ThemeColor(hex: 0xECF7FF),
      secondaryForeground: ThemeColor(hex: 0xECF7FF, alpha: 0.68),
      surface: ThemeColor.white.withAlpha(0.07),
      elevatedSurface: ThemeColor.white.withAlpha(0.11),
      border: ThemeColor(hex: 0x9AD5FF, alpha: 0.14),
      shadow: ThemeColor.black.withAlpha(0.44),
      preferredColorScheme: .dark
    )
  )

  static let catalog = ThemeCatalog(
    themes: [paper, linen, sage, midnight, graphite, ocean],
    fallbackThemeID: paper.id
  )
}
