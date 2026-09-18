import MacAppFoundation
import SwiftUI

@MainActor
struct InkribeRootView: View {
    let appState: InkribeAppState
    @Bindable var shellState: InkribeShellState
    let purchaseManager: PurchaseManager
    let settingsRouter: MacAppSettingsRouter

    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        InkribeShellView(
            appState: appState,
            state: shellState,
            purchaseManager: purchaseManager,
            onOpenSettings: openSettingsWindow,
            onOpenPlan: openPlan,
            onOpenPaywall: openPaywall
        )
    }

    private func openSettingsWindow() {
        openSettings()
    }

    private func openPlan() {
        settingsRouter.request(.plan)
        openSettings()
    }

    private func openPaywall() {
        openWindow(id: InkribeWindowID.proPaywall)
    }
}
