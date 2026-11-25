import BYOKchatProviderCore
import SwiftUI

@MainActor
@Observable
final class MacUtilitySheetCoordinator {
  var destination: MacUtilitySheetDestination?
  var analyticsInitialConversationID: ConversationID?

  func present(_ destination: MacUtilitySheetDestination) {
    if destination == .analytics {
      analyticsInitialConversationID = nil
    }
    trackOpeningIfNeeded(destination)
    self.destination = destination
  }

  func presentAnalytics(conversationID: ConversationID? = nil) {
    analyticsInitialConversationID = conversationID
    trackOpeningIfNeeded(.analytics)
    destination = .analytics
  }

  func dismiss() {
    destination = nil
    analyticsInitialConversationID = nil
  }

  private func trackOpeningIfNeeded(_ destination: MacUtilitySheetDestination) {
    guard self.destination != destination else { return }
    let dimension: MacAppAnalytics.Dimension
    switch destination {
    case .providers: dimension = .providers
    case .library: dimension = .library
    case .projects: dimension = .projects
    case .mcpServers: dimension = .mcp
    case .analytics: dimension = .analytics
    case .allChats: return
    }
    MacAppAnalytics.track(.featureOpened, dimension: dimension)
  }
}

enum MacUtilitySheetDestination: String, Identifiable {
  case providers
  case library
  case projects
  case mcpServers
  case analytics
  case allChats

  var id: String { rawValue }

  var title: String {
    switch self {
    case .providers: "AI Providers"
    case .library: "Library"
    case .projects: "Projects"
    case .mcpServers: "MCP Servers"
    case .analytics: "Analytics"
    case .allChats: "All Chats"
    }
  }

  var systemImage: String {
    switch self {
    case .providers: "sparkles"
    case .library: "books.vertical"
    case .projects: "folder"
    case .mcpServers: "shippingbox"
    case .analytics: "chart.bar.xaxis"
    case .allChats: "bubble.left.and.bubble.right"
    }
  }

  var footerMessage: String {
    switch self {
    case .providers: "Provider accounts and model availability are managed here."
    case .library: "Library files can be reused across chats and projects."
    case .projects: "Projects group chats, source files, instructions, and tool defaults."
    case .mcpServers: "Server connections are managed here; tool permissions stay with chats and projects."
    case .analytics: "Analytics stays local to the app unless a configured service reports usage."
    case .allChats: "Browse, search, pin, organize, and manage every conversation."
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
  @Environment(\.macToastCenter) private var toastCenter

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
        MacSheetCloseButton(accessibilityLabel: "Close \(destination.title)") {
          dismiss()
        }
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
            .buttonStyle(MacActionButtonStyle(.secondary))
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
        .background(MacDesignTokens.Colors.surface)
      }
    }
    .frame(minWidth: 920, idealWidth: 980, minHeight: 620, idealHeight: 680)
    .background(MacDesignTokens.Colors.canvas)
    .overlay(alignment: .top) {
      if let toastCenter {
        MacToastOverlay(center: toastCenter)
      }
    }
  }
}

struct MacSidebarUtilityGrid: View {
  @Environment(MacUtilitySheetCoordinator.self) private var utilitySheets
  @Environment(\.openSettings) private var openSettings

  private static let spacing: CGFloat = 6
  private static let columns = [
    GridItem(.flexible(), spacing: spacing),
    GridItem(.flexible(), spacing: spacing),
  ]

  var body: some View {
    LazyVGrid(columns: Self.columns, spacing: Self.spacing) {
      utilityTile(.providers)
      utilityTile(.library)
      utilityTile(.projects)
      utilityTile(.mcpServers)
      utilityTile(.analytics)
      settingsTile
    }
    .padding(Self.spacing)
  }

  private func utilityTile(_ destination: MacUtilitySheetDestination) -> some View {
    Button {
      utilitySheets.present(destination)
    } label: {
      tileLabel(title: destination.title, systemImage: destination.systemImage)
    }
    .buttonStyle(MacCardButtonStyle(cornerRadius: 8))
  }

  private var settingsTile: some View {
    Button {
      openSettings()
    } label: {
      tileLabel(title: "Settings", systemImage: "gearshape")
    }
    .buttonStyle(MacCardButtonStyle(cornerRadius: 8))
  }

  private func tileLabel(title: String, systemImage: String) -> some View {
    HStack(spacing: 6) {
      Image(systemName: systemImage)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(MacDesignTokens.Colors.accent)
        .frame(width: 14)

      Text(title)
        .font(.caption.weight(.medium))
        .foregroundStyle(MacDesignTokens.Colors.textPrimary)
        .lineLimit(1)
        .minimumScaleFactor(0.9)

      Spacer(minLength: 0)
    }
    .padding(.horizontal, 8)
    .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
  }
}
