import AppFoundation

@MainActor
enum BYOKchatThemes {
  // MARK: - Dark

  /// Deep navy workspace with luminous blue actions and cool, high-contrast typography.
  static let midnight = AppTheme(
    id: "midnight",
    title: "Midnight",
    symbolName: "moon.stars.fill",
    access: .free,
    appearance: ThemeAppearance(
      background: ThemeColor(hex: 0x08111F),
      gradientStart: ThemeColor(hex: 0x132642),
      gradientEnd: ThemeColor(hex: 0x08111F),
      accent: ThemeColor(hex: 0x5EA8FF),
      primaryForeground: ThemeColor(hex: 0xE6EDF7),
      secondaryForeground: ThemeColor(hex: 0x98A8BE),
      surface: ThemeColor(hex: 0x101B2C),
      elevatedSurface: ThemeColor(hex: 0x16243A),
      border: ThemeColor(hex: 0x263753),
      shadow: ThemeColor.black.withAlpha(0.46),
      preferredColorScheme: .dark
    )
  )

  /// Purple-black creative theme with lavender controls and restrained violet surfaces.
  static let aubergine = AppTheme(
    id: "aubergine",
    title: "Aubergine",
    symbolName: "sparkles",
    access: .pro,
    appearance: ThemeAppearance(
      background: ThemeColor(hex: 0x211A29),
      gradientStart: ThemeColor(hex: 0x3A2D47),
      gradientEnd: ThemeColor(hex: 0x211A29),
      accent: ThemeColor(hex: 0xB783F2),
      primaryForeground: ThemeColor(hex: 0xF5EFFA),
      secondaryForeground: ThemeColor(hex: 0xC1B2CF),
      surface: ThemeColor(hex: 0x2E2438),
      elevatedSurface: ThemeColor(hex: 0x3A2D47),
      border: ThemeColor(hex: 0x574267),
      shadow: ThemeColor.black.withAlpha(0.40),
      preferredColorScheme: .dark
    )
  )

  /// Sleek OLED graphite-black with a subtle slate sheen and electric indigo accent.
  static let obsidian = AppTheme(
    id: "obsidian",
    title: "Obsidian",
    symbolName: "diamond.fill",
    access: .pro,
    appearance: ThemeAppearance(
      background: ThemeColor(hex: 0x0A0C10),
      gradientStart: ThemeColor(hex: 0x191E29),
      gradientEnd: ThemeColor(hex: 0x0A0C10),
      accent: ThemeColor(hex: 0x7C8CFF),
      primaryForeground: ThemeColor(hex: 0xF1F4F9),
      secondaryForeground: ThemeColor(hex: 0x96A0B2),
      surface: ThemeColor(hex: 0x12151D),
      elevatedSurface: ThemeColor(hex: 0x1A1F2B),
      border: ThemeColor(hex: 0x2A3242),
      shadow: ThemeColor.black.withAlpha(0.48),
      preferredColorScheme: .dark
    )
  )

  /// Deep pine-black canvas with crisp emerald surfaces and luminous mint-emerald actions.
  static let evergreen = AppTheme(
    id: "evergreen",
    title: "Evergreen",
    symbolName: "leaf.fill",
    access: .pro,
    appearance: ThemeAppearance(
      background: ThemeColor(hex: 0x081412),
      gradientStart: ThemeColor(hex: 0x122D27),
      gradientEnd: ThemeColor(hex: 0x081412),
      accent: ThemeColor(hex: 0x34D399),
      primaryForeground: ThemeColor(hex: 0xE8F5F0),
      secondaryForeground: ThemeColor(hex: 0x8FB2A6),
      surface: ThemeColor(hex: 0x0F1F1C),
      elevatedSurface: ThemeColor(hex: 0x162C27),
      border: ThemeColor(hex: 0x24443D),
      shadow: ThemeColor.black.withAlpha(0.46),
      preferredColorScheme: .dark
    )
  )

  /// Deep wine-charcoal dusk palette with crisp warm ivory ink and luminous rose-coral actions.
  static let velvet = AppTheme(
    id: "velvet",
    title: "Velvet",
    symbolName: "sun.horizon.fill",
    access: .pro,
    appearance: ThemeAppearance(
      background: ThemeColor(hex: 0x170E14),
      gradientStart: ThemeColor(hex: 0x331B29),
      gradientEnd: ThemeColor(hex: 0x170E14),
      accent: ThemeColor(hex: 0xFB7185),
      primaryForeground: ThemeColor(hex: 0xFBF0F4),
      secondaryForeground: ThemeColor(hex: 0xC49EAE),
      surface: ThemeColor(hex: 0x23151E),
      elevatedSurface: ThemeColor(hex: 0x2F1C28),
      border: ThemeColor(hex: 0x4D2F41),
      shadow: ThemeColor.black.withAlpha(0.44),
      preferredColorScheme: .dark
    )
  )

  // MARK: - Light

