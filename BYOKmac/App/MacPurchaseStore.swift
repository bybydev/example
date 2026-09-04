import BYOKchatProviderCore
import Foundation
import MacAppFoundation
import Observation
import SwiftUI

@MainActor
enum MacWindowID {
  static let proPaywall = "byokchat.pro-paywall"
}

@MainActor
enum MacPurchaseStore {
  static let monthlyProductID = BYOKProCatalog.monthlyProductID
  static let yearlyProductID = BYOKProCatalog.yearlyProductID
  static let lifetimeProductID = BYOKProCatalog.lifetimeProductID

  #if DEBUG
  static let simulatedModeKey = "byokchat.mac.developer.simulatedPurchases"
  #endif

  static let features: [PurchaseFeature] = [
    PurchaseFeature(
      id: "themes",
      systemImage: "paintpalette.fill",
      title: "All themes",
      message: "Free includes 2 themes. Pro unlocks the complete theme collection.",
      freeValue: "2 themes",
      proValue: "All themes"
    ),
    PurchaseFeature(
      id: "provider-accounts",
      systemImage: "key.horizontal.fill",
      title: "Unlimited provider accounts",
      message: "Connect as many provider accounts as you need instead of the single free account.",
      freeValue: "1 connection",
      proValue: "Unlimited"
    ),
    PurchaseFeature(
      id: "projects",
      systemImage: "folder.fill",
      title: "Unlimited projects",
      message: "Organize chats, files, prompts, models, and tools across unlimited projects.",
      freeValue: "1 project",
      proValue: "Unlimited"
    ),
    PurchaseFeature(
      id: "mcp-servers",
      systemImage: "shippingbox.fill",
      title: "Unlimited MCP servers",
      message: "Connect unlimited remote MCP servers instead of the single free server.",
      freeValue: "1 server",
      proValue: "Unlimited"
    ),
    PurchaseFeature(
      id: "library-items",
      systemImage: "books.vertical.fill",
      title: "Unlimited saved files",
      message: "Keep using existing files and save more than the 10-file free limit.",
      freeValue: "10 files",
      proValue: "Unlimited"
    ),
    PurchaseFeature(
      id: "advanced-analytics",
      systemImage: "chart.bar.xaxis",
      title: "Advanced usage analytics",
      message: "Add performance, reliability, provider/model breakdowns, budgets, and deeper insights.",
      freeValue: "Basic",
      proValue: "Advanced"
    ),
  ]

  static let configuration = PurchaseConfiguration(
    productIDs: BYOKProCatalog.productIDs,
    preferredProductID: BYOKProCatalog.preferredProductID,
    features: features
  )

  static let simulatedProducts: [StoreProduct] = [
    StoreProduct(
      id: monthlyProductID,
      displayName: "BYOK Pro Monthly",
      description: "BYOK Pro for one month",
      displayPrice: "$6.99",
      price: 6.99,
      subscriptionPeriod: .init(value: 1, unit: .month)
    ),
    StoreProduct(
      id: yearlyProductID,
      displayName: "BYOK Pro Yearly",
      description: "BYOK Pro for one year",
      displayPrice: "$49.99",
      price: 49.99,
      subscriptionPeriod: .init(value: 1, unit: .year)
    ),
    StoreProduct(
      id: lifetimeProductID,
      displayName: "BYOK Pro Lifetime",
      description: "Pay once and keep BYOK Pro forever",
      displayPrice: "$129.99",
      price: 129.99,
      subscriptionPeriod: nil
    ),
  ]

  static let manager: PurchaseManager = {
    #if DEBUG
    let startsSimulated = UserDefaults.standard.bool(forKey: simulatedModeKey)
    #else
    let startsSimulated = false
    #endif

    return PurchaseManager(
      configuration: configuration,
      simulated: startsSimulated,
      simulatedProducts: simulatedProducts,
      simulatedPersistenceKey: "byokchat.mac.simulatedPurchases"
    )
  }()

  static let paywallConfiguration = ProPaywallConfiguration(
    title: "BYOK Pro",
    subtitle: "Unlock every theme, unlimited configurations, saved files, and advanced local analytics.",
    highlightedProductID: yearlyProductID,
    highlightedProductBadge: "BEST VALUE",
    termsURL: URL(string: "https://byok.pro/terms")!,
    privacyURL: URL(string: "https://byok.pro/privacy")!,
    showsRedeemCode: true
  )

