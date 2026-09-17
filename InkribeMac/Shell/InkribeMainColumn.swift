import MacAppFoundation
import SwiftUI

@MainActor
struct InkribeMainColumn: View {
    let appState: InkribeAppState
    @Bindable var state: InkribeShellState
    let purchaseManager: PurchaseManager
    let onOpenPlan: () -> Void

    @Environment(\.macAppTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            titlebar

            InkribeShellContentView(
                appState: appState,
                state: state
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            statusBar
        }
        .background(theme.canvas)
        .accessibilityIdentifier("Inkribe.MainColumn")
    }

    private var titlebar: some View {
        HStack(spacing: 12) {
            Text(state.route.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)

            Spacer(minLength: 12)

            ProPlanButton(
                purchaseManager: purchaseManager,
                onUpgrade: onOpenPlan,
                onManagePlan: onOpenPlan
            )
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .frame(height: InkribeShellMetrics.titlebarHeight)
        .background {
            MacAppWindowDragRegion(
                trafficLightReserve: 0,
                background: theme.canvas
            )
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.separator)
                .frame(height: 1)
        }
        .accessibilityIdentifier("Inkribe.MainTitlebar")
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Label("Local only", systemImage: "lock.fill")
                .labelStyle(.titleAndIcon)

            Spacer(minLength: 12)

            Text(queueStatusText)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(theme.textMuted)
        .padding(.horizontal, 12)
        .frame(height: InkribeShellMetrics.statusBarHeight)
        .background(theme.surface)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(theme.separator)
                .frame(height: 1)
        }
        .accessibilityIdentifier("Inkribe.MainStatusBar")
    }

    private var queueStatusText: String {
        if appState.startupIssue != nil
            || appState.transcriptionQueue?.persistenceIssueDescription != nil {
            return "Needs attention"
        }
        guard let queue = appState.transcriptionQueue else { return "Ready" }
        if queue.isPaused { return "Queue paused" }
        if queue.activeCount > 0 {
            return queue.activeCount == 1
                ? "Transcribing"
                : "Transcribing \(queue.activeCount)"
        }
        return "Ready"
    }
}
