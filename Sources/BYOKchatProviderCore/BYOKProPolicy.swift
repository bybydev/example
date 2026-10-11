import Foundation

/// Cross-platform BYOK Pro product identifiers used by both Apple app targets.
public enum BYOKProCatalog: Sendable {
  public static let monthlyProductID = "com.hoangbkit.byokchat.pro.monthly"
  public static let yearlyProductID = "com.hoangbkit.byokchat.pro.yearly"
  public static let lifetimeProductID = "com.hoangbkit.byokchat.pro.lifetime"

  public static let productIDs = [
    monthlyProductID,
    yearlyProductID,
    lifetimeProductID,
  ]

  public static let preferredProductID = yearlyProductID
}

/// Platform-neutral Free vs Pro business rules.
///
/// Entitlement state remains platform-owned by AppFoundation/MacAppFoundation;
/// this type only answers what a given entitlement is allowed to do.
public enum BYOKProPolicy: Sendable {
  public static let freeThemeCount = 2
  public static let freeProviderAccountLimit = 1
  public static let freeProjectLimit = 1
  public static let freeMCPServerLimit = 1

  public static func canUseTheme(at index: Int, hasPro: Bool) -> Bool {
    hasPro || (index >= 0 && index < freeThemeCount)
  }

  public static func canCreateProviderAccount(currentCount: Int, hasPro: Bool) -> Bool {
    hasPro || currentCount < freeProviderAccountLimit
  }

  public static func canCreateProject(currentCount: Int, hasPro: Bool) -> Bool {
    hasPro || currentCount < freeProjectLimit
  }

  public static func canCreateMCPServer(currentCount: Int, hasPro: Bool) -> Bool {
    hasPro || currentCount < freeMCPServerLimit
  }

}