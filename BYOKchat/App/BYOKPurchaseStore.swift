import AppFoundation
import Foundation

@MainActor
final class BYOKPurchaseStore {
  static let monthlyProductID = "com.hoangbkit.byokchat.pro.monthly"
  static let yearlyProductID = "com.hoangbkit.byokchat.pro.yearly"
  static let lifetimeProductID = "com.hoangbkit.byokchat.pro.lifetime"

  #if DEBUG
  private static let simulatedModeKey = "byokchat.developer.simulatedPurchases"
  #endif

  let manager: PurchaseManager

  init() {
    #if DEBUG
    let startsSimulated = UserDefaults.standard.bool(forKey: Self.simulatedModeKey)
    #else
    let startsSimulated = false
    #endif

    manager = PurchaseManager(
      configuration: PurchaseConfiguration(
        productIDs: [
          Self.monthlyProductID,
          Self.yearlyProductID,
          Self.lifetimeProductID,
        ],
        preferredProductID: Self.yearlyProductID
      ),
      simulated: startsSimulated,
      simulatedProducts: Self.simulatedProducts,
      simulatedPersistenceKey: "byokchat.simulatedPurchases"
    )
  }

  var hasPro: Bool { manager.hasPro }

  func prepare() async {
    await manager.prepare()
  }

  #if DEBUG
  var isUsingSimulatedPurchases: Bool {
    manager.isUsingSimulatedPurchases
  }

  static func makeScreenshotPreviewManager() -> PurchaseManager {
    PurchaseManager.screenshotPreview(
      configuration: PurchaseConfiguration(
        productIDs: [
          Self.monthlyProductID,
          Self.yearlyProductID,
          Self.lifetimeProductID,
        ],
        preferredProductID: Self.yearlyProductID
      ),
      products: simulatedProducts
    )
  }

  func setSimulatedPurchasesEnabled(_ enabled: Bool) async {
    UserDefaults.standard.set(enabled, forKey: Self.simulatedModeKey)
    await manager.setSimulatedPurchasesEnabled(enabled)
  }
  #endif

  static let paywallConfiguration = FoundationPaywallConfiguration(
    badge: "BYOK PRO",
    title: "Upgrade to BYOK Pro",
    subtitle: "Unlock all themes, unlimited configurations, and advanced local usage analytics.",
    features: [
      FoundationPaywallFeature(
        id: "themes",
        systemImage: "paintpalette.fill",
        title: "All themes",
        message: "Free includes 2 themes. Pro unlocks the complete theme collection."
      ),
      FoundationPaywallFeature(
        id: "provider-accounts",
        systemImage: "key.horizontal.fill",
        title: "Unlimited provider accounts",
        message: "Connect as many provider accounts as you need instead of the single free account."
      ),
      FoundationPaywallFeature(
        id: "projects",
        systemImage: "folder.fill",
        title: "Unlimited projects",
        message: "Organize chats, files, prompts, models, and tools across unlimited projects."
      ),
      FoundationPaywallFeature(
        id: "mcp-servers",
        systemImage: "shippingbox.fill",
        title: "Unlimited MCP servers",
        message: "Connect unlimited remote MCP servers instead of the single free server."
      ),
      FoundationPaywallFeature(
        id: "advanced-analytics",
        systemImage: "chart.bar.xaxis",
        title: "Advanced usage analytics",
        message: "Add performance, reliability, provider/model breakdowns, budgets, and deeper insights."
      ),
    ],
    highlightedProductID: yearlyProductID,
    highlightedProductBadge: "BEST VALUE",
    privacyURL: URL(string: "https://byok.pro/privacy"),
    termsURL: URL(string: "https://byok.pro/terms")
  )

  private static let simulatedProducts: [PurchaseProduct] = [
    PurchaseProduct(
      id: monthlyProductID,
      displayName: "BYOK Pro Monthly",
      description: "BYOK Pro for one month",
      displayPrice: "$6.99",
      price: 6.99,
      subscriptionPeriod: .init(value: 1, unit: .month)
    ),
    PurchaseProduct(
      id: yearlyProductID,
      displayName: "BYOK Pro Yearly",
      description: "BYOK Pro for one year",
      displayPrice: "$49.99",
      price: 49.99,
      subscriptionPeriod: .init(value: 1, unit: .year)
    ),
    PurchaseProduct(
      id: lifetimeProductID,
      displayName: "BYOK Pro Lifetime",
      description: "Pay once and keep BYOK Pro forever",
      displayPrice: "$129.99",
      price: 129.99
    ),
  ]
}
