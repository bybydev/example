import AppFoundation
import SwiftUI

enum BYOKProFeature: String, Sendable {
  case themes
  case providerAccounts
  case projects
  case mcpServers
  case analytics

  var upsellConfiguration: LimitReachedUpsellConfiguration {
    LimitReachedUpsellConfiguration(
      navigationTitle: "BYOK Pro",
      title: title,
      message: message,
      symbolName: symbolName,
      comparisonTitle: "Free vs Pro",
      comparisonSubtitle: "Your existing data stays available if Pro expires.",
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
      "Free includes 1 provider account"
    case .projects:
      "Free includes 1 project"
    case .mcpServers:
      "Free includes 1 MCP server"
    case .analytics:
      "Unlock advanced analytics"
    }
  }

  private var message: String {
    switch self {
    case .themes:
      "Choose from every BYOK theme with Pro. Free includes Paper and Midnight."
    case .providerAccounts:
      "Keep your existing account, or upgrade to connect unlimited provider accounts."
    case .projects:
      "Keep your existing project, or upgrade to create unlimited projects."
    case .mcpServers:
      "Keep your existing server, or upgrade to connect unlimited MCP servers."
    case .analytics:
      "Basic monthly usage stays free. Pro adds performance, reliability, breakdowns, budgets, and deeper insights."
    }
  }

  private var symbolName: String {
    switch self {
    case .themes: "paintpalette.fill"
    case .providerAccounts: "key.horizontal.fill"
    case .projects: "folder.fill"
    case .mcpServers: "shippingbox.fill"
    case .analytics: "chart.bar.xaxis"
    }
  }
}

enum BYOKProAccess {
  static let freeThemeCount = 2
  static let freeProviderAccountLimit = 1
  static let freeProjectLimit = 1
  static let freeMCPServerLimit = 1

  static let comparisonRows: [LimitReachedComparisonRow] = [
    LimitReachedComparisonRow(feature: "Themes", freeValue: "2", proValue: "All themes"),
    LimitReachedComparisonRow(feature: "Provider accounts", freeValue: "1", proValue: "Unlimited"),
    LimitReachedComparisonRow(feature: "Projects", freeValue: "1", proValue: "Unlimited"),
    LimitReachedComparisonRow(feature: "MCP servers", freeValue: "1", proValue: "Unlimited"),
    LimitReachedComparisonRow(feature: "Usage analytics", freeValue: "Basic", proValue: "Advanced"),
  ]

  static func canCreateProviderAccount(currentCount: Int, hasPro: Bool) -> Bool {
    hasPro || currentCount < freeProviderAccountLimit
  }

  static func canCreateProject(currentCount: Int, hasPro: Bool) -> Bool {
    hasPro || currentCount < freeProjectLimit
  }

  static func canCreateMCPServer(currentCount: Int, hasPro: Bool) -> Bool {
    hasPro || currentCount < freeMCPServerLimit
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
