import MacAppFoundation
import SwiftUI

@MainActor
struct InkribeSidebarColumn: View {
    @Bindable var state: InkribeShellState
    let onOpenSettings: () -> Void

    @Environment(\.macAppTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            MacAppWindowDragRegion(background: theme.surface)
                .frame(height: InkribeShellMetrics.titlebarHeight)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(theme.separator)
                        .frame(height: 1)
                }

            ZStack {
                theme.surface

                if state.isSidebarExpanded {
                    expandedSidebar
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityIdentifier("Inkribe.Sidebar")
    }

    private var expandedSidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(spacing: 4) {
                ForEach(InkribeShellDestination.allCases) { destination in
                    navigationButton(destination)
                }
            }

            Spacer(minLength: 12)

            Button(action: onOpenSettings) {
                Label("Settings", systemImage: "gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(InkribeSidebarButtonStyle(isSelected: false))
            .accessibilityIdentifier("Inkribe.Sidebar.Settings")
        }
        .padding(.horizontal, 10)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private func navigationButton(_ destination: InkribeShellDestination) -> some View {
        let isSelected = state.route.sidebarDestination == destination

        return Button {
            state.select(destination)
        } label: {
            Label(destination.title, systemImage: destination.systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(InkribeSidebarButtonStyle(isSelected: isSelected))
        .accessibilityIdentifier("Inkribe.Sidebar.\(destination.rawValue)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct InkribeSidebarButtonStyle: ButtonStyle {
    let isSelected: Bool

    @Environment(\.macAppTheme) private var theme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
            .foregroundStyle(isSelected ? theme.textPrimary : theme.textSecondary)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(background(configuration.isPressed), in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
    }

    private func background(_ isPressed: Bool) -> Color {
        if isPressed {
            return theme.selection.opacity(0.85)
        }
        if isSelected {
            return theme.selection
        }
        return .clear
    }
}
