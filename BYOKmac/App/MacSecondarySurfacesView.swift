import BYOKchatProviderCore
import Foundation
import SwiftUI

extension Notification.Name {
  static let macOpenConversationFromLibrary = Notification.Name(
    "com.hoangbkit.byokchat.mac.openConversationFromLibrary"
  )
  static let macScrollToConversationMessage = Notification.Name(
    "com.hoangbkit.byokchat.mac.scrollToConversationMessage"
  )
}

struct MacConversationNavigationRequest: Equatable, Sendable {
  let conversationID: ConversationID
  let messageID: ChatMessageID
}

enum MacLibraryNavigation {
  static func openConversation(
    _ conversationID: ConversationID,
    messageID: ChatMessageID? = nil
  ) {
    // Keep the original String payload so the existing shell and Project
    // navigation path remain unchanged.
    NotificationCenter.default.post(
      name: .macOpenConversationFromLibrary,
      object: conversationID.rawValue
    )

    guard let messageID else { return }
    let request = MacConversationNavigationRequest(
      conversationID: conversationID,
      messageID: messageID
    )
    Task { @MainActor in
      // Let the shell receive the conversation selection first. It retains
      // this precise destination across background preparation, even before
      // the target transcript exists.
      await Task.yield()
      await Task.yield()
      NotificationCenter.default.post(
        name: .macScrollToConversationMessage,
        object: request
      )
    }
  }
}

/// Compatibility entry point used by Settings. Server management itself lives in
/// `MacMCPServerManagementView` so every route presents the same hierarchy.
struct MacMCPServerListView: View {
  @Bindable var mcp: MacMCPModel

  @Environment(\.dismiss) private var dismiss
  @State private var toastCenter = MacToastCenter()

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Image(systemName: "shippingbox")
          .foregroundStyle(MacDesignTokens.Colors.accent)
        Text("MCP Servers")
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
        .accessibilityLabel("Close MCP Servers")
      }
      .padding(.horizontal, 16)
      .frame(height: 52)
      .background(MacDesignTokens.Colors.surface)

      Divider()

      MacMCPServerManagementView(mcp: mcp)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(minWidth: 920, idealWidth: 980, minHeight: 620, idealHeight: 680)
    .background(MacDesignTokens.Colors.canvas)
    .macToastOverlay(toastCenter)
    .onChange(of: mcp.statusMessage) { _, message in
      guard let message else { return }
      toastCenter.showStatus(message)
      mcp.statusMessage = nil
    }
  }
}

struct MacSecondarySurfacesView: View {
  let model: MacAppModel

  @State private var utilitySheets = MacUtilitySheetCoordinator()
  @State private var toastCenter = MacToastCenter()

  var body: some View {
    if let workspace = model.workspace, let mcp = model.mcp, let chats = model.chats {
      content(workspace: workspace, mcp: mcp, chats: chats)
        .environment(workspace)
        .environment(mcp)
        .environment(chats)
        .environment(utilitySheets)
        .environment(\.macToastCenter, toastCenter)
    } else {
      ContentUnavailableView(
        "Workspace Unavailable",
        systemImage: "externaldrive.badge.exclamationmark",
        description: Text("Restart BYOKchat to reload Projects, Library, and Tools.")
      )
    }
  }

  private func content(
    workspace: MacWorkspaceModel,
    mcp: MacMCPModel,
    chats: MacChatSessionModel
  ) -> some View {
    MacShellView(model: model)
      .overlay(alignment: .top) {
        if utilitySheets.destination == nil {
          MacToastOverlay(center: toastCenter)
        }
      }
      .onChange(of: workspace.statusMessage) { _, message in
        guard let message else { return }
        toastCenter.showStatus(message)
        workspace.statusMessage = nil
      }
      .onChange(of: mcp.statusMessage) { _, message in
        guard let message else { return }
        toastCenter.showStatus(message)
        mcp.statusMessage = nil
      }
      .sheet(
        item: Binding(
          get: { utilitySheets.destination },
          set: { next in
            utilitySheets.destination = next
            if next != .analytics {
              utilitySheets.analyticsInitialConversationID = nil
            }
          }
        ),
        onDismiss: {
          utilitySheets.analyticsInitialConversationID = nil
          model.chats?.refreshNewChatTargetAfterProviderChanges()
        }
      ) { destination in
        MacUtilitySheetContainer(destination: destination) {
          utilityContent(destination, workspace: workspace, mcp: mcp, chats: chats)
        }
        .environment(workspace)
        .environment(mcp)
        .environment(chats)
        .environment(utilitySheets)
        .environment(\.macToastCenter, toastCenter)
      }
  }

  @ViewBuilder
  private func utilityContent(
    _ destination: MacUtilitySheetDestination,
    workspace: MacWorkspaceModel,
    mcp: MacMCPModel,
    chats: MacChatSessionModel
  ) -> some View {
    switch destination {
    case .providers:
      if let providers = model.providers {
        MacProviderManagementView(model: providers, showsCloseButton: false)
      } else {
        unavailable("AI Providers", systemImage: "sparkles")
      }

    case .library:
      MacLibraryView(
        workspace: workspace,
        chats: chats,
        openSourceChat: { conversationID, messageID in
          MacLibraryNavigation.openConversation(
            conversationID,
            messageID: messageID
          )
          utilitySheets.dismiss()
        }
      )

    case .projects:
      if let providers = model.providers {
        MacProjectsWorkspaceView(
          workspace: workspace,
          providers: providers,
          chats: chats,
          mcp: mcp,
          openChat: { conversationID in
            MacLibraryNavigation.openConversation(conversationID)
            utilitySheets.dismiss()
          },
          startNewChat: { projectID, prompt in
            model.requestNewChat(projectID: projectID, initialDraft: prompt)
            utilitySheets.dismiss()
          }
        )
      } else {
        unavailable("Projects", systemImage: "folder")
      }

    case .mcpServers:
      MacMCPServerManagementView(mcp: mcp)

    case .analytics:
      if let services = model.coreServices {
        MacAnalyticsGateView(
          services: services,
          initialConversationID: utilitySheets.analyticsInitialConversationID
        )
      } else {
        unavailable("Analytics", systemImage: "chart.bar.xaxis")
      }
    }
  }

  private func unavailable(_ title: String, systemImage: String) -> some View {
    ContentUnavailableView(
      "\(title) Unavailable",
      systemImage: systemImage,
      description: Text("Restart BYOKchat to reload this workspace surface.")
    )
  }
}
