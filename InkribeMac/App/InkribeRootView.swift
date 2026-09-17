import MacAppFoundation
import SwiftUI

@MainActor
struct InkribeRootView: View {
    let appState: InkribeAppState
    @Bindable var shellState: InkribeShellState
    let purchaseManager: PurchaseManager
    let settingsRouter: MacAppSettingsRouter

    @Environment(\.openSettings) private var openSettings

    var body: some View {
        InkribeShellView(
            appState: appState,
            state: shellState,
            purchaseManager: purchaseManager,
            onOpenSettings: openSettingsWindow,
            onOpenPlan: openPlan
        )
    }

    private func openSettingsWindow() {
        openSettings()
    }

    private func openPlan() {
        settingsRouter.request(.plan)
        openSettings()
    }
}
