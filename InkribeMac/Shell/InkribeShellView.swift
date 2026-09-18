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
        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                InkribeSidebarColumn(
                    state: state,
                    onOpenSettings: onOpenSettings
                )
                .frame(width: state.sidebarWidth)
                .clipped()

                Rectangle()
                    .fill(theme.separator)
                    .frame(width: InkribeShellMetrics.dividerWidth)
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

            sidebarToggle
                .offset(
                    x: state.sidebarToggleCenterX - (InkribeShellMetrics.toggleDiameter / 2),
                    y: (InkribeShellMetrics.titlebarHeight - InkribeShellMetrics.toggleDiameter) / 2
                )
                .zIndex(10)
        }
        .frame(
            minWidth: InkribeShellMetrics.minimumWindowWidth,
            minHeight: InkribeShellMetrics.minimumWindowHeight
        )
        .background(theme.canvas)
        .macAppFullSizeWindowChrome()
        .animation(shellAnimation, value: state.isSidebarExpanded)
    }

    private var sidebarToggle: some View {
        Button {
            if reduceMotion {
                state.toggleSidebar()
            } else {
                withAnimation(shellAnimation) {
                    state.toggleSidebar()
                }
            }
        } label: {
            Image(systemName: state.isSidebarExpanded ? "sidebar.left" : "sidebar.right")
                .font(.system(size: 12, weight: .semibold))
                .frame(
                    width: InkribeShellMetrics.toggleDiameter,
                    height: InkribeShellMetrics.toggleDiameter
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.textSecondary)
        .background(theme.surfaceRaised, in: Circle())
        .overlay {
            Circle()
                .stroke(theme.border, lineWidth: 0.75)
        }
        .contentShape(Circle())
        .help(state.isSidebarExpanded ? "Hide Sidebar" : "Show Sidebar")
        .accessibilityLabel(state.isSidebarExpanded ? "Hide sidebar" : "Show sidebar")
        .accessibilityIdentifier("Inkribe.Sidebar.Toggle")
    }

    private var shellAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: InkribeShellMetrics.sidebarAnimationDuration)
    }
}
