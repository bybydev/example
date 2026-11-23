import AppFoundation
import BYOKchatProviderCore
import SwiftUI

enum BYOKProFeature: String, Sendable {
  case themes
  case providerAccounts
  case projects
  case mcpServers
  case analytics
  case chatSearch

  var upsellConfiguration: LimitReachedUpsellConfiguration {
    LimitReachedUpsellConfiguration(
      navigationTitle: "BYOK Pro",
      title: title,
      message: message,
      symbolName: symbolName,
      comparisonTitle: "Free vs Pro",
      comparisonSubtitle: "Saved data is preserved if Pro expires; access to Pro-only features and historical analytics is locked.",
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
    case .chatSearch:
      "Unlock full-text chat search"
    }
  }

  private var message: String {
    switch self {
    case .themes:
      "Choose from every BYOK theme with Pro. Midnight is the only free theme."
    case .providerAccounts:
      "Keep your existing connection, or upgrade to add unlimited connections."
    case .projects:
      "Keep your existing project, or upgrade to create unlimited projects."
    case .mcpServers:
      "Keep your existing server, or upgrade to connect unlimited MCP servers."
    case .analytics:
      "Every analytics feature is free for today. Upgrade to Pro to explore your usage, performance, reliability, and breakdowns across earlier dates."
    case .chatSearch:
      "Search chat titles for free. Upgrade to Pro to search across every message and attachment name in your history."
    }
  }

  private var symbolName: String {
    switch self {
    case .themes: "paintpalette.fill"
    case .providerAccounts: "link"
    case .projects: "folder.fill"
    case .mcpServers: "shippingbox.fill"
    case .analytics: "chart.bar.xaxis"
    case .chatSearch: "magnifyingglass"
    }
  }
}

enum BYOKProAccess {
  static let freeThemeCount = 1
  static let freeProviderAccountLimit = BYOKProPolicy.freeProviderAccountLimit
  static let freeProjectLimit = BYOKProPolicy.freeProjectLimit
  static let freeMCPServerLimit = BYOKProPolicy.freeMCPServerLimit

  /// The single feature catalog for AppFoundation's paywall, upsell, and
  /// Compare Plans surfaces. Keep the requested order, with themes last.
  static let features: [PurchaseFeature] = [
    PurchaseFeature(
      id: "provider-accounts",
      systemImage: "key.horizontal.fill",
      title: "Provider accounts",
      message: "Connect as many provider accounts as you need instead of the single free account.",
      freeValue: "1",
      proValue: "Unlimited"
    ),
    PurchaseFeature(
      id: "projects",
      systemImage: "folder.fill",
      title: "Projects",
      message: "Organize chats, files, prompts, models, and tools across unlimited projects.",
      freeValue: "1",
      proValue: "Unlimited"
    ),
    PurchaseFeature(
      id: "mcp-servers",
      systemImage: "shippingbox.fill",
      title: "MCP servers",
      message: "Connect unlimited remote MCP servers instead of the single free server.",
      freeValue: "1",
      proValue: "Unlimited"
    ),
    PurchaseFeature(
      id: "analytics-history",
      systemImage: "chart.bar.xaxis",
      title: "Usage analytics",
      message: "All analytics features are free for today. Pro unlocks 7-day, 30-day, monthly, and all-time history.",
      freeValue: "Today",
      proValue: "All date ranges"
    ),
    PurchaseFeature(
      id: "chat-search",
      systemImage: "magnifyingglass",
      title: "Chat search",
      message: "Search chat titles for free. Pro unlocks fast full-text search across every message and attachment name.",
      freeValue: "Titles",
      proValue: "Full text search"
    ),
    PurchaseFeature(
      id: "themes",
      systemImage: "paintpalette.fill",
      title: "Themes",
      message: "Midnight is free. Pro unlocks the complete theme collection, including Paper.",
      freeValue: "Midnight",
      proValue: "All themes"
    ),
  ]

  static var comparisonRows: [LimitReachedComparisonRow] {
    features.map(LimitReachedComparisonRow.init)
  }

  static func canCreateProviderAccount(currentCount: Int, hasPro: Bool) -> Bool {
    BYOKProPolicy.canCreateProviderAccount(currentCount: currentCount, hasPro: hasPro)
  }

  static func canCreateProject(currentCount: Int, hasPro: Bool) -> Bool {
    BYOKProPolicy.canCreateProject(currentCount: currentCount, hasPro: hasPro)
  }

  static func canCreateMCPServer(currentCount: Int, hasPro: Bool) -> Bool {
    BYOKProPolicy.canCreateMCPServer(currentCount: currentCount, hasPro: hasPro)
  }

  static func canUseFullTextSearch(hasPro: Bool) -> Bool {
    BYOKProPolicy.canUseFullTextSearch(hasPro: hasPro)
  }
}

struct BYOKProUpsellFlow: View {
  let feature: BYOKProFeature

  @Environment(PurchaseManager.self) private var purchaseManager
  @Environment(AppModel.self) private var appModel: AppModel?
  @State private var didTrackRequest = false

  var body: some View {
    LimitReachedUpsellFlow(configuration: feature.upsellConfiguration) {
      ProPaywallView(
        purchases: purchaseManager,
        configuration: BYOKPurchaseStore.paywallConfiguration,
        initialSelectedProductID: BYOKPurchaseStore.yearlyProductID
      )
      .environment(purchaseManager)
    }
    .onAppear {
      guard !didTrackRequest else { return }
      didTrackRequest = true
      appModel?.reviewPrompt.recordPaywallShown()
      BYOKAppAnalytics.track(.upgradeRequested, dimension: .init(feature: feature))
    }
  }
}