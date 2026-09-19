import MacAppFoundation
import SwiftUI

@MainActor
struct InkribeShellView: View {
    let appState: InkribeAppState
    @Bindable var state: InkribeShellState
    let purchaseManager: PurchaseManager
    let onOpenSettings: () -> Void
    let onOpenPlan: () -> Void
    let onOpenPaywall: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.macAppTheme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            InkribeSidebarColumn(
                state: state,
                onOpenSettings: onOpenSettings
            )
            .frame(width: state.sidebarWidth)
            .clipped()

            Rectangle()
                .fill(theme.separator)
                .frame(
                    width: state.isSidebarExpanded
                        ? InkribeShellMetrics.dividerWidth
                        : 0
                )
                .accessibilityHidden(true)

            InkribeMainColumn(
                appState: appState,
                state: state,
                purchaseManager: purchaseManager,
                onOpenPlan: onOpenPlan,
                onOpenPaywall: onOpenPaywall
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(
            minWidth: InkribeShellMetrics.minimumWindowWidth,
            minHeight: InkribeShellMetrics.minimumWindowHeight
        )
        .background(theme.canvas)
        .macAppFullSizeWindowChrome()
        .animation(shellAnimation, value: state.isSidebarExpanded)
    }

    private var shellAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: InkribeShellMetrics.sidebarAnimationDuration)
    }
}
