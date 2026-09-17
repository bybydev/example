import MacAppFoundation

@MainActor
enum InkribeCommerce {
    static let monthlyProductID = "com.hoangbkit.inkribe.pro.monthly"
    static let yearlyProductID = "com.hoangbkit.inkribe.pro.yearly"
    static let lifetimeProductID = "com.hoangbkit.inkribe.pro.lifetime"

    static let productIDs = [
        monthlyProductID,
        yearlyProductID,
        lifetimeProductID
    ]

    static let configuration = PurchaseConfiguration(
        productIDs: productIDs,
        preferredProductID: yearlyProductID,
        features: []
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
