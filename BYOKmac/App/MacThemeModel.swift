import Foundation
import MacAppFoundation

@MainActor
enum MacThemeFoundation {
  static let storageKey = "mac.theme"

  static let freeThemeIDs: Set<MacAppThemeID> = [
    .githubDarkDimmed,
    .githubLight,
  ]

  static let configuration: MacAppThemeConfiguration = {
    let allThemes = MacAppThemeCatalog.allBuiltIn
    let allThemeIDs = Set(allThemes.map(\.id))

    return MacAppThemeConfiguration(
      themes: allThemes,
      defaultThemeID: .githubLight,
      storageKey: storageKey,
      proThemeIDs: allThemeIDs.subtracting(freeThemeIDs)
    )
  }()

  static let store = makeStore()

  static func isProTheme(_ themeID: MacAppThemeID) -> Bool {
    configuration.isProTheme(themeID)
  }

  static func isFreeTheme(_ themeID: MacAppThemeID) -> Bool {
    freeThemeIDs.contains(themeID)
  }

  static func makeStore(defaults: UserDefaults = .standard) -> MacAppThemeStore {
    migrateLegacyThemeID(defaults: defaults)
    return MacAppThemeStore(
      configuration: configuration,
      defaults: defaults
    )
  }

  /// BYOKchat's previous Mac theme enum persisted a few camelCase raw values.
  /// MAF uses stable kebab-case IDs, so migrate those values in place before
  /// constructing the shared theme store. The migration is intentionally
  /// idempotent and preserves all already-compatible theme IDs.
  static func migrateLegacyThemeID(defaults: UserDefaults = .standard) {
    guard let legacyID = defaults.string(forKey: storageKey) else { return }

    let migratedID: String?
    switch legacyID {
    case "githubDarkDimmed":
      migratedID = MacAppThemeID.githubDarkDimmed.rawValue
    case "morningMist":
      migratedID = MacAppThemeID.morningMist.rawValue
    case "softSage":
      migratedID = MacAppThemeID.softSage.rawValue
    case "githubLight":
      migratedID = MacAppThemeID.githubLight.rawValue
    default:
      migratedID = nil
    }

    if let migratedID {
      defaults.set(migratedID, forKey: storageKey)
    }
  }
}
