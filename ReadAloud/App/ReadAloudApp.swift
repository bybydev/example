import AppFoundation
import SwiftUI
import UIKit

@main
@MainActor
struct ReadAloudApp: App {
    @State private var purchaseManager:
        PurchaseManager
    @State private var themeManager:
        ThemeManager
    @State private var runtimeManager:
        ProjectRuntimeManager

    init() {
        let purchases =
            PurchaseManager(
                configuration:
                    ReadAloudCommerce
                        .purchaseConfiguration,
                simulated: false,
                simulatedProducts:
                    ReadAloudCommerce
                        .simulatedProducts,
                simulatedPersistenceKey:
                    "com.hoangbkit.readaloud.simulated-purchases"
            )

        _purchaseManager =
            State(
                initialValue:
                    purchases
            )
        _runtimeManager =
            State(
                initialValue:
                    ProjectRuntimeManager(
                        hasPro: {
                            purchases.hasPro
                        }
                    )
            )
        _themeManager =
            State(
                initialValue:
                    ThemeManager(
                        catalog:
                            ReadAloudThemeCatalog
                                .catalog,
                        stateStore:
                            ReadAloudThemeCatalog
                                .makeStateStore(),
                        previewBehavior:
                            .disabled
                    )
            )
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .readAloudThemeSurface()
                .environment(
                    purchaseManager
                )
                .environment(
                    themeManager
                )
                .environment(
                    runtimeManager
                )
                .managesPurchases(
                    purchaseManager
                )
                .appFoundationTheme(
                    themeManager,
                    purchaseManager:
                        purchaseManager
                )
                .onReceive(NotificationCenter.default.publisher(
                    for: UIApplication.didReceiveMemoryWarningNotification
                )) { _ in
                    runtimeManager.handleMemoryPressure()
                }
                .onChange(
                    of:
                        purchaseManager
                            .hasPro
                ) { _, _ in
                    Task {
                        await runtimeManager
                            .refreshAllLoaded()
                    }
                }
        }
    }
}

