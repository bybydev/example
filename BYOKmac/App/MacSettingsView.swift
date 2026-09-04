import SwiftUI

struct MacSettingsView: View {
  let model: MacAppModel

  var body: some View {
    TabView {
      MacGeneralSettingsView(preferences: model.preferences)
        .tabItem { Label("General", systemImage: "gearshape") }

      MacAppearanceSettingsView(theme: model.theme)
        .tabItem { Label("Appearance", systemImage: "paintpalette") }

      MacConnectionSettingsView(model: model)
        .tabItem { Label("Connections", systemImage: "bolt.horizontal.circle") }

      MacToolsSettingsView(model: model)
        .tabItem { Label("Tools", systemImage: "wrench.and.screwdriver") }

      MacDataSettingsView(model: model)
        .tabItem { Label("Data", systemImage: "externaldrive") }

      MacDiagnosticsSettingsView(model: model)
        .tabItem { Label("Diagnostics", systemImage: "waveform.path.ecg") }
    }
    .frame(width: 760, height: 620)
    .preferredColorScheme(model.theme.preferredColorScheme)
    .tint(MacDesignTokens.Colors.accent)
    .environment(\.macThemeRevision, model.theme.revision)
  }
}

private struct MacGeneralSettingsView: View {
  @Bindable var preferences: MacPreferencesModel

  var body: some View {
    Form {
      Section("Chat") {
        LabeledContent("Keyboard") {
          Text("Return sends · Shift-Return inserts a line")
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
        }
      }

      Section("Default System Prompt") {
        TextEditor(text: $preferences.defaultSystemPrompt)
          .font(.system(size: 13))
          .frame(minHeight: 170)
          .padding(6)
          .background(
            MacDesignTokens.Colors.surface,
            in: RoundedRectangle(cornerRadius: MacDesignTokens.Radius.medium)
          )
          .overlay {
            RoundedRectangle(cornerRadius: MacDesignTokens.Radius.medium)
              .stroke(MacDesignTokens.Colors.separator.opacity(0.8), lineWidth: 1)
          }
        Text("Used for new standalone chats and as the fallback when a project has no instructions.")
          .font(.caption)
          .foregroundStyle(MacDesignTokens.Colors.textMuted)
      }
    }
    .formStyle(.grouped)
    .padding(12)
    .background(MacDesignTokens.Colors.canvas)
  }
}

private struct MacAppearanceSettingsView: View {
  @Bindable var theme: MacThemeModel

  private let columns = [
    GridItem(.adaptive(minimum: 145, maximum: 190), spacing: 12)
  ]

  var body: some View {
    ScrollView {
      LazyVGrid(columns: columns, spacing: 12) {
        ForEach(MacThemeID.allCases) { item in
          themeCard(item)
        }
      }
      .padding(18)
    }
    .background(MacDesignTokens.Colors.canvas)
  }

  private func themeCard(_ item: MacThemeID) -> some View {
    let palette = item.palette
    return Button {
      theme.selectedID = item
    } label: {
      VStack(alignment: .leading, spacing: 10) {
        VStack(spacing: 0) {
          HStack(spacing: 5) {
            Circle().fill(palette.accent).frame(width: 7, height: 7)
            RoundedRectangle(cornerRadius: 3).fill(palette.textMuted.opacity(0.45)).frame(height: 6)
            RoundedRectangle(cornerRadius: 3).fill(palette.textMuted.opacity(0.24)).frame(width: 34, height: 6)
          }
          .padding(10)

          VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: 4).fill(palette.textPrimary.opacity(0.82)).frame(width: 78, height: 7)
            RoundedRectangle(cornerRadius: 4).fill(palette.textMuted.opacity(0.45)).frame(width: 112, height: 6)
            HStack {
              Spacer()
              RoundedRectangle(cornerRadius: 10).fill(palette.selection).frame(width: 70, height: 24)
            }
          }
          .padding(10)
          .background(palette.surface)
        }
        .background(palette.canvas)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
          RoundedRectangle(cornerRadius: 8).stroke(palette.separator, lineWidth: 1)
        }