  /// Crisp Apple-native cool light workspace: airy mist canvas, bright white cards, cobalt actions.
  static let daylight = AppTheme(
    id: "daylight",
    title: "Daylight",
    symbolName: "sun.max.fill",
    access: .pro,
    appearance: ThemeAppearance(
      background: ThemeColor(hex: 0xECF1F8),
      gradientStart: ThemeColor(hex: 0xF3F6FB),
      gradientEnd: ThemeColor(hex: 0xE3EBF5),
      accent: ThemeColor(hex: 0x2563EB),
      primaryForeground: ThemeColor(hex: 0x141B29),
      secondaryForeground: ThemeColor(hex: 0x57657A),
      surface: ThemeColor(hex: 0xFAFCFF),
      elevatedSurface: ThemeColor(hex: 0xFFFFFF),
      border: ThemeColor(hex: 0xD2DCEB),
      shadow: ThemeColor(hex: 0x14213D, alpha: 0.10),
      preferredColorScheme: .light
    )
  )

  /// Warm editorial linen canvas with crisp ivory cards, deep espresso ink, and warm terracotta accents.
  static let paper = AppTheme(
    id: "paper",
    title: "Paper",
    symbolName: "doc.text",
    access: .pro,
    appearance: ThemeAppearance(
      background: ThemeColor(hex: 0xF0EADF),
      gradientStart: ThemeColor(hex: 0xF6F2EA),
      gradientEnd: ThemeColor(hex: 0xE7DEC9),
      accent: ThemeColor(hex: 0xC2592A),
      primaryForeground: ThemeColor(hex: 0x221D18),
      secondaryForeground: ThemeColor(hex: 0x6A5F54),
      surface: ThemeColor(hex: 0xFCF9F3),
      elevatedSurface: ThemeColor(hex: 0xFFFDF9),
      border: ThemeColor(hex: 0xD8CCBA),
      shadow: ThemeColor(hex: 0x4A3B2B, alpha: 0.11),
      preferredColorScheme: .light
    )
  )

  /// Light counterpart to Aubergine: airy lilac-mist canvas, crisp pearl cards, vivid violet accents.
  static let iris = AppTheme(
    id: "iris",
    title: "Iris",
    symbolName: "wand.and.stars",
    access: .pro,
    appearance: ThemeAppearance(
      background: ThemeColor(hex: 0xEFEAF7),
      gradientStart: ThemeColor(hex: 0xF5F1FB),
      gradientEnd: ThemeColor(hex: 0xE6DCF4),
      accent: ThemeColor(hex: 0x7C3AED),
      primaryForeground: ThemeColor(hex: 0x1F182B),
      secondaryForeground: ThemeColor(hex: 0x665B7A),
      surface: ThemeColor(hex: 0xFBF9FF),
      elevatedSurface: ThemeColor(hex: 0xFFFFFF),
      border: ThemeColor(hex: 0xD9CEE9),
      shadow: ThemeColor(hex: 0x3B2667, alpha: 0.11),
      preferredColorScheme: .light
    )
  )

  /// Fresh botanical mist canvas with crisp white cards, forest ink, and clean emerald accents.
  static let sage = AppTheme(
    id: "sage",
    title: "Sage",
    symbolName: "leaf.fill",
    access: .pro,
    appearance: ThemeAppearance(
      background: ThemeColor(hex: 0xEAF2EC),
      gradientStart: ThemeColor(hex: 0xF2F7F3),
      gradientEnd: ThemeColor(hex: 0xDFEBE3),
      accent: ThemeColor(hex: 0x0F8A5F),
      primaryForeground: ThemeColor(hex: 0x16251D),
      secondaryForeground: ThemeColor(hex: 0x526A5C),
      surface: ThemeColor(hex: 0xF9FCFA),
      elevatedSurface: ThemeColor(hex: 0xFFFFFF),
      border: ThemeColor(hex: 0xC9DDD0),
      shadow: ThemeColor(hex: 0x1A3A2A, alpha: 0.10),
      preferredColorScheme: .light
    )
  )

  /// Refined blush-porcelain canvas with crisp white cards and vivid editorial rose accents.
  static let sakura = AppTheme(
    id: "sakura",
    title: "Sakura",
    symbolName: "camera.macro",
    access: .pro,
    appearance: ThemeAppearance(
      background: ThemeColor(hex: 0xF6ECF0),
      gradientStart: ThemeColor(hex: 0xFAF3F6),
      gradientEnd: ThemeColor(hex: 0xEFE0E6),
      accent: ThemeColor(hex: 0xD6336C),
      primaryForeground: ThemeColor(hex: 0x291A21),
      secondaryForeground: ThemeColor(hex: 0x745B66),
      surface: ThemeColor(hex: 0xFFF9FB),
      elevatedSurface: ThemeColor(hex: 0xFFFFFF),
      border: ThemeColor(hex: 0xE6CED7),
      shadow: ThemeColor(hex: 0x5C253A, alpha: 0.10),
      preferredColorScheme: .light
    )
  )

  static let catalog = ThemeCatalog(
    themes: [
      midnight,
      aubergine,
      obsidian,
      evergreen,
      velvet,
      daylight,
      paper,
      iris,
      sage,
      sakura,
    ],
    fallbackThemeID: midnight.id
  )
}
