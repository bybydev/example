import AppFoundation
import BYOKchatProviderCore
import Foundation

@MainActor
final class BYOKPurchaseStore {
  static let monthlyProductID = BYOKProCatalog.monthlyProductID
  static let yearlyProductID = BYOKProCatalog.yearlyProductID
  static let lifetimeProductID = BYOKProCatalog.lifetimeProductID

  #if DEBUG
  static let simulatedModeKey = "byokchat.developer.simulatedPurchases"
  #endif

  static let purchaseConfiguration = PurchaseConfiguration(
    productIDs: BYOKProCatalog.productIDs,
    preferredProductID: BYOKProCatalog.preferredProductID,
    features: BYOKProAccess.features
  )

  let manager: PurchaseManager

  init() {
    #if DEBUG
    let startsSimulated = UserDefaults.standard.bool(forKey: Self.simulatedModeKey)
    #else
    let startsSimulated = false
    #endif

    manager = PurchaseManager(
      configuration: Self.purchaseConfiguration,
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
  static func makeScreenshotPreviewManager() -> PurchaseManager {
    PurchaseManager.screenshotPreview(
      configuration: Self.purchaseConfiguration,
      products: simulatedProducts
    )
  }
  #endif

  static let paywallConfiguration = FoundationPaywallConfiguration(
    badge: "BYOK PRO",
    title: "Upgrade to BYOK Pro",
    subtitle: "Unlock every theme, unlimited configurations, and your full analytics history.",
    highlightedProductID: yearlyProductID,
    highlightedProductBadge: "BEST VALUE",
    privacyURL: URL(string: "https://byok.pro/privacy")!,
    termsURL: URL(string: "https://byok.pro/terms")!
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
      displayPrice: "$29.99",
      price: 29.99,
      subscriptionPeriod: .init(value: 1, unit: .year)
    ),
    PurchaseProduct(
      id: lifetimeProductID,
      displayName: "BYOK Pro Lifetime",
      description: "Pay once and keep BYOK Pro forever",
      displayPrice: "$49.99",
      price: 49.99
    ),
  ]
}