        HStack {
          Text(item.title)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(MacDesignTokens.Colors.textPrimary)
            .lineLimit(1)
          Spacer()
          if theme.selectedID == item {
            Image(systemName: "checkmark.circle.fill")
              .foregroundStyle(MacDesignTokens.Colors.accent)
          }
        }
      }
      .padding(10)
      .background(
        theme.selectedID == item ? MacDesignTokens.Colors.selection : MacDesignTokens.Colors.surface,
        in: RoundedRectangle(cornerRadius: MacDesignTokens.Radius.large)
      )
      .overlay {
        RoundedRectangle(cornerRadius: MacDesignTokens.Radius.large)
          .stroke(
            theme.selectedID == item ? MacDesignTokens.Colors.accent.opacity(0.65) : MacDesignTokens.Colors.separator.opacity(0.7),
            lineWidth: 1
          )
      }
    }
    .buttonStyle(.plain)
    .accessibilityLabel(item.title)
    .accessibilityValue(theme.selectedID == item ? "Selected" : "")
  }
}

private struct MacConnectionSettingsView: View {
  let model: MacAppModel
  @State private var showingConnections = false

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      if let providers = model.providers {
        GroupBox("Provider Connections") {
          VStack(alignment: .leading, spacing: 12) {
            Text("\(providers.accounts.count) configured connection\(providers.accounts.count == 1 ? "" : "s")")
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
            Button("Manage Connections…") {
              showingConnections = true
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(8)
        }
      } else {
        ContentUnavailableView(
          "Connections Unavailable",
          systemImage: "bolt.slash",
          description: Text("Finish app startup before editing provider connections.")
        )
      }
      Spacer()
    }
    .padding(20)
    .background(MacDesignTokens.Colors.canvas)
    .sheet(isPresented: $showingConnections) {
      if let providers = model.providers {
        MacProviderManagementView(model: providers)
      }
    }
  }
}

private struct MacToolsSettingsView: View {
  let model: MacAppModel
  @State private var showingServers = false

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      if let mcp = model.mcp {
        GroupBox("MCP Servers") {
          VStack(alignment: .leading, spacing: 12) {
            HStack {
              VStack(alignment: .leading, spacing: 3) {
                Text("\(mcp.servers.count) configured server\(mcp.servers.count == 1 ? "" : "s")")
                Text("Tools are enabled per chat or inherited from Projects.")
                  .font(.caption)
                  .foregroundStyle(MacDesignTokens.Colors.textMuted)
              }
              Spacer()
              Button("Manage MCP Servers…") {
                showingServers = true
              }
            }

            if !mcp.servers.isEmpty {
              Divider()
              ForEach(mcp.servers.prefix(6)) { server in
                HStack {
                  Image(systemName: server.isEnabled ? "shippingbox.fill" : "shippingbox")
                    .foregroundStyle(server.isEnabled ? MacDesignTokens.Colors.accent : MacDesignTokens.Colors.textMuted)
                  Text(server.name)
                  Spacer()
                  Text("\(mcp.snapshot(for: server.id)?.tools.count ?? 0) tools")
                    .font(.caption)
                    .foregroundStyle(MacDesignTokens.Colors.textMuted)
                }
              }
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(8)
        }
      } else {
        ContentUnavailableView(
          "Tools Unavailable",
          systemImage: "wrench.and.screwdriver",
          description: Text("Finish app startup before configuring MCP servers.")
        )
      }
      Spacer()
    }
    .padding(20)
    .background(MacDesignTokens.Colors.canvas)
    .sheet(isPresented: $showingServers) {
      if let mcp = model.mcp {
        MacMCPServerListView(mcp: mcp)
      }
    }
  }
}

private struct MacDataSettingsView: View {
  let model: MacAppModel

  var body: some View {
    if let data = model.dataManagement {
      MacDataManagementView(app: model, data: data)
    } else {
      ContentUnavailableView(
        "Data Management Unavailable",
        systemImage: "externaldrive.badge.exclamationmark",
        description: Text("Finish app startup before importing, exporting, or resetting data.")
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(MacDesignTokens.Colors.canvas)
    }
  }
}

private struct MacDiagnosticsSettingsView: View {
  let model: MacAppModel

  var body: some View {
    if let diagnostics = model.diagnostics {
      MacDiagnosticsView(diagnostics: diagnostics)
    } else {
      ContentUnavailableView(
        "Diagnostics Unavailable",
        systemImage: "waveform.path.ecg.rectangle",
        description: Text("Finish app startup before inspecting local diagnostics.")
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(MacDesignTokens.Colors.canvas)
    }
  }
}

private struct MacThemeRevisionKey: EnvironmentKey {
  static let defaultValue = 0
}

extension EnvironmentValues {
  var macThemeRevision: Int {
    get { self[MacThemeRevisionKey.self] }
    set { self[MacThemeRevisionKey.self] = newValue }
  }
}
