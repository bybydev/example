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

    static let features:
        [PurchaseFeature] = [
            PurchaseFeature(
                id: "library",
                systemImage:
                    "books.vertical.fill",
                title:
                    "Unlimited Library",
                message:
                    "Keep an unlimited personal listening library.",
                freeValue:
                    "\(ReadAloudAccessPolicy.freeProjectLimit) projects",
                proValue:
                    "Unlimited projects"
            ),
            PurchaseFeature(
                id: "voices",
                systemImage:
                    "waveform.circle.fill",
                title: "All Voices",
                message:
                    "Use Heart, Bella, and Michael across your projects.",
                freeValue: "Heart",
                proValue: "All voices"
            ),
            PurchaseFeature(
                id: "chapter-narration",
                systemImage:
                    "slider.horizontal.3",
                title:
                    "Per-Chapter Narration",
                message:
                    "Override voice and synthesis speed for individual chapters.",
                freeValue:
                    "Project defaults",
                proValue:
                    "Per-chapter controls"
            ),
            PurchaseFeature(
                id: "offline-generation",
                systemImage:
                    "arrow.down.circle.fill",
                title:
                    "Advanced Offline Generation",
                message:
                    "Generate in bulk, prefetch upcoming chapters, and generate while listening.",
                freeValue:
                    "One chapter at a time",
                proValue:
                    "Bulk + prefetch"
            ),
            PurchaseFeature(
                id: "themes",
                systemImage:
                    "paintpalette.fill",
                title: "Premium Themes",
                message:
                    "Unlock the complete ReadAloud theme collection.",
                freeValue:
                    "Midnight + Paper",
                proValue:
                    "All themes"
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
                "Build your complete listening library",
            subtitle:
                "Unlimited projects, every voice, per-chapter narration, advanced offline generation, and premium themes.",
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
