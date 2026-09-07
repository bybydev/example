import SwiftUI

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

enum MacUtilitySheetDestination: String, Identifiable {
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

  var systemImage: String {
    switch self {
    case .providers: "sparkles"
    case .library: "books.vertical"
    case .projects: "folder"
    case .mcpServers: "shippingbox"
    case .analytics: "chart.bar.xaxis"
    }
  }

  var footerMessage: String {
    switch self {
    case .providers: "Provider accounts and model availability are managed here."
    case .library: "Library files can be reused across chats and projects."
    case .projects: "Projects group chats, source files, instructions, and tool defaults."
    case .mcpServers: "Server connections are managed here; tool permissions stay with chats and projects."
    case .analytics: "Analytics stays local to the app unless a configured service reports usage."
    }
  }

  var showsFooter: Bool {
    false
  }
}

struct MacUtilitySheetContainer<Content: View>: View {
  let destination: MacUtilitySheetDestination
  @ViewBuilder let content: Content

  @Environment(\.dismiss) private var dismiss

  init(
    destination: MacUtilitySheetDestination,
    @ViewBuilder content: () -> Content
  ) {
    self.destination = destination
    self.content = content()
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Image(systemName: destination.systemImage)
          .foregroundStyle(MacDesignTokens.Colors.accent)
        Text(destination.title)
          .font(.headline)
        Spacer()
        Button {
          dismiss()
        } label: {
          Image(systemName: "xmark")
            .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .help("Close")
      }
      .padding(.horizontal, 16)
      .frame(height: 52)
      .background(MacDesignTokens.Colors.surface)

      Divider()

      content
        .frame(maxWidth: .infinity, maxHeight: .infinity)

      if destination.showsFooter {
        Divider()

        HStack(spacing: 12) {
          Text(destination.footerMessage)
            .font(.caption)
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
          Spacer()
          Button("Close") { dismiss() }
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
        .background(MacDesignTokens.Colors.surface)
      }
    }
    .frame(minWidth: 920, idealWidth: 980, minHeight: 620, idealHeight: 680)
    .background(MacDesignTokens.Colors.canvas)
  }
}

struct MacSidebarUtilityGrid: View {
  @Environment(MacUtilitySheetCoordinator.self) private var utilitySheets

  var body: some View {
    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
      utilityTile(.providers)
      utilityTile(.library)
      utilityTile(.projects)
      utilityTile(.mcpServers)
      utilityTile(.analytics)
    }
  }

  private func utilityTile(_ destination: MacUtilitySheetDestination) -> some View {
    Button {
      utilitySheets.present(destination)
    } label: {
      VStack(alignment: .leading, spacing: 6) {
        Image(systemName: destination.systemImage)
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(MacDesignTokens.Colors.accent)
        Text(destination.title)
          .font(.caption.weight(.medium))
          .foregroundStyle(MacDesignTokens.Colors.textPrimary)
      }
      .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
      .padding(.horizontal, 10)
      .background(MacDesignTokens.Colors.surface, in: RoundedRectangle(cornerRadius: 8))
      .overlay {
        RoundedRectangle(cornerRadius: 8)
          .stroke(MacDesignTokens.Colors.separator.opacity(0.7), lineWidth: 0.5)
      }
    }
    .buttonStyle(.plain)
  }
}
