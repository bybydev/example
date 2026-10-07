import AppFoundation
import SwiftUI

@main
@MainActor
struct ReadAloudApp: App {
    @State private var purchaseManager: PurchaseManager
    @State private var themeManager: ThemeManager

    init() {
        _purchaseManager = State(
            initialValue: PurchaseManager(
                configuration: ReadAloudCommerce.purchaseConfiguration,
                simulated: false,
                simulatedProducts: [],
                simulatedPersistenceKey: "com.hoangbkit.readaloud.simulated-purchases"
            )
        )
        _themeManager = State(
            initialValue: ThemeManager(
                catalog: ReadAloudThemeCatalog.catalog,
                stateStore: UserDefaultsThemeStateStore(
                    storageKey: "com.hoangbkit.readaloud.theme-state"
                )
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(purchaseManager)
                .environment(themeManager)
                .managesPurchases(purchaseManager)
                .appFoundationTheme(
                    themeManager,
                    purchaseManager: purchaseManager
                )
        }
    }
}
