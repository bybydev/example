import Foundation
import MacAppFoundation

@MainActor
enum InkribeCommerce {
    static let monthlyProductID = "com.hoangbkit.inkribe.pro.monthly"
    static let yearlyProductID = "com.hoangbkit.inkribe.pro.yearly"
    static let lifetimeProductID = "com.hoangbkit.inkribe.pro.lifetime"

    // Placeholder legal destinations for v1 development. Replace before submission.
    static let termsURL = URL(string: "https://example.com/inkribe/terms")!
    static let privacyURL = URL(string: "https://example.com/inkribe/privacy")!

    static let productIDs = [
        monthlyProductID,
        yearlyProductID,
        lifetimeProductID
    ]

    static let configuration = PurchaseConfiguration(
        productIDs: productIDs,
        preferredProductID: yearlyProductID,
        features: InkribeProCapability.allCases.map(\.purchaseFeature)
    )

    static let paywallConfiguration = ProPaywallConfiguration(
        title: "Inkribe Pro",
        subtitle: "Unlock the power workflows already built into Inkribe.",
        features: configuration.features.map { ProPaywallFeature($0) },
        purchaseButtonTitle: "Continue",
        highlightedProductID: yearlyProductID,
        highlightedProductBadge: "BEST VALUE",
        termsURL: termsURL,
        privacyURL: privacyURL,
        showsRedeemCode: true
    )

    #if DEBUG
    static let simulatedProducts: [StoreProduct] = [
        StoreProduct(
            id: monthlyProductID,
            displayName: "Monthly",
            description: "Inkribe Pro, billed monthly.",
            displayPrice: "$4.99",
            price: 4.99,
            subscriptionPeriod: .init(value: 1, unit: .month)
        ),
        StoreProduct(
            id: yearlyProductID,
            displayName: "Yearly",
            description: "Inkribe Pro, billed yearly.",
            displayPrice: "$24.99",
            price: 24.99,
            subscriptionPeriod: .init(value: 1, unit: .year)
        ),
        StoreProduct(
            id: lifetimeProductID,
            displayName: "Lifetime",
            description: "Permanent access to Inkribe Pro.",
            displayPrice: "$49.99",
            price: 49.99,
            subscriptionPeriod: nil
        )
    ]
    #endif

    static func makePurchaseManager() -> PurchaseManager {
        #if DEBUG
        PurchaseManager(
            configuration: configuration,
            simulated: true,
            simulatedProducts: simulatedProducts,
            simulatedPersistenceKey: "Inkribe.simulatedPurchases"
        )
        #else
        PurchaseManager(configuration: configuration)
        #endif
    }
}
