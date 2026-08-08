import AppFoundation

@MainActor
enum BYOKchatThemes {
  // MARK: - Light

  /// Warm editorial paper: soft cream canvas, sepia ink, restrained terracotta accent.
  static let paper = AppTheme(
    id: "paper",
    title: "Paper",
    symbolName: "doc.text",
    access: .free,
    appearance: ThemeAppearance(
      background: ThemeColor(hex: 0xF7F3EA),
      gradientStart: ThemeColor(hex: 0xFFFDF8),
      gradientEnd: ThemeColor(hex: 0xE9DFC9),
      accent: ThemeColor(hex: 0x95552F),
      primaryForeground: ThemeColor(hex: 0x27231F),
      secondaryForeground: ThemeColor(hex: 0x6B6259),
      surface: ThemeColor(hex: 0xEFE7D8),
      elevatedSurface: ThemeColor(hex: 0xFFFDF8),
      border: ThemeColor(hex: 0xCFC1AE),
      shadow: ThemeColor(hex: 0x5E4D3B, alpha: 0.16),
      preferredColorScheme: .light
    )
  )

  /// GitHub's familiar clean light hierarchy: white canvas, cool gray surfaces, blue actions.
  static let githubLight = AppTheme(
    id: "github-light",
    title: "GitHub Light",
    symbolName: "chevron.left.forwardslash.chevron.right",
    access: .free,
    appearance: ThemeAppearance(
      background: ThemeColor(hex: 0xFFFFFF),
      gradientStart: ThemeColor(hex: 0xFFFFFF),
      gradientEnd: ThemeColor(hex: 0xF0F3F6),
      accent: ThemeColor(hex: 0x0969DA),
      primaryForeground: ThemeColor(hex: 0x1F2328),
      secondaryForeground: ThemeColor(hex: 0x59636E),
      surface: ThemeColor(hex: 0xF6F8FA),
      elevatedSurface: ThemeColor(hex: 0xFFFFFF),
      border: ThemeColor(hex: 0xD0D7DE),
      shadow: ThemeColor(hex: 0x1F2328, alpha: 0.12),
      preferredColorScheme: .light
    )
  )

  /// Soft blush without sacrificing text contrast; rose is reserved for emphasis and actions.
  static let sakura = AppTheme(
    id: "sakura",
    title: "Sakura",
    symbolName: "camera.macro",
    access: .free,
    appearance: ThemeAppearance(
      background: ThemeColor(hex: 0xFFF7F9),
      gradientStart: ThemeColor(hex: 0xFFFDFE),
      gradientEnd: ThemeColor(hex: 0xF7E3E9),
      accent: ThemeColor(hex: 0xB4235A),
      primaryForeground: ThemeColor(hex: 0x33242A),
      secondaryForeground: ThemeColor(hex: 0x746068),
      surface: ThemeColor(hex: 0xFCEBF0),
      elevatedSurface: ThemeColor(hex: 0xFFFFFF),
      border: ThemeColor(hex: 0xE8C8D3),
      shadow: ThemeColor(hex: 0x6A3346, alpha: 0.14),
      preferredColorScheme: .light
    )
  )

  /// Calm botanical palette with a clearly green surface hierarchy rather than a neutral recolor.
  static let sage = AppTheme(
    id: "sage",
    title: "Sage",
    symbolName: "leaf.fill",
    access: .free,
    appearance: ThemeAppearance(
      background: ThemeColor(hex: 0xF3F7F2),
      gradientStart: ThemeColor(hex: 0xFBFDFB),
      gradientEnd: ThemeColor(hex: 0xDFEADF),
      accent: ThemeColor(hex: 0x2F6F4E),
      primaryForeground: ThemeColor(hex: 0x1F2B22),
      secondaryForeground: ThemeColor(hex: 0x5F6F64),
      surface: ThemeColor(hex: 0xE7F0E8),
      elevatedSurface: ThemeColor(hex: 0xFBFDFB),
      border: ThemeColor(hex: 0xC7D7CA),
      shadow: ThemeColor(hex: 0x294232, alpha: 0.14),
      preferredColorScheme: .light
    )
  )

