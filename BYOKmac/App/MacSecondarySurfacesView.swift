import SwiftUI

struct MacSecondarySurfacesView: View {
  let model: MacAppModel

  @State private var utilitySheets = MacUtilitySheetCoordinator()

  var body: some View {
    if let workspace = model.workspace, let mcp = model.mcp {
      content(workspace: workspace, mcp: mcp)
        .environment(workspace)
        .environment(mcp)
        .environment(utilitySheets)
    } else {
      ContentUnavailableView(
        "Workspace Unavailable",
        systemImage: "externaldrive.badge.exclamationmark",
        description: Text("Restart BYOKchat to reload Projects, Library, and Tools.")
      )
    }
  }

  private func content(workspace: MacWorkspaceModel, mcp: MacMCPModel) -> some View {
    MacShellView(model: model)
      .preferredColorScheme(model.theme.preferredColorScheme)
      .tint(MacDesignTokens.Colors.accent)
      .environment(\.macThemeRevision, model.theme.revision)
      .sheet(
        item: Binding(
          get: { utilitySheets.destination },
          set: { utilitySheets.destination = $0 }
        ),
        onDismiss: {
          model.chats?.refreshNewChatTargetAfterProviderChanges()
        }
      ) { destination in
        MacUtilitySheetContainer(destination: destination) {
          utilityContent(destination, workspace: workspace, mcp: mcp)
        }
        .preferredColorScheme(model.theme.preferredColorScheme)
        .tint(MacDesignTokens.Colors.accent)
        .environment(\.macThemeRevision, model.theme.revision)
        .environment(workspace)
        .environment(mcp)
        .environment(utilitySheets)
      }
  }

  @ViewBuilder
  private func utilityContent(
    _ destination: MacUtilitySheetDestination,
    workspace: MacWorkspaceModel,
    mcp: MacMCPModel
  ) -> some View {
    switch destination {
    case .providers:
      if let providers = model.providers {
        MacProviderManagementView(model: providers)
      } else {
        unavailable("AI Providers", systemImage: "sparkles")
      }

    case .library:
      MacLibraryView(workspace: workspace)

    case .projects:
      if let providers = model.providers, let chats = model.chats {
        MacProjectsView(
          workspace: workspace,
          providers: providers,
          chats: chats,
          mcp: mcp
        ) { projectID, prompt in
          model.requestNewChat(projectID: projectID, initialDraft: prompt)
          utilitySheets.dismiss()
        }
      } else {
        unavailable("Projects", systemImage: "folder")
      }

    case .mcpServers:
      MacMCPServerListView(mcp: mcp)

    case .analytics:
      if let services = model.coreServices {
        MacAnalyticsGateView(services: services)
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