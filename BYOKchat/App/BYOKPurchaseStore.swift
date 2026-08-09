import AppFoundation
import Foundation

@MainActor
final class BYOKPurchaseStore {
  static let monthlyProductID = "com.hoangbkit.byokchat.pro.monthly"
  static let yearlyProductID = "com.hoangbkit.byokchat.pro.yearly"

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
        productIDs: [Self.monthlyProductID, Self.yearlyProductID],
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

  func setSimulatedPurchasesEnabled(_ enabled: Bool) async {
    UserDefaults.standard.set(enabled, forKey: Self.simulatedModeKey)
    await manager.setSimulatedPurchasesEnabled(enabled)
  }
  #endif

  static let paywallConfiguration = FoundationPaywallConfiguration(
    badge: "BYOK PRO",
    title: "Upgrade to BYOK Pro",
    subtitle: "Get higher usage limits and deeper insights while keeping your own provider accounts.",
    features: [
      FoundationPaywallFeature(
        id: "higher-limits",
        systemImage: "message.badge.waveform.fill",
        title: "Higher usage limits",
        message: "More monthly messages as Pro limits roll out."
      ),
      FoundationPaywallFeature(
        id: "usage-insights",
        systemImage: "chart.bar.xaxis",
        title: "Deeper usage insights",
        message: "See richer model, token, and conversation analytics as the usage module expands."
      ),
      FoundationPaywallFeature(
        id: "byok",
        systemImage: "key.horizontal.fill",
        title: "Keep your own keys",
        message: "Your provider accounts remain yours; Pro upgrades the BYOK app experience around them."
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
      displayPrice: "$7.99",
      price: 7.99,
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
  ]
}
