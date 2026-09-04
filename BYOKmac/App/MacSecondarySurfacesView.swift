import SwiftUI

struct MacSecondarySurfacesView: View {
  let model: MacAppModel

  @State private var showingProjects = false
  @State private var showingLibrary = false
  @State private var showingAnalytics = false
  @State private var showingMCPServers = false

  var body: some View {
    if let workspace = model.workspace, let mcp = model.mcp {
      content(workspace: workspace, mcp: mcp)
        .environment(workspace)
        .environment(mcp)
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
      .toolbar {
        ToolbarItem(placement: .automatic) {
          Menu {
            Button("Projects", systemImage: "folder") { showingProjects = true }
            Button("Library", systemImage: "books.vertical") { showingLibrary = true }
            Button("Analytics", systemImage: "chart.xyaxis.line") { showingAnalytics = true }
            Button("MCP Servers", systemImage: "wrench.and.screwdriver") { showingMCPServers = true }
            Divider()
            SettingsLink {
              Label("Settings…", systemImage: "gearshape")
            }
          } label: {
            Image(systemName: "square.grid.2x2")
          }
          .help("Projects, Library, Analytics, Tools, and Settings")
        }
      }
      .sheet(isPresented: $showingProjects) {
        if let providers = model.providers, let chats = model.chats {
          MacProjectsView(
            workspace: workspace,
            providers: providers,
            chats: chats,
            mcp: mcp
          ) { projectID, prompt in
            model.requestNewChat(projectID: projectID, initialDraft: prompt)
            showingProjects = false
          }
          .preferredColorScheme(model.theme.preferredColorScheme)
          .tint(MacDesignTokens.Colors.accent)
          .environment(\.macThemeRevision, model.theme.revision)
          .environment(workspace)
          .environment(mcp)
        }
      }
      .sheet(isPresented: $showingLibrary) {
        MacLibraryView(workspace: workspace)
          .preferredColorScheme(model.theme.preferredColorScheme)
          .tint(MacDesignTokens.Colors.accent)
          .environment(\.macThemeRevision, model.theme.revision)
          .environment(workspace)
          .environment(mcp)
      }
      .sheet(isPresented: $showingAnalytics) {
        if let services = model.coreServices {
          MacAnalyticsView(services: services)
            .preferredColorScheme(model.theme.preferredColorScheme)
            .tint(MacDesignTokens.Colors.accent)
            .environment(\.macThemeRevision, model.theme.revision)
        }
      }
      .sheet(isPresented: $showingMCPServers) {
        MacMCPServerListView(mcp: mcp)
          .preferredColorScheme(model.theme.preferredColorScheme)
          .tint(MacDesignTokens.Colors.accent)
          .environment(\.macThemeRevision, model.theme.revision)
      }
  }
}
