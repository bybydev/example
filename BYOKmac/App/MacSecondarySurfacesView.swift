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
        MacSheetCloseButton(accessibilityLabel: "Close MCP Servers") {
          dismiss()
        }
      }
      .padding(.horizontal, 16)
      .frame(height: 52)
      .background(MacDesignTokens.Colors.surface)

      Divider()

      MacMCPServerManagementView(mcp: mcp)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(
      minWidth: MacDesignTokens.Sheet.workspaceMinWidth,
      idealWidth: MacDesignTokens.Sheet.workspaceIdealWidth,
      minHeight: MacDesignTokens.Sheet.workspaceMinHeight,
      idealHeight: MacDesignTokens.Sheet.workspaceIdealHeight
    )
    .background(MacDesignTokens.Colors.canvas)
    .environment(\.macToastCenter, toastCenter)
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
      .id(model.runtimeGeneration)
      .overlay(alignment: .topTrailing) {
        MacRootToastOverlayHost(
          workspace: workspace,
          mcp: mcp,
          utilitySheets: utilitySheets,
          toastCenter: toastCenter
        )
      }
      .background {
        MacUtilitySheetPresenterHost(
          model: model,
          workspace: workspace,
          mcp: mcp,
          chats: chats,
          utilitySheets: utilitySheets,
          toastCenter: toastCenter
        )
      }
  }
}

private struct MacRootToastOverlayHost: View {
  let workspace: MacWorkspaceModel
  let mcp: MacMCPModel
  let utilitySheets: MacUtilitySheetCoordinator
  let toastCenter: MacToastCenter

  var body: some View {
    Group {
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
  }
}

private struct MacUtilitySheetPresenterHost: View {
  let model: MacAppModel
  let workspace: MacWorkspaceModel
  let mcp: MacMCPModel
  let chats: MacChatSessionModel
  let utilitySheets: MacUtilitySheetCoordinator
  let toastCenter: MacToastCenter

  var body: some View {
    Color.clear
      .allowsHitTesting(false)
      .accessibilityHidden(true)
      .sheet(
        item: Binding(
          get: { utilitySheets.destination },
          set: { next in
            utilitySheets.destination = next
            if next != .analytics {
              utilitySheets.analyticsInitialConversationID = nil
            }
            if next != .projects {
              utilitySheets.projectsInitialProjectID = nil
            }
          }
        ),
        onDismiss: {
          utilitySheets.analyticsInitialConversationID = nil
          utilitySheets.projectsInitialProjectID = nil
          model.chats?.refreshNewChatTargetAfterProviderChanges()
        }
      ) { destination in
        MacUtilitySheetContainer(destination: destination) {
          utilityContent(destination)
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
    _ destination: MacUtilitySheetDestination
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
        },
        openSourceProject: { projectID in
          utilitySheets.presentProject(projectID)
        }
      )

    case .projects:
      if let providers = model.providers {
        MacProjectsWorkspaceView(
          workspace: workspace,
          providers: providers,
          chats: chats,
          mcp: mcp,
          initialProjectID: utilitySheets.projectsInitialProjectID,
          openChat: { conversationID in
            MacLibraryNavigation.openConversation(conversationID)
            utilitySheets.dismiss()
          },
          startNewChat: { projectID, prompt in
            guard model.requestNewChat(projectID: projectID, initialDraft: prompt) else {
              return false
            }
            utilitySheets.dismiss()
            return true
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

    case .allChats:
      if let providers = model.providers {
        MacAllChatsView(
          providers: providers,
          chats: chats,
          workspace: workspace,
          mcp: mcp,
          openChat: { conversationID, messageID in
            MacLibraryNavigation.openConversation(
              conversationID,
              messageID: messageID
            )
            utilitySheets.dismiss()
          },
          startNewChat: {
            model.requestNewChat()
            utilitySheets.dismiss()
          }
        )
      } else {
        unavailable("All Chats", systemImage: "bubble.left.and.bubble.right")
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
