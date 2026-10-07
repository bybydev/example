import AppFoundation
import SwiftUI

@main
@MainActor
struct ReadAloudApp: App {
    @State private var purchaseManager: PurchaseManager
    @State private var themeManager: ThemeManager
    @State private var runtimeManager: ProjectRuntimeManager

    init() {
        _purchaseManager = State(
            initialValue: PurchaseManager(
                configuration: ReadAloudCommerce.purchaseConfiguration,
                simulated: false,
                simulatedProducts: [],
                simulatedPersistenceKey: "com.hoangbkit.readaloud.simulated-purchases"
            )
        )
        _runtimeManager = State(
            initialValue: ProjectRuntimeManager()
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
                .environment(runtimeManager)
                .managesPurchases(purchaseManager)
                .appFoundationTheme(
                    themeManager,
                    purchaseManager: purchaseManager
                )
        }
    }
}
