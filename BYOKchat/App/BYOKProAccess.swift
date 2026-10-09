import AppFoundation
import BYOKchatProviderCore
import SwiftUI

enum BYOKProFeature: String, Sendable {
  case themes
  case providerAccounts
  case projects
  case mcpServers
  case analytics
  case libraryItems

  var upsellConfiguration: LimitReachedUpsellConfiguration {
    LimitReachedUpsellConfiguration(
      navigationTitle: "BYOK Pro",
      title: title,
      message: message,
      symbolName: symbolName,
      comparisonTitle: "Free vs Pro",
      comparisonSubtitle: "Saved data is preserved if Pro expires; access to Pro-only features and historical analytics is locked.",
      rows: BYOKProAccess.comparisonRows,
      unlockButtonTitle: "Unlock BYOK Pro",
      stayFreeButtonTitle: "Stay Free",
      comparisonAccessibilityLabel: "BYOK Free and Pro feature comparison"
    )
  }

  private var title: String {
    switch self {
    case .themes:
      "Unlock every theme"
    case .providerAccounts:
      "Free includes 1 connection"
    case .projects:
      "Free includes 1 project"
    case .mcpServers:
      "Free includes 1 MCP server"
    case .analytics:
      "Unlock analytics history"
    case .libraryItems:
      "Free includes \(BYOKProPolicy.freeLibraryItemLimit) saved files"
    }
  }

  private var message: String {
    switch self {
    case .themes:
      "Choose from every BYOK theme with Pro. Free includes Paper and Midnight."
    case .providerAccounts:
      "Keep your existing connection, or upgrade to add unlimited connections."
    case .projects:
      "Keep your existing project, or upgrade to create unlimited projects."
    case .mcpServers:
      "Keep your existing server, or upgrade to connect unlimited MCP servers."
    case .analytics:
      "Every analytics feature is free for today. Upgrade to Pro to explore your usage, performance, reliability, breakdowns, and budgets across earlier dates."
    case .libraryItems:
      "Keep your existing files, or upgrade to save unlimited files."
    }
  }

  private var symbolName: String {
    switch self {
    case .themes: "paintpalette.fill"
    case .providerAccounts: "link"
    case .projects: "folder.fill"
    case .mcpServers: "shippingbox.fill"
    case .analytics: "chart.bar.xaxis"
    case .libraryItems: "books.vertical.fill"
    }
  }
}

enum BYOKProAccess {
  static let freeThemeCount = BYOKProPolicy.freeThemeCount
  static let freeProviderAccountLimit = BYOKProPolicy.freeProviderAccountLimit
  static let freeProjectLimit = BYOKProPolicy.freeProjectLimit
  static let freeMCPServerLimit = BYOKProPolicy.freeMCPServerLimit
  static let freeLibraryItemLimit = BYOKProPolicy.freeLibraryItemLimit

  static let comparisonRows: [LimitReachedComparisonRow] = [
    LimitReachedComparisonRow(feature: "Themes", freeValue: "2", proValue: "All themes"),
    LimitReachedComparisonRow(feature: "Connections", freeValue: "1", proValue: "Unlimited"),
    LimitReachedComparisonRow(feature: "Projects", freeValue: "1", proValue: "Unlimited"),
    LimitReachedComparisonRow(feature: "MCP servers", freeValue: "1", proValue: "Unlimited"),
    LimitReachedComparisonRow(
      feature: "Saved files",
      freeValue: String(BYOKProPolicy.freeLibraryItemLimit),
      proValue: "Unlimited"
    ),
    LimitReachedComparisonRow(feature: "Usage analytics", freeValue: "Today", proValue: "All date ranges"),
  ]

  static func canCreateProviderAccount(currentCount: Int, hasPro: Bool) -> Bool {
    BYOKProPolicy.canCreateProviderAccount(currentCount: currentCount, hasPro: hasPro)
  }

  static func canCreateProject(currentCount: Int, hasPro: Bool) -> Bool {
    BYOKProPolicy.canCreateProject(currentCount: currentCount, hasPro: hasPro)
  }

  static func canCreateMCPServer(currentCount: Int, hasPro: Bool) -> Bool {
    BYOKProPolicy.canCreateMCPServer(currentCount: currentCount, hasPro: hasPro)
  }

  static func canCreateLibraryItem(currentCount: Int, hasPro: Bool) -> Bool {
    BYOKProPolicy.canCreateLibraryItem(currentCount: currentCount, hasPro: hasPro)
  }
}

struct BYOKProUpsellFlow: View {
  let feature: BYOKProFeature

  @Environment(PurchaseManager.self) private var purchaseManager

  var body: some View {
    LimitReachedUpsellFlow(configuration: feature.upsellConfiguration) {
      ProPaywallView(
        purchases: purchaseManager,
        configuration: BYOKPurchaseStore.paywallConfiguration,
        initialSelectedProductID: BYOKPurchaseStore.yearlyProductID
      )
      .environment(purchaseManager)
    }
  }
}