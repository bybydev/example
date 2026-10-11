import AppFoundation
import Foundation

enum ReadAloudCommerce {
    static let lifetimeProductID =
        "com.hoangbkit.readaloud.pro.lifetime"
    static let yearlyProductID =
        "com.hoangbkit.readaloud.pro.yearly"
    static let monthlyProductID =
        "com.hoangbkit.readaloud.pro.monthly"

    static let supportURL =
        URL(
            string:
                "https://github.com/hoangbkit/ReadAloud/issues"
        )!
    static let privacyURL =
        URL(
            string:
                "https://github.com/hoangbkit/ReadAloud/blob/master/docs/PRIVACY.md"
        )!
    static let termsURL =
        URL(
            string:
                "https://github.com/hoangbkit/ReadAloud/blob/master/docs/TERMS.md"
        )!

    static let features: [PurchaseFeature] = [
        PurchaseFeature(
            id: "voices",
            systemImage: "waveform.circle.fill",
            title: "All Voices",
            message: "Unlock all 28 American and British English Kokoro voices.",
            freeValue: "Heart",
            proValue: "All 28 voices"
        ),
        PurchaseFeature(
            id: "themes",
            systemImage: "paintpalette.fill",
            title: "Premium Themes",
            message: "Unlock the complete ReadAloud theme collection.",
            freeValue: "ReadAloud Light + Dark",
            proValue: "All themes"
        ),
    ]

    static let purchaseConfiguration =
        PurchaseConfiguration(
            productIDs: [
                lifetimeProductID,
                yearlyProductID,
                monthlyProductID,
            ],
            preferredProductID:
                lifetimeProductID,
            features: features,
            offlineEntitlements:
                .verifiedCache(.init())
        )

    // Local StoreKit / developer-simulation prices only.
    // Production App Store pricing remains a release decision.
    static let simulatedProducts:
        [PurchaseProduct] = [
            PurchaseProduct(
                id: lifetimeProductID,
                displayName: "Lifetime",
                description:
                    "One-time purchase for permanent ReadAloud Pro access.",
                displayPrice: "$49.99",
                price: 49.99
            ),
            PurchaseProduct(
                id: yearlyProductID,
                displayName: "Yearly",
                description:
                    "ReadAloud Pro billed yearly.",
                displayPrice: "$24.99",
                price: 24.99,
                subscriptionPeriod:
                    .init(
                        value: 1,
                        unit: .year
                    )
            ),
            PurchaseProduct(
                id: monthlyProductID,
                displayName: "Monthly",
                description:
                    "ReadAloud Pro billed monthly.",
                displayPrice: "$4.99",
                price: 4.99,
                subscriptionPeriod:
                    .init(
                        value: 1,
                        unit: .month
                    )
            ),
        ]

    static let paywallConfiguration =
        FoundationPaywallConfiguration(
            badge: "READALOUD PRO",
            title:
                "Make every book sound like yours",
            subtitle:
                "Unlock all 28 English voices and premium app themes. Reading, projects, generation, and chapter controls are free.",
            purchaseButtonTitle:
                "Continue",
            highlightedProductID:
                lifetimeProductID,
            highlightedProductBadge:
                "BEST VALUE",
            privacyURL: privacyURL,
            termsURL: termsURL
        )

    static let planConfiguration =
        ProPlanSettingsConfiguration(
            sectionTitle: "Plan",
            freePlanTitle: "Free",
            activePlanTitle:
                "ReadAloud Pro",
            unlockTitle: "Unlock Pro",
            comparePlansTitle:
                "Compare plans"
        )
}