  /// Solarized-inspired parchment and blue, adjusted darker where needed for accessible small text.
  static let solarizedLight = AppTheme(
    id: "solarized-light",
    title: "Solarized Light",
    symbolName: "sun.max.fill",
    access: .free,
    appearance: ThemeAppearance(
      background: ThemeColor(hex: 0xFDF6E3),
      gradientStart: ThemeColor(hex: 0xFFFDF1),
      gradientEnd: ThemeColor(hex: 0xE9E2C8),
      accent: ThemeColor(hex: 0x005F87),
      primaryForeground: ThemeColor(hex: 0x3C4F55),
      secondaryForeground: ThemeColor(hex: 0x52666D),
      surface: ThemeColor(hex: 0xEEE8D5),
      elevatedSurface: ThemeColor(hex: 0xFFFDF4),
      border: ThemeColor(hex: 0xD6CEB8),
      shadow: ThemeColor(hex: 0x586E75, alpha: 0.15),
      preferredColorScheme: .light
    )
  )

  // MARK: - Dark

  /// GitHub Dark Dimmed: lower glare than true black while preserving GitHub's blue/gray hierarchy.
  static let githubDarkDimmed = AppTheme(
    id: "github-dark-dimmed",
    title: "GitHub Dark Dimmed",
    symbolName: "chevron.left.forwardslash.chevron.right",
    access: .free,
    appearance: ThemeAppearance(
      background: ThemeColor(hex: 0x22272E),
      gradientStart: ThemeColor(hex: 0x2D333B),
      gradientEnd: ThemeColor(hex: 0x1C2128),
      accent: ThemeColor(hex: 0x539BF5),
      primaryForeground: ThemeColor(hex: 0xADBAC7),
      secondaryForeground: ThemeColor(hex: 0x909DA8),
      surface: ThemeColor(hex: 0x2D333B),
      elevatedSurface: ThemeColor(hex: 0x373E47),
      border: ThemeColor(hex: 0x444C56),
      shadow: ThemeColor.black.withAlpha(0.34),
      preferredColorScheme: .dark
    )
  )

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

  /// Nordic slate with icy cyan accents; noticeably softer and cooler than GitHub Dimmed.
  static let nordic = AppTheme(
    id: "nordic",
    title: "Nordic",
    symbolName: "snowflake",
    access: .free,
    appearance: ThemeAppearance(
      background: ThemeColor(hex: 0x2E3440),
      gradientStart: ThemeColor(hex: 0x3B4252),
      gradientEnd: ThemeColor(hex: 0x2E3440),
      accent: ThemeColor(hex: 0x88C0D0),
      primaryForeground: ThemeColor(hex: 0xECEFF4),
      secondaryForeground: ThemeColor(hex: 0xD8DEE9),
      surface: ThemeColor(hex: 0x3B4252),
      elevatedSurface: ThemeColor(hex: 0x434C5E),
      border: ThemeColor(hex: 0x4C566A),
      shadow: ThemeColor.black.withAlpha(0.32),
      preferredColorScheme: .dark
    )
  )

  /// Purple-black creative theme with lavender controls and restrained violet surfaces.
  static let aubergine = AppTheme(
    id: "aubergine",
    title: "Aubergine",
    symbolName: "sparkles",
    access: .free,
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

  /// Warm charcoal and copper for a dark theme that does not read blue, gray, or purple.
  static let ember = AppTheme(
    id: "ember",
    title: "Ember",
    symbolName: "flame.fill",
    access: .free,
    appearance: ThemeAppearance(
      background: ThemeColor(hex: 0x1B1513),
      gradientStart: ThemeColor(hex: 0x352A26),
      gradientEnd: ThemeColor(hex: 0x1B1513),
      accent: ThemeColor(hex: 0xE07A45),
      primaryForeground: ThemeColor(hex: 0xF5EDE8),
      secondaryForeground: ThemeColor(hex: 0xBDA9A0),
      surface: ThemeColor(hex: 0x2A211E),
      elevatedSurface: ThemeColor(hex: 0x352A26),
      border: ThemeColor(hex: 0x503C34),
      shadow: ThemeColor.black.withAlpha(0.44),
      preferredColorScheme: .dark
    )
  )

  static let catalog = ThemeCatalog(
    themes: [
      paper,
      githubLight,
      sakura,
      sage,
      solarizedLight,
      githubDarkDimmed,
      midnight,
      nordic,
      aubergine,
      ember,
    ],
    fallbackThemeID: paper.id
  )
}
