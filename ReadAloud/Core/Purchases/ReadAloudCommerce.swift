import AppFoundation
import Foundation

enum ReadAloudCommerce {
    static let lifetimeProductID =
        "com.hoangbkit.readaloud.pro.lifetime"
    static let monthlyProductID =
        "com.hoangbkit.readaloud.pro.monthly"

    static let supportURL =
        URL(
            string:
                "https://studio.spokio.pro/riidrr/contact"
        )!
    static let privacyURL =
        URL(
            string:
                "https://studio.spokio.pro/riidrr/privacy"
        )!
    static let termsURL =
        URL(
            string:
                "https://studio.spokio.pro/riidrr/terms"
        )!

    static let features: [PurchaseFeature] = [
        PurchaseFeature(
            id: "listening",
            systemImage: "headphones",
            title: "Listening Time",
            message: "Listen as much as you like across your entire library, without weekly limits",
            freeValue: "\(Int(ReadAloudAccessPolicy.weeklyListeningSeconds / 3600)) hours/week",
            proValue: "Unlimited"
        ),
        PurchaseFeature(
            id: "offlineGeneration",
            systemImage: "arrow.down.circle.fill",
            title: "Prepare Audio Ahead",
            message: "Generate complete chapters or entire books ahead of time for offline listening",
            freeValue: "Live listening",
            proValue: "Chapters & books"
        ),
        PurchaseFeature(
            id: "voices",
            systemImage: "waveform.circle.fill",
            title: "All Voices",
            message: "Unlock every built-in voice and choose the perfect narrator for each book",
            freeValue: SpeechVoice.heart.name,
            proValue: "All 28 voices"
        ),
        PurchaseFeature(
            id: "themes",
            systemImage: "paintpalette.fill",
            title: "Premium Themes",
            message: "Make the app feel like yours with full access to every premium theme",
            freeValue: "ReadAloud Light + Dark",
            proValue: "All themes"
        ),
    ]

    static let purchaseConfiguration =
        PurchaseConfiguration(
            productIDs: [
                lifetimeProductID,
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
                displayPrice: "$29.99",
                price: 29.99
            ),
            PurchaseProduct(
                id: monthlyProductID,
                displayName: "Monthly",
                description:
                    "ReadAloud Pro billed monthly.",
                displayPrice: "$6.99",
                price: 6.99,
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
                "Unlock unlimited listening, audio preparation, all 28 English voices, and premium app themes. Reading, imports, and queue controls stay free.",
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


