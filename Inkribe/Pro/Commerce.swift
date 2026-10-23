import AppFoundation
import Foundation

enum Commerce {
    static let monthlyID = "com.hoangbkit.inkribe.pro.monthly"
    static let lifetimeID = "com.hoangbkit.inkribe.pro.lifetime"
    static let weeklySeconds = 300
    static let configuration = PurchaseConfiguration(productIDs: [monthlyID, lifetimeID],
        preferredProductID: monthlyID, features: features)
    static let simulatedProducts: [StoreProduct] = [
        .init(id: monthlyID, displayName: "Monthly", description: "Inkribe Pro billed monthly.",
              displayPrice: "$6.99", price: 6.99, subscriptionPeriod: .init(value: 1, unit: .month)),
        .init(id: lifetimeID, displayName: "Lifetime", description: "One purchase for lifetime Inkribe Pro access.",
              displayPrice: "$24.99", price: 24.99)
    ]
    static let features: [PurchaseFeature] = [
        .init(id: "captioning", systemImage: "waveform", title: "Unlimited Captioning",
              message: "Transcribe your videos without weekly limits.", freeValue: "5 min/week", proValue: "Unlimited"),
        .init(id: "styles", systemImage: "textformat", title: "All Styles & Animations",
              message: "Unlock every caption font, template and animation.", freeValue: "Basic", proValue: "All"),
        .init(id: "fullHD", systemImage: "film", title: "Full HD Exports",
              message: "Save your captioned videos in 1080p.", freeValue: "720p", proValue: "1080p"),
        .init(id: "themes", systemImage: "paintpalette.fill", title: "All Premium Themes",
              message: "Make Inkribe yours with every app theme.", freeValue: "Default", proValue: "All")
    ]
    @MainActor static var comparison: [LimitReachedComparisonRow] {
        features.map { LimitReachedComparisonRow($0) }
    }
    // Development placeholder requested by the user; replace before publishing.
    static let privacyURL = URL(string: "https://example.com/inkribe/privacy")!
    static let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    static let supportURL = URL(string: "mailto:hi@spokio.pro")!

    @MainActor static let paywall = FoundationPaywallConfiguration(badge: "INKRIBE PRO",
        title: "Make every video yours",
        subtitle: "Unlimited captioning, all styles and animations, Full HD exports and premium app themes.",
        purchaseButtonTitle: "Continue",
        highlightedProductID: lifetimeID,
        privacyURL: privacyURL, termsURL: termsURL)

    static let celebration = FoundationProCelebrationConfiguration(
        navigationTitle: "Inkribe Pro",
        message: "Thanks for supporting Inkribe and unlocking the complete caption creation experience."
    )

    @MainActor static func makePurchases() -> PurchaseManager {
        PurchaseManager(configuration: configuration,
            simulated: PurchaseServiceMode.fromEnvironment() == .simulated,
            simulatedProducts: simulatedProducts,
            simulatedPersistenceKey: "com.hoangbkit.inkribe.ios.simulated-purchases")
    }
}

enum ProFeature: String, Identifiable, Sendable {
    case captioning, styles, fullHD, themes
    var id: String { rawValue }
    var title: String {
        switch self {
        case .captioning: "Unlimited Captioning"
        case .styles: "All Styles & Animations"
        case .fullHD: "Full HD Exports"
        case .themes: "All Premium Themes"
        }
    }
}

enum ProError: LocalizedError {
    case requiresPro(ProFeature)
    case allowanceStorage, authorizationUnavailable
    var errorDescription: String? {
        switch self {
        case .requiresPro(let feature): "\(feature.title) requires Inkribe Pro."
        case .allowanceStorage: "Caption allowance storage could not be read or saved. Your projects are preserved. Retry after checking device storage."
        case .authorizationUnavailable: "This transcription's saved allowance authorization is unavailable. Retry the transcription."
        }
    }
}
