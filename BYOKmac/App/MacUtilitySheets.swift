import Observation
import SwiftUI

enum MacUtilitySheetDestination: String, CaseIterable, Identifiable {
  case providers
  case library
  case projects
  case mcpServers
  case analytics

  var id: String { rawValue }

  var title: String {
    switch self {
    case .providers: "AI Providers"
    case .library: "Library"
    case .projects: "Projects"
    case .mcpServers: "MCP Servers"
    case .analytics: "Analytics"
    }
  }

  var symbol: String {
    switch self {
    case .providers: "sparkles"
    case .library: "books.vertical"
    case .projects: "folder"
    case .mcpServers: "puzzlepiece.extension"
    case .analytics: "chart.bar.xaxis"
    }
  }

  var footerMessage: String {
    switch self {
    case .providers:
      "Manage provider connections, credentials, models, and defaults."
    case .library:
      "Library files can be reused across chats and projects."
    case .projects:
      "Projects group chats, instructions, files, prompts, and tool defaults."
    case .mcpServers:
      "MCP servers provide tools that chats and projects can enable."
    case .analytics:
      "Analytics summarize local chat activity and usage."
    }
  }
}

@MainActor
@Observable
final class MacUtilitySheetCoordinator {
  var destination: MacUtilitySheetDestination?

  func present(_ destination: MacUtilitySheetDestination) {
    self.destination = destination
  }

  func dismiss() {
    destination = nil
  }
}

struct MacUtilitySheetFooterAction: Identifiable {
  let id: String
  let title: String
  var role: ButtonRole? = nil
  let action: () -> Void

  init(
    id: String? = nil,
    title: String,
    role: ButtonRole? = nil,
    action: @escaping () -> Void
  ) {
    self.id = id ?? title
    self.title = title
    self.role = role
    self.action = action
  }
}

struct MacUtilitySheetContainer<Content: View>: View {
  let destination: MacUtilitySheetDestination
  let footerActions: [MacUtilitySheetFooterAction]
  @ViewBuilder let content: () -> Content

  @Environment(\.dismiss) private var dismiss

  init(
    destination: MacUtilitySheetDestination,
    footerActions: [MacUtilitySheetFooterAction] = [],
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.destination = destination
    self.footerActions = footerActions
    self.content = content
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()

      content()
        .frame(maxWidth: .infinity, maxHeight: .infinity)

      Divider()
      footer
    }
    .frame(minWidth: 920, idealWidth: 980, minHeight: 620, idealHeight: 680)
    .background(MacDesignTokens.Colors.canvas)
  }

  private var header: some View {
    HStack(spacing: 10) {
      Image(systemName: destination.symbol)
        .font(.system(size: 16, weight: .semibold))
        .foregroundStyle(MacDesignTokens.Colors.accent)
        .frame(width: 24)

      Text(destination.title)
        .font(.title3.weight(.semibold))

      Spacer()

      Button {
        dismiss()
      } label: {
        Image(systemName: "xmark")
          .font(.system(size: 11, weight: .semibold))
          .frame(width: 28, height: 28)
          .background(Color.primary.opacity(0.06), in: Circle())
      }
      .buttonStyle(.plain)
      .help("Close")
      .accessibilityLabel("Close \(destination.title)")
    }
    .padding(.horizontal, 18)
    .frame(height: 52)
  }

  private var footer: some View {
    HStack(alignment: .center, spacing: 16) {
      Text(destination.footerMessage)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(2)

      Spacer(minLength: 24)

      HStack(spacing: 8) {
        ForEach(footerActions) { action in
          Button(action.title, role: action.role, action: action.action)
        }

        Button("Close") {
          dismiss()
        }
        .keyboardShortcut(.cancelAction)
      }
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 10)
    .frame(minHeight: 54)
  }
}

struct MacSidebarUtilityGrid: View {
  @Environment(MacUtilitySheetCoordinator.self) private var coordinator

  private let columns = [
    GridItem(.flexible(), spacing: 8),
    GridItem(.flexible(), spacing: 8),
  ]

  var body: some View {
    LazyVGrid(columns: columns, spacing: 8) {
      ForEach(MacUtilitySheetDestination.allCases) { destination in
        Button {
          coordinator.present(destination)
        } label: {
          tile(title: destination.title, symbol: destination.symbol)
        }
        .buttonStyle(.plain)
        .help(destination.title)
      }

      SettingsLink {
        tile(title: "Settings", symbol: "gearshape")
      }
      .buttonStyle(.plain)
      .help("Settings")
    }
    .padding(10)
  }

  private func tile(title: String, symbol: String) -> some View {
    VStack(spacing: 5) {
      Image(systemName: symbol)
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(.secondary)
        .frame(height: 18)

      Text(title)
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(.primary)
        .lineLimit(1)
        .minimumScaleFactor(0.78)
    }
    .frame(maxWidth: .infinity, minHeight: 54)
    .background(
      Color.primary.opacity(0.045),
      in: RoundedRectangle(cornerRadius: 9, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 9, style: .continuous)
        .stroke(Color.primary.opacity(0.07), lineWidth: 0.5)
    }
    .contentShape(Rectangle())
  }
}