  static let planConfiguration = ProPlanPaneConfiguration(appName: "BYOKchat")

  #if DEBUG
  static var developerConfiguration: FoundationDeveloperConfiguration {
    FoundationDeveloperConfiguration(
      replays: [
        FoundationDeveloperReplay(
          id: "paywall",
          title: "Pro Paywall",
          systemImage: "crown.fill"
        ) { dismiss in
          ProPaywallView(
            purchaseManager: manager,
            configuration: paywallConfiguration,
            onPurchased: { _ in dismiss() },
            onRestored: dismiss,
            onClose: dismiss
          )
        }
      ]
    )
  }
  #endif
}

enum MacProFeature: String, Sendable {
  case themes
  case providerAccounts
  case projects
  case mcpServers
  case libraryItems
  case analytics
}

@MainActor
@Observable
final class MacProGateCenter {
  static let shared = MacProGateCenter()

  private(set) var requestID = 0
  private(set) var feature: MacProFeature?

  private init() {}

  func request(_ feature: MacProFeature) {
    self.feature = feature
    requestID &+= 1
  }
}

@MainActor
enum MacProAccess {
  static let freeThemeCount = BYOKProPolicy.freeThemeCount
  static let freeProviderAccountLimit = BYOKProPolicy.freeProviderAccountLimit
  static let freeProjectLimit = BYOKProPolicy.freeProjectLimit
  static let freeMCPServerLimit = BYOKProPolicy.freeMCPServerLimit
  static let freeLibraryItemLimit = BYOKProPolicy.freeLibraryItemLimit

  static var hasPro: Bool { MacPurchaseStore.manager.hasPro }

  static func canUseTheme(_ theme: MacThemeID, hasPro: Bool) -> Bool {
    guard let index = MacThemeID.allCases.firstIndex(of: theme) else { return hasPro }
    return BYOKProPolicy.canUseTheme(at: index, hasPro: hasPro)
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

  static func remainingLibraryCapacity(currentCount: Int, hasPro: Bool) -> Int? {
    BYOKProPolicy.remainingLibraryCapacity(currentCount: currentCount, hasPro: hasPro)
  }

  static func canCreateLibraryItem(currentCount: Int, hasPro: Bool) -> Bool {
    BYOKProPolicy.canCreateLibraryItem(currentCount: currentCount, hasPro: hasPro)
  }

  static func requireProviderAccountCapacity(currentCount: Int) -> Bool {
    guard canCreateProviderAccount(currentCount: currentCount, hasPro: hasPro) else {
      MacProGateCenter.shared.request(.providerAccounts)
      return false
    }
    return true
  }

  static func requireProjectCapacity(currentCount: Int) -> Bool {
    guard canCreateProject(currentCount: currentCount, hasPro: hasPro) else {
      MacProGateCenter.shared.request(.projects)
      return false
    }
    return true
  }

  static func requireMCPServerCapacity(currentCount: Int) -> Bool {
    guard canCreateMCPServer(currentCount: currentCount, hasPro: hasPro) else {
      MacProGateCenter.shared.request(.mcpServers)
      return false
    }
    return true
  }

  static func requireLibraryCapacity(currentCount: Int, additions: Int = 1) -> Int {
    guard additions > 0 else { return 0 }
    guard let remaining = remainingLibraryCapacity(currentCount: currentCount, hasPro: hasPro) else {
      return additions
    }
    guard remaining > 0 else {
      MacProGateCenter.shared.request(.libraryItems)
      return 0
    }
    if additions > remaining {
      MacProGateCenter.shared.request(.libraryItems)
    }
    return min(additions, remaining)
  }
}

struct MacProPaywallWindow: View {
  let purchaseManager: PurchaseManager

  @Environment(\.dismissWindow) private var dismissWindow

  var body: some View {
    ProPaywallView(
      purchaseManager: purchaseManager,
      configuration: MacPurchaseStore.paywallConfiguration,
      onPurchased: { _ in close() },
      onRestored: close,
      onClose: close
    )
  }

  private func close() {
    dismissWindow(id: MacWindowID.proPaywall)
  }
}