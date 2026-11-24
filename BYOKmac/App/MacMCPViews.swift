import BYOKchatProviderCore
import Foundation
import SwiftUI

enum MacMCPConfigurationContext: Equatable {
  case chat(projectName: String?)
  case project

  var enableTitle: String {
    switch self {
    case .chat: "Enable for This Chat"
    case .project: "Enable in Project"
    }
  }

  var guidance: String {
    switch self {
    case .chat:
      "Only tools enabled here are sent to the model for this chat. New tools default to Ask."
    case .project:
      "These are project defaults. Chats inherit them until they customize Tools themselves."
    }
  }

  var guidanceIcon: String {
    switch self {
    case .chat: "hand.raised"
    case .project: "arrow.triangle.branch"
    }
  }
}

enum MacMCPServerDetailTab: String, CaseIterable, Identifiable {
  case overview = "Overview"
  case tools = "Tools"
  case connection = "Connection"

  var id: String { rawValue }
}

enum MacMCPServerPresentationState: String, Equatable {
  case disabled = "Disabled"
  case needsDiscovery = "Needs discovery"
  case discovered = "Discovered"
}

func macMCPServerPresentationState(
  server: MCPRemoteServer,
  snapshot: MCPServerSnapshot?
) -> MacMCPServerPresentationState {
  guard server.isEnabled else { return .disabled }
  return snapshot == nil ? .needsDiscovery : .discovered
}

enum MacMCPToolCatalogState: Equatable {
  case notDiscovered
  case noTools
  case noSearchResults
  case results
}

func macMCPToolCatalogState(
  snapshot: MCPServerSnapshot?,
  filteredToolCount: Int,
  searchText: String
) -> MacMCPToolCatalogState {
  guard let snapshot else { return .notDiscovered }
  if snapshot.tools.isEmpty { return .noTools }
  if filteredToolCount == 0,
    !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  {
    return .noSearchResults
  }
  return .results
}

struct MacMCPServerManagementView: View {
  @Bindable var mcp: MacMCPModel

  @State private var showingAddServer = false
  @State private var selectedServerID: MCPServerID?
  @State private var deleteServer: MCPRemoteServer?

  private var selectedServer: MCPRemoteServer? {
    guard let selectedServerID else { return nil }
    return mcp.servers.first { $0.id == selectedServerID }
  }

  private var enabledServerCount: Int {
    mcp.servers.filter(\.isEnabled).count
  }

  private var discoveredToolCount: Int {
    mcp.servers.reduce(0) { count, server in
      count + (mcp.snapshot(for: server.id)?.tools.count ?? 0)
    }
  }

  var body: some View {
    Group {
      if let selectedServer {
        MacMCPServerDetailView(
          mcp: mcp,
          server: selectedServer,
          dismissDetail: { selectedServerID = nil },
          requestDelete: { deleteServer = selectedServer }
        )
      } else {
        serverList
      }
    }
    .frame(minWidth: 760, minHeight: 600)
    .background(MacDesignTokens.Colors.canvas)
    .sheet(isPresented: $showingAddServer) {
      MacMCPServerConnectionEditorView(mcp: mcp, server: nil)
    }
    .confirmationDialog(
      deleteServer.map { "Delete \"\($0.name)\"?" } ?? "Delete MCP server?",
      isPresented: Binding(
        get: { deleteServer != nil },
        set: { if !$0 { deleteServer = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("Delete Server", role: .destructive) {
        guard let server = deleteServer else { return }
        deleteServer = nil
        selectedServerID = nil
        Task { _ = await mcp.deleteServer(server.id) }
      }
      Button("Cancel", role: .cancel) { deleteServer = nil }
    } message: {
      Text("The server configuration, cached tool catalog, chat selections, and its Keychain credential will be removed.")
    }
    .alert(
      "MCP Error",
      isPresented: Binding(
        get: { mcp.errorMessage != nil },
        set: { if !$0 { mcp.errorMessage = nil } }
      )
    ) {
      Button("OK") { mcp.errorMessage = nil }
    } message: {
      Text(mcp.errorMessage ?? "Unknown error")
    }
  }

  private var serverList: some View {
    VStack(spacing: 0) {
      HStack(alignment: .center, spacing: 12) {
        VStack(alignment: .leading, spacing: 3) {
          Text("Connect external tools and services to BYOKchat.")
            .font(.subheadline)
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
          Text("\(enabledServerCount) enabled · \(discoveredToolCount) tools discovered")
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        Spacer()
        Button("Add Server", systemImage: "plus") {
          guard MacProAccess.requireMCPServerCapacity(currentCount: mcp.servers.count) else { return }
          showingAddServer = true
        }
      }
      .padding(.horizontal, 18)
      .padding(.vertical, 14)

      Divider()

      if mcp.servers.isEmpty {
        ContentUnavailableView(
          "No MCP Servers",
          systemImage: "shippingbox.and.arrow.backward",
          description: Text("Add a remote Streamable HTTP MCP endpoint to discover its tools.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVStack(spacing: 10) {
            ForEach(mcp.servers) { server in
              serverCard(server)
            }
          }
          .padding(16)
        }
      }
    }
  }

  private func serverCard(_ server: MCPRemoteServer) -> some View {
    HStack(spacing: 12) {
      Button {
        selectedServerID = server.id
      } label: {
        HStack(spacing: 12) {
          Circle()
            .fill(statusColor(server))
            .frame(width: 9, height: 9)
            .accessibilityHidden(true)

          VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
              Text(server.name)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(MacDesignTokens.Colors.textPrimary)
              if let snapshot = mcp.snapshot(for: server.id) {
                Text("\(snapshot.tools.count) tools")
                  .font(.caption2)
                  .foregroundStyle(MacDesignTokens.Colors.textMuted)
              }
            }
            Text(statusTitle(server))
              .font(.caption)
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
            Text(server.endpoint.absoluteString)
              .font(.caption2)
              .foregroundStyle(.tertiary)
              .lineLimit(1)
          }

          Spacer(minLength: 12)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      Toggle(
        "Enabled",
        isOn: Binding(
          get: { server.isEnabled },
          set: { enabled in
            Task { _ = await mcp.setEnabled(enabled, serverID: server.id) }
          }
        )
      )
      .labelsHidden()
      .toggleStyle(.switch)
      .controlSize(.small)
      .disabled(mcp.isBusy)

      Menu {
        Button("Configure", systemImage: "slider.horizontal.3") {
          selectedServerID = server.id
        }
        Button("Refresh Tools", systemImage: "arrow.clockwise") {
          Task { _ = await mcp.refresh(server.id) }
        }
        .disabled(mcp.isBusy || !server.isEnabled)
        Divider()
        Button("Delete", systemImage: "trash", role: .destructive) {
          deleteServer = server
        }
      } label: {
        Image(systemName: "ellipsis")
          .frame(width: 28, height: 24)
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
    }
    .padding(14)
    .background(MacDesignTokens.Colors.surface, in: RoundedRectangle(cornerRadius: 10))
    .overlay {
      RoundedRectangle(cornerRadius: 10)
        .stroke(MacDesignTokens.Colors.separator.opacity(0.8), lineWidth: 0.5)
    }
    .contextMenu {
      Button("Configure", systemImage: "slider.horizontal.3") { selectedServerID = server.id }
      Button("Refresh Tools", systemImage: "arrow.clockwise") {
        Task { _ = await mcp.refresh(server.id) }
      }
      .disabled(mcp.isBusy || !server.isEnabled)
      Divider()
      Button("Delete", systemImage: "trash", role: .destructive) { deleteServer = server }
    }
  }

  private func statusTitle(_ server: MCPRemoteServer) -> String {
    macMCPServerPresentationState(
      server: server,
      snapshot: mcp.snapshot(for: server.id)
    ).rawValue
  }

  private func statusColor(_ server: MCPRemoteServer) -> Color {
    switch macMCPServerPresentationState(server: server, snapshot: mcp.snapshot(for: server.id)) {
    case .disabled:
      MacDesignTokens.Colors.textMuted.opacity(0.55)
    case .needsDiscovery:
      .orange
    case .discovered:
      MacDesignTokens.Colors.accent
    }
  }
}

private struct MacMCPServerDetailView: View {
  @Bindable var mcp: MacMCPModel
  let server: MCPRemoteServer
  let dismissDetail: () -> Void
  let requestDelete: () -> Void

  @State private var tab: MacMCPServerDetailTab = .overview
  @State private var showingConnectionEditor = false
  @State private var searchText = ""

  private var snapshot: MCPServerSnapshot? { mcp.snapshot(for: server.id) }

  private var presentationState: MacMCPServerPresentationState {
    macMCPServerPresentationState(server: server, snapshot: snapshot)
  }

  private var filteredTools: [MCPRemoteTool] {
    guard let tools = snapshot?.tools else { return [] }
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return tools }
    return tools.filter {
      $0.remoteName.localizedCaseInsensitiveContains(query)
        || ($0.title?.localizedCaseInsensitiveContains(query) ?? false)
        || $0.description.localizedCaseInsensitiveContains(query)
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Button("MCP Servers", systemImage: "chevron.left") { dismissDetail() }
          .buttonStyle(.borderless)
        Divider().frame(height: 18)
        VStack(alignment: .leading, spacing: 2) {
          Text(server.name).font(.headline)
          Text(presentationState.rawValue)
            .font(.caption)
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
        }
        Spacer()
        Toggle(
          "Enabled",
          isOn: Binding(
            get: { server.isEnabled },
            set: { enabled in
              Task { _ = await mcp.setEnabled(enabled, serverID: server.id) }
            }
          )
        )
        .toggleStyle(.switch)
        .controlSize(.small)
        .disabled(mcp.isBusy)
      }
      .padding(.horizontal, 18)
      .padding(.vertical, 12)

      Divider()

      Picker("Section", selection: $tab) {
        ForEach(MacMCPServerDetailTab.allCases) { item in
          Text(item.rawValue).tag(item)
        }
      }
      .pickerStyle(.segmented)
      .frame(maxWidth: 420)
      .padding(.vertical, 12)

      Divider()

      Group {
        switch tab {
        case .overview: overview
        case .tools: tools
        case .connection: connection
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .sheet(isPresented: $showingConnectionEditor) {
      MacMCPServerConnectionEditorView(mcp: mcp, server: server)
    }
  }

  private var overview: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        HStack(spacing: 20) {
          statusMetric(
            presentationState.rawValue,
            systemImage: presentationState == .discovered
              ? "checkmark.circle.fill"
              : "exclamationmark.triangle"
          )
          statusMetric("\(snapshot?.tools.count ?? 0) tools", systemImage: "wrench.and.screwdriver")
          if let snapshot {
            statusMetric("MCP \(snapshot.protocolVersion)", systemImage: "network")
          }
          Spacer()
          Button("Refresh Tools", systemImage: "arrow.clockwise") {
            Task { _ = await mcp.refresh(server.id) }
          }
          .disabled(mcp.isBusy || !server.isEnabled)
        }

        detailCard("Server") {
          LabeledContent("Name", value: server.name)
          LabeledContent("Endpoint", value: server.endpoint.absoluteString)
            .textSelection(.enabled)
          LabeledContent("Authentication", value: authenticationTitle(server.authentication.kind))
          LabeledContent("Credential", value: mcp.hasCredential(server.id) ? "Stored in Keychain" : "None")
        }

        if let snapshot {
          detailCard("Discovery") {
            LabeledContent("Protocol", value: snapshot.protocolVersion)
            LabeledContent("Mode", value: snapshot.era == .modern ? "Modern" : "Legacy fallback")
            if let info = snapshot.serverInfo {
              LabeledContent("Server", value: "\(info.name) \(info.version)")
            }
            if let instructions = snapshot.instructions,
              !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
              DisclosureGroup("Server Instructions") {
                Text(instructions)
                  .font(.caption)
                  .textSelection(.enabled)
                  .padding(.top, 5)
              }
            }
            ForEach(snapshot.warnings, id: \.self) { warning in
              Label(warning, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
            }
          }
        }

        HStack {
          Spacer()
          Button("Edit Connection…", systemImage: "slider.horizontal.3") {
            showingConnectionEditor = true
          }
        }
      }
      .padding(18)
    }
  }

  private var tools: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        HStack(spacing: 7) {
          Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
          TextField("Search tools", text: $searchText)
            .textFieldStyle(.plain)
        }
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(MacDesignTokens.Colors.surface, in: RoundedRectangle(cornerRadius: 7))
        .overlay {
          RoundedRectangle(cornerRadius: 7)
            .stroke(MacDesignTokens.Colors.separator.opacity(0.75), lineWidth: 0.5)
        }
        Spacer()
        Text("Permissions are configured per chat or project.")
          .font(.caption)
          .foregroundStyle(MacDesignTokens.Colors.textMuted)
      }
      .padding(14)

      Divider()

      switch macMCPToolCatalogState(
        snapshot: snapshot,
        filteredToolCount: filteredTools.count,
        searchText: searchText
      ) {
      case .notDiscovered:
        ContentUnavailableView(
          "Tools Not Discovered",
          systemImage: "wrench.and.screwdriver",
          description: Text("Refresh this server to discover its available tools.")
        )
      case .noTools:
        ContentUnavailableView(
          "No Tools Available",
          systemImage: "wrench.and.screwdriver",
          description: Text("This server returned no tools. Refresh to check again.")
        )
      case .noSearchResults:
        ContentUnavailableView.search(text: searchText)
      case .results:
        ScrollView {
          LazyVStack(spacing: 0) {
            ForEach(filteredTools) { tool in
              DisclosureGroup {
                VStack(alignment: .leading, spacing: 10) {
                  Text(tool.description)
                    .font(.caption)
                  safetyHints(for: tool)
                  LabeledContent("Remote name", value: tool.remoteName)
                    .font(.caption)
                  DisclosureGroup("Input schema") {
                    Text(tool.inputSchema.macPrettyJSONString())
                      .font(.system(size: 11, design: .monospaced))
                      .textSelection(.enabled)
                      .padding(.top, 4)
                  }
                  .font(.caption)
                }
                .padding(.vertical, 8)
              } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                  VStack(alignment: .leading, spacing: 3) {
                    Text(tool.title ?? tool.remoteName)
                      .font(.system(size: 13, weight: .medium))
                    Text(tool.description)
                      .font(.caption)
                      .foregroundStyle(MacDesignTokens.Colors.textMuted)
                      .lineLimit(1)
                  }
                  Spacer()
                  safetyHints(for: tool)
                }
                .padding(.vertical, 8)
              }
              .padding(.horizontal, 16)
              Divider().padding(.leading, 16)
            }
          }
        }
      }
    }
  }

  private var connection: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        detailCard("Connection") {
          LabeledContent("Name", value: server.name)
          LabeledContent("Endpoint", value: server.endpoint.absoluteString)
            .textSelection(.enabled)
          LabeledContent("Authentication", value: authenticationTitle(server.authentication.kind))
          LabeledContent("Credential", value: mcp.hasCredential(server.id) ? "Stored in Keychain" : "None")
          LabeledContent(
            "Additional Headers",
            value: server.additionalHeaders.isEmpty ? "None" : server.additionalHeaders.count.formatted()
          )
        }

        HStack {
          Button("Delete Server…", role: .destructive) { requestDelete() }
          Spacer()
          Button("Edit Connection…", systemImage: "pencil") { showingConnectionEditor = true }
        }
      }
      .padding(18)
    }
  }

  private func statusMetric(_ title: String, systemImage: String) -> some View {
    Label(title, systemImage: systemImage)
      .font(.caption.weight(.medium))
      .foregroundStyle(MacDesignTokens.Colors.textMuted)
  }

  private func detailCard<Content: View>(
    _ title: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(title).font(.headline)
      VStack(alignment: .leading, spacing: 10) { content() }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(MacDesignTokens.Colors.surface, in: RoundedRectangle(cornerRadius: 10))
    .overlay {
      RoundedRectangle(cornerRadius: 10)
        .stroke(MacDesignTokens.Colors.separator.opacity(0.8), lineWidth: 0.5)
    }
  }

  private func authenticationTitle(_ kind: MCPAuthenticationKind) -> String {
    switch kind {
    case .none: "None"
    case .bearer: "Bearer Token"
    case .customHeader: "Custom Header"
    }
  }

  @ViewBuilder
  private func safetyHints(for tool: MCPRemoteTool) -> some View {
    HStack(spacing: 7) {
      if macMCPAnnotationBool("readOnlyHint", tool: tool) == true {
        Label("Read-only", systemImage: "eye")
      }
      if macMCPAnnotationBool("destructiveHint", tool: tool) == true {
        Label("Destructive", systemImage: "exclamationmark.triangle")
          .foregroundStyle(.orange)
      }
    }
    .font(.caption2)
    .foregroundStyle(MacDesignTokens.Colors.textMuted)
  }
}

private struct MacMCPServerConnectionEditorView: View {
  @Bindable var mcp: MacMCPModel
  let server: MCPRemoteServer?

  @Environment(\.dismiss) private var dismiss
  @State private var name: String
  @State private var endpoint: String
  @State private var authenticationKind: MCPAuthenticationKind
  @State private var authenticationHeader: String
  @State private var credential = ""
  @State private var additionalHeaders: [MacAdditionalHeaderItem]
  @State private var headerEditorTarget: MacAdditionalHeaderEditorTarget?
  @State private var showingAdvanced: Bool
  @State private var isSaving = false

  init(mcp: MacMCPModel, server: MCPRemoteServer?) {
    self.mcp = mcp
    self.server = server
    let savedHeaders = server?.additionalHeaders ?? [:]
    _name = State(initialValue: server?.name ?? "")
    _endpoint = State(initialValue: server?.endpoint.absoluteString ?? "https://")
    _authenticationKind = State(initialValue: server?.authentication.kind ?? .none)
    _authenticationHeader = State(initialValue: server?.authentication.headerName ?? "X-API-Key")
    _additionalHeaders = State(initialValue: MacAdditionalHeaderItem.items(from: savedHeaders))
    _showingAdvanced = State(initialValue: !savedHeaders.isEmpty)
  }

  private var headerValidationPolicy: HTTPHeaderValidationPolicy {
    .mcp(
      authenticationHeader: authenticationKind == .customHeader
        ? authenticationHeader
        : nil
    )
  }

  private var hasInvalidAdditionalHeaders: Bool {
    MacAdditionalHeaderItem.hasValidationErrors(
      in: additionalHeaders,
      policy: headerValidationPolicy
    )
  }

  private var canSave: Bool {
    guard !isSaving else { return false }
    guard !hasInvalidAdditionalHeaders else { return false }
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
    guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
      let scheme = url.scheme?.lowercased(),
      scheme == "https" || scheme == "http",
      url.host != nil
    else { return false }
    if authenticationKind == .customHeader,
      authenticationHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      return false
    }
    return true
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text(server == nil ? "Add MCP Server" : "Edit Connection")
          .font(.headline)
        Spacer()
        Button("Cancel") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button(server == nil ? "Add Server" : "Save") { save() }
          .keyboardShortcut(.defaultAction)
          .disabled(!canSave)
      }
      .padding(16)

      Divider()

      Form {
        Section("Server") {
          TextField("Name", text: $name)
          TextField("Server URL", text: $endpoint, prompt: Text("https://example.com/mcp"))
            .textFieldStyle(.roundedBorder)
        }

        Section("Authentication") {
          Picker("Authentication", selection: $authenticationKind) {
            Text("None").tag(MCPAuthenticationKind.none)
            Text("Bearer Token").tag(MCPAuthenticationKind.bearer)
            Text("Custom Header").tag(MCPAuthenticationKind.customHeader)
          }
          if authenticationKind == .customHeader {
            TextField("Header Name", text: $authenticationHeader)
          }
          if authenticationKind != .none {
            SecureField(credentialPlaceholder, text: $credential)
          }
          Text("Credentials are stored securely in Keychain.")
            .font(.caption)
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
        }

        Section {
          DisclosureGroup(isExpanded: $showingAdvanced) {
            MacAdditionalHeadersSection(
              headers: $additionalHeaders,
              policy: headerValidationPolicy,
              footerText: "Optional non-secret headers. Authentication and MCP protocol headers are managed by BYOKchat.",
              editorTarget: $headerEditorTarget
            )
            .padding(.top, 8)
          } label: {
            HStack(spacing: 8) {
              Text("Additional Headers")
              Spacer()
              if hasInvalidAdditionalHeaders {
                Image(systemName: "exclamationmark.triangle.fill")
                  .font(.caption)
                  .foregroundStyle(.red)
              }
              Text(additionalHeaders.isEmpty ? "None" : "\(additionalHeaders.count)")
                .font(.caption)
                .foregroundStyle(hasInvalidAdditionalHeaders ? Color.red : MacDesignTokens.Colors.textMuted)
            }
          }
        }
      }
      .formStyle(.grouped)
      .padding(10)
    }
    .frame(width: 560, height: 520)
    .background(MacDesignTokens.Colors.canvas)
    .onChange(of: hasInvalidAdditionalHeaders) { _, hasErrors in
      if hasErrors && !showingAdvanced {
        showingAdvanced = true
      }
    }
    .macAdditionalHeaderEditorSheet(
      target: $headerEditorTarget,
      headers: $additionalHeaders,
      policy: headerValidationPolicy
    )
  }

  private var credentialPlaceholder: String {
    guard let server, mcp.hasCredential(server.id) else { return "Credential" }
    return "Leave blank to keep current credential"
  }

  private func save() {
    guard canSave else { return }
    let headers: [String: String]
    do {
      headers = try MacAdditionalHeaderItem.validatedDictionary(
        from: additionalHeaders,
        policy: headerValidationPolicy
      )
    } catch {
      showingAdvanced = true
      mcp.errorMessage = error.localizedDescription
      return
    }

    isSaving = true
    Task { @MainActor in
      defer { isSaving = false }
      let newCredential: String?
      if authenticationKind == .none {
        newCredential = ""
      } else if credential.isEmpty, server != nil {
        newCredential = nil
      } else {
        newCredential = credential
      }

      let saved = await mcp.saveServer(
        existing: server,
        name: name,
        endpoint: endpoint,
        authenticationKind: authenticationKind,
        authenticationHeader: authenticationHeader,
        credential: newCredential,
        additionalHeaders: headers,
        isEnabled: server?.isEnabled ?? true
      )
      if saved { dismiss() }
    }
  }
}

struct MacChatToolsView: View {
  @Bindable var mcp: MacMCPModel
  let conversationID: ConversationID
  let presets: [ProjectToolPreset]
  let isGenerating: Bool
  let modelSupportsTools: Bool
  let manageServers: (() -> Void)?

  @Environment(\.dismiss) private var dismiss
  @Environment(MacWorkspaceModel.self) private var workspace
  @State private var showingAddServer = false

  init(
    mcp: MacMCPModel,
    conversationID: ConversationID,
    presets: [ProjectToolPreset],
    isGenerating: Bool = false,
    modelSupportsTools: Bool = true,
    manageServers: (() -> Void)? = nil
  ) {
    self.mcp = mcp
    self.conversationID = conversationID
    self.presets = presets
    self.isGenerating = isGenerating
    self.modelSupportsTools = modelSupportsTools
    self.manageServers = manageServers
  }

  private var project: ChatProject? {
    workspace.project(for: conversationID)
  }

  private var isMutationDisabled: Bool {
    mcp.isBusy || isGenerating
  }

  var body: some View {
    let activeConfig = normalizedToolConfiguration(mcp.chatConfiguration(for: conversationID))
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text("Chat Tools")
            .font(.headline)
          if mcp.inheritsProjectTools(conversationID), let project {
            Text("Inheriting defaults from \(project.name)")
              .font(.caption)
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
          } else if mcp.hasChatOverride(conversationID) {
            Text("This chat has its own tool configuration")
              .font(.caption)
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
          }
        }
        Spacer()

        if !presets.isEmpty {
          Menu("Apply Preset") {
            ForEach(presets) { preset in
              let isApplied = normalizedToolConfiguration(preset.configuration) == activeConfig
              Button {
                Task {
                  _ = await mcp.applyChatConfiguration(
                    preset.configuration,
                    conversationID: conversationID
                  )
                }
              } label: {
                if isApplied {
                  Label(preset.name, systemImage: "checkmark")
                } else {
                  Text(preset.name)
                }
              }
            }
          }
          .disabled(isMutationDisabled)
        }

        if mcp.hasChatOverride(conversationID), project != nil {
          Button("Reset to Project Defaults") {
            Task { _ = await mcp.removeChatConfiguration(conversationID) }
          }
          .disabled(isMutationDisabled)
        }

        Button("Done") { dismiss() }
          .keyboardShortcut(.cancelAction)
      }
      .padding(16)

      Divider()

      MacMCPServerConfigurationList(
        mcp: mcp,
        configuration: mcp.chatConfiguration(for: conversationID),
        context: .chat(projectName: project?.name),
        isGenerating: isGenerating,
        modelSupportsTools: modelSupportsTools,
        addServer: {
          if let manageServers {
            dismiss()
            manageServers()
          } else if MacProAccess.requireMCPServerCapacity(currentCount: mcp.servers.count) {
            showingAddServer = true
          }
        },
        setServerEnabled: { serverID, enabled in
          Task {
            _ = await mcp.setChatServerEnabled(
              enabled,
              serverID: serverID,
              conversationID: conversationID
            )
          }
        },
        setPolicy: { name, policy in
          Task {
            _ = await mcp.setChatToolPolicy(
              policy,
              exposedToolName: name,
              conversationID: conversationID
            )
          }
        }
      )
    }
    .frame(width: 700, height: 650)
    .background(MacDesignTokens.Colors.canvas)
    .sheet(isPresented: $showingAddServer) {
      MacMCPServerConnectionEditorView(mcp: mcp, server: nil)
    }
  }

  private func normalizedToolConfiguration(
    _ configuration: MCPChatToolConfiguration
  ) -> MCPChatToolConfiguration {
    MCPChatToolConfiguration(
      enabledServerIDs: Array(Set(configuration.enabledServerIDs)).sorted { $0.rawValue < $1.rawValue },
      toolPolicies: configuration.toolPolicies.filter { $0.value != .ask }
    )
  }
}

struct MacProjectToolsConfigurationView: View {
  @Bindable var mcp: MacMCPModel
  @Binding var configuration: MCPChatToolConfiguration
  @State private var showingAddServer = false

  var body: some View {
    MacMCPServerConfigurationList(
      mcp: mcp,
      configuration: configuration,
      context: .project,
      addServer: {
        guard MacProAccess.requireMCPServerCapacity(currentCount: mcp.servers.count) else { return }
        showingAddServer = true
      },
      setServerEnabled: { serverID, enabled in
        configuration.enabledServerIDs.removeAll { $0 == serverID }
        if enabled { configuration.enabledServerIDs.append(serverID) }
        configuration.enabledServerIDs.sort { $0.rawValue < $1.rawValue }
      },
      setPolicy: { name, policy in
        if policy == .ask {
          configuration.toolPolicies.removeValue(forKey: name)
        } else {
          configuration.toolPolicies[name] = policy
        }
      }
    )
    .sheet(isPresented: $showingAddServer) {
      MacMCPServerConnectionEditorView(mcp: mcp, server: nil)
    }
  }
}

private struct MacMCPServerConfigurationList: View {
  @Bindable var mcp: MacMCPModel
  let configuration: MCPChatToolConfiguration
  let context: MacMCPConfigurationContext
  var isGenerating: Bool = false
  var modelSupportsTools: Bool = true
  var addServer: (() -> Void)? = nil
  let setServerEnabled: (MCPServerID, Bool) -> Void
  let setPolicy: (String, ChatToolPermissionPolicy) -> Void

  private var isMutationDisabled: Bool {
    isGenerating || (mcp.isBusy && isChatContext)
  }

  var body: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 10) {
          Image(systemName: context.guidanceIcon)
            .foregroundStyle(MacDesignTokens.Colors.accent)
          Text(context.guidance)
            .font(.caption)
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
          Spacer()
        }

        if isGenerating {
          HStack(alignment: .top, spacing: 8) {
            Image(systemName: "hourglass")
              .font(.caption.weight(.semibold))
              .foregroundStyle(.orange)
              .padding(.top, 1)
            Text("Wait for the current response to finish before changing tools.")
              .font(.caption)
              .foregroundStyle(MacDesignTokens.Colors.textPrimary)
          }
        }

        if !modelSupportsTools {
          HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
              .font(.caption.weight(.semibold))
              .foregroundStyle(.orange)
              .padding(.top, 1)
            Text("The current model does not support tools. Enabled tools will not be sent until you switch models.")
              .font(.caption)
              .foregroundStyle(MacDesignTokens.Colors.textPrimary)
          }
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
      .background(MacDesignTokens.Colors.surface.opacity(0.75))

      if mcp.servers.isEmpty {
        ContentUnavailableView {
          Label("No MCP Servers", systemImage: "server.rack")
        } description: {
          Text("Add a remote MCP server to discover and enable tools.")
        } actions: {
          if let addServer {
            Button("Add MCP Server") {
              addServer()
            }
            .buttonStyle(.borderedProminent)
            .disabled(mcp.isBusy)
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVStack(spacing: 10) {
            ForEach(mcp.servers) { server in
              serverConfigurationCard(server)
            }
          }
          .padding(14)
        }
      }
    }
  }

  private func serverConfigurationCard(_ server: MCPRemoteServer) -> some View {
    let enabled = configuration.isServerEnabled(server.id)
    let missingCredential = server.authentication.kind != .none && !mcp.hasCredential(server.id)
    let tools = mcp.tools(for: server.id)
    let snapshot = mcp.snapshot(for: server.id)

    return VStack(alignment: .leading, spacing: 0) {
      DisclosureGroup {
        VStack(alignment: .leading, spacing: 8) {
          if !server.isEnabled {
            Label(
              "Enable this server globally in MCP Servers before using its tools here.",
              systemImage: "pause.circle"
            )
            .font(.caption)
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
          } else if missingCredential {
            Label(
              "Missing credential. Add it in MCP Servers before enabling.",
              systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(.orange)
          } else if !enabled {
            Label(
              context == .project
                ? "Enable in Project to configure this server's tool permissions."
                : "Enable for This Chat to configure this server's tool permissions.",
              systemImage: "switch.2"
            )
            .font(.caption)
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
          } else if tools.isEmpty {
            HStack {
              Text("No cached tools yet.")
                .font(.caption)
                .foregroundStyle(MacDesignTokens.Colors.textMuted)
              Spacer()
              Button("Refresh Tools", systemImage: "arrow.clockwise") {
                Task { _ = await mcp.refresh(server.id) }
              }
              .disabled(mcp.isBusy)
            }
          } else {
            ForEach(tools) { binding in
              toolPermissionRow(binding)
            }
          }
        }
        .padding(.top, 8)
      } label: {
        HStack(spacing: 10) {
          Circle()
            .fill(
              !server.isEnabled
                ? MacDesignTokens.Colors.textMuted.opacity(0.5)
                : (missingCredential ? Color.orange : MacDesignTokens.Colors.accent)
            )
            .frame(width: 8, height: 8)
          VStack(alignment: .leading, spacing: 2) {
            Text(server.name)
              .font(.system(size: 13.5, weight: .medium))
            if !server.isEnabled {
              Text("Globally disabled")
                .font(.caption)
                .foregroundStyle(MacDesignTokens.Colors.textMuted)
            } else if missingCredential {
              Text("Missing credential. Add it in MCP Servers before enabling.")
                .font(.caption)
                .foregroundStyle(.orange)
            } else {
              Text("\(tools.count) \(tools.count == 1 ? "tool" : "tools") discovered")
                .font(.caption)
                .foregroundStyle(MacDesignTokens.Colors.textMuted)
            }
          }
          Spacer()
          if server.isEnabled && !missingCredential {
            Button {
              Task { _ = await mcp.refresh(server.id) }
            } label: {
              Image(systemName: "arrow.clockwise")
                .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(MacIconButtonStyle())
            .disabled(mcp.isBusy)
            .help("Refresh tools for \(server.name)")
            .accessibilityLabel("Refresh tools for \(server.name)")
          }
          Toggle(
            context.enableTitle,
            isOn: Binding(
              get: { configuration.isServerEnabled(server.id) },
              set: { setServerEnabled(server.id, $0) }
            )
          )
          .toggleStyle(.switch)
          .controlSize(.small)
          .disabled(((!server.isEnabled || missingCredential) && !enabled) || mcp.isBusy || isGenerating)
        }
        .padding(.vertical, 4)
      }

      if let snapshot {
        HStack {
          Text("MCP \(snapshot.protocolVersion)")
            .font(.caption2)
            .foregroundStyle(.tertiary)
          Spacer()
        }
        .padding(.top, 6)
      }
    }
    .padding(12)
    .background(MacDesignTokens.Colors.surface, in: RoundedRectangle(cornerRadius: 10))
    .overlay {
      RoundedRectangle(cornerRadius: 10)
        .stroke(MacDesignTokens.Colors.separator.opacity(0.75), lineWidth: 0.5)
    }
  }

  private func toolPermissionRow(_ binding: MCPToolBinding) -> some View {
    let tool = binding.remoteTool
    let description = tool.description.trimmingCharacters(in: .whitespacesAndNewlines)
    return HStack(alignment: .top, spacing: 10) {
      VStack(alignment: .leading, spacing: 3) {
        Text(tool.title ?? tool.remoteName)
          .font(.system(size: 13, weight: .medium))
        if !description.isEmpty {
          Text(description)
            .font(.caption)
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
        }
        HStack(spacing: 7) {
          if tool.title != nil {
            Text(tool.remoteName)
              .font(.caption2.monospaced())
              .foregroundStyle(.tertiary)
          }
          if macMCPAnnotationBool("readOnlyHint", tool: tool) == true {
            Label("Read-only", systemImage: "eye")
          }
          if macMCPAnnotationBool("destructiveHint", tool: tool) == true {
            Label("Destructive", systemImage: "exclamationmark.triangle")
              .foregroundStyle(.orange)
          }
        }
        .font(.caption2)
        .foregroundStyle(MacDesignTokens.Colors.textMuted)
      }
      Spacer()
      Picker(
        "Permission",
        selection: Binding(
          get: { configuration.policy(for: binding.exposedName) },
          set: { setPolicy(binding.exposedName, $0) }
        )
      ) {
        ForEach(ChatToolPermissionPolicy.allCases, id: \.self) { policy in
          Text(policy.displayName).tag(policy)
        }
      }
      .labelsHidden()
      .pickerStyle(.menu)
      .frame(width: 130)
      .disabled(isMutationDisabled)
    }
    .padding(.vertical, 3)
  }

  private var isChatContext: Bool {
    if case .chat = context { return true }
    return false
  }
}

func macMCPAnnotationBool(_ key: String, tool: MCPRemoteTool) -> Bool? {
  guard case .object(let annotations)? = tool.annotations,
    case .bool(let value)? = annotations[key]
  else { return nil }
  return value
}

struct MacMCPInteractionStack: View {
  @Bindable var mcp: MacMCPModel
  @Bindable var chats: MacChatSessionModel
  let conversationID: ConversationID

  private var approvals: [MCPToolApprovalRequest] {
    mcp.pendingApprovals(for: conversationID)
  }

  private var approvalCallIDs: Set<String> {
    Set(approvals.map(\.callID))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach(approvals) { request in
        MacMCPApprovalCard(request: request) { decision in
          Task { await mcp.resolveApproval(request.id, decision: decision) }
        }
      }
      ForEach(mcp.pendingElicitations(for: conversationID)) { request in
        MacMCPElicitationCard(request: request) { decision in
          Task { await mcp.resolveElicitation(request.id, decision: decision) }
        }
      }
      ForEach(chats.activeToolCalls(for: conversationID)) { call in
        MacMCPToolRunningCard(
          call: call,
          displayName: mcp.toolDisplayName(call.name),
          waitingForApproval: approvalCallIDs.contains(call.id)
        )
      }
    }
  }
}

private struct MacMCPApprovalCard: View {
  let request: MCPToolApprovalRequest
  let resolve: (MCPToolApprovalDecision) -> Void

  @State private var isResolving = false

  private var isDestructive: Bool {
    request.destructiveHint == true
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: isDestructive ? "exclamationmark.shield" : "hand.raised")
          .font(.system(size: 18, weight: .semibold))
          .foregroundStyle(isDestructive ? Color.orange : MacDesignTokens.Colors.accent)
          .frame(width: 28, height: 28)
        VStack(alignment: .leading, spacing: 3) {
          Text("Allow tool call?")
            .font(.system(size: 14, weight: .semibold))
          Text("\(request.serverName) · \(request.displayName)")
            .font(.system(size: 12.5, weight: .medium))
          Text(request.toolDescription)
            .font(.caption)
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      if request.readOnlyHint == true || isDestructive {
        HStack(spacing: 8) {
          if request.readOnlyHint == true {
            Label("Read-only", systemImage: "eye")
          }
          if isDestructive {
            Label("Destructive", systemImage: "exclamationmark.triangle")
              .foregroundStyle(.orange)
          }
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(MacDesignTokens.Colors.textMuted)
      }

      DisclosureGroup("Arguments") {
        Text(request.arguments.macPrettyJSONString())
          .font(.system(size: 11, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.top, 6)
      }
      .font(.caption.weight(.semibold))

      if isResolving {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text("Applying decision…")
            .font(.caption.weight(.medium))
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
        }
        .padding(.top, 2)
      } else {
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 8) {
            denyButton
            Spacer(minLength: 4)
            allowOnceButton
            alwaysAllowButton
          }
          VStack(alignment: .trailing, spacing: 8) {
            HStack(spacing: 8) {
              denyButton
              allowOnceButton
            }
            alwaysAllowButton
          }
          .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .controlSize(.small)
        .disabled(isResolving)
      }
    }
    .padding(14)
    .background(MacDesignTokens.Colors.surface, in: RoundedRectangle(cornerRadius: MacDesignTokens.Radius.large))
    .overlay {
      RoundedRectangle(cornerRadius: MacDesignTokens.Radius.large)
        .stroke(
          isDestructive ? Color.orange.opacity(0.45) : MacDesignTokens.Colors.separator,
          lineWidth: 1
        )
    }
  }

  private func submit(_ decision: MCPToolApprovalDecision) {
    guard !isResolving else { return }
    isResolving = true
    resolve(decision)
  }

  private var denyButton: some View {
    Button("Deny", role: .destructive) { submit(.deny) }
      .buttonStyle(.bordered)
  }

  @ViewBuilder
  private var allowOnceButton: some View {
    if isDestructive {
      Button("Allow Once") { submit(.allowOnce) }
        .buttonStyle(.borderedProminent)
        .tint(Color.orange)
    } else {
      Button("Allow Once") { submit(.allowOnce) }
        .buttonStyle(.bordered)
    }
  }

  @ViewBuilder
  private var alwaysAllowButton: some View {
    if isDestructive {
      Button("Always Allow") { submit(.alwaysAllow) }
        .buttonStyle(.bordered)
    } else {
      Button("Always Allow") { submit(.alwaysAllow) }
        .buttonStyle(.borderedProminent)
    }
  }
}

enum MacMCPElicitationFormSupport {
  static func initialValues(
    for fields: [MCPElicitationField]
  ) -> (text: [String: String], bools: [String: Bool]) {
    var text: [String: String] = [:]
    var bools: [String: Bool] = [:]
    for field in fields {
      if field.kind == .string, !field.allowedValues.isEmpty {
        if case .string(let value)? = field.defaultValue, field.allowedValues.contains(value) {
          text[field.name] = value
        } else if field.isRequired {
          text[field.name] = field.allowedValues.first
        } else {
          text[field.name] = ""
        }
        continue
      }
      switch (field.kind, field.defaultValue) {
      case (.boolean, .bool(let value)):
        bools[field.name] = value
      case (.string, .string(let value)):
        text[field.name] = value
      case (.integer, .number(let value)), (.number, .number(let value)):
        if let exact = Int(exactly: value) {
          text[field.name] = String(exact)
        } else if value.isFinite {
          text[field.name] = String(value)
        }
      case (.stringArray, .array(let values)):
        text[field.name] = values.compactMap {
          if case .string(let value) = $0 { return value }
          return nil
        }.joined(separator: ", ")
      default:
        if field.kind == .boolean { bools[field.name] = false }
      }
    }
    return (text, bools)
  }

  static func canSubmit(
    mode: MCPElicitationMode,
    url: URL?,
    fields: [MCPElicitationField],
    textValues: [String: String]
  ) -> Bool {
    guard mode == .form else { return url != nil }
    for field in fields {
      let storedValue = textValues[field.name] ?? ""
      if field.kind == .string, !field.allowedValues.isEmpty {
        if storedValue.isEmpty {
          if field.isRequired { return false }
          continue
        }
        guard field.allowedValues.contains(storedValue) else { return false }
        continue
      }
      let raw = storedValue.trimmingCharacters(in: .whitespacesAndNewlines)
      switch field.kind {
      case .boolean:
        continue
      case .string:
        if field.isRequired, raw.isEmpty { return false }
      case .integer:
        if raw.isEmpty {
          if field.isRequired { return false }
          continue
        }
        guard Int(raw) != nil else { return false }
      case .number:
        if raw.isEmpty {
          if field.isRequired { return false }
          continue
        }
        guard let value = Double(raw), value.isFinite else { return false }
      case .stringArray:
        let items = parseStringArray(raw)
        if items.isEmpty {
          if field.isRequired { return false }
          continue
        }
        if !field.allowedValues.isEmpty,
          !items.allSatisfy(field.allowedValues.contains)
        {
          return false
        }
      }
    }
    return true
  }

  static func responseContent(
    fields: [MCPElicitationField],
    textValues: [String: String],
    boolValues: [String: Bool]
  ) -> [String: JSONValue] {
    var values: [String: JSONValue] = [:]
    for field in fields {
      switch field.kind {
      case .boolean:
        values[field.name] = .bool(boolValues[field.name] ?? false)
      case .integer:
        let raw = (textValues[field.name] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let value = Int(raw) { values[field.name] = .number(Double(value)) }
      case .number:
        let raw = (textValues[field.name] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let value = Double(raw), value.isFinite { values[field.name] = .number(value) }
      case .string:
        let value = textValues[field.name] ?? ""
        if !field.allowedValues.isEmpty {
          if !value.isEmpty { values[field.name] = .string(value) }
        } else if !value.isEmpty || field.isRequired {
          values[field.name] = .string(value)
        }
      case .stringArray:
        let items = parseStringArray(textValues[field.name] ?? "")
        if !items.isEmpty || field.isRequired {
          values[field.name] = .array(items.map(JSONValue.string))
        }
      }
    }
    return values
  }

  static func parseStringArray(_ raw: String) -> [String] {
    raw
      .split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }
}

private struct MacMCPElicitationCard: View {
  let request: MCPElicitationRequest
  let resolve: (MCPElicitationDecision) -> Void

  @State private var textValues: [String: String]
  @State private var boolValues: [String: Bool]
  @State private var isResolving = false

  init(request: MCPElicitationRequest, resolve: @escaping (MCPElicitationDecision) -> Void) {
    self.request = request
    self.resolve = resolve
    let initial = MacMCPElicitationFormSupport.initialValues(for: request.fields)
    _textValues = State(initialValue: initial.text)
    _boolValues = State(initialValue: initial.bools)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label("\(request.serverName) needs input", systemImage: "text.bubble")
        .font(.system(size: 14, weight: .semibold))
      Text(request.message)
        .font(.system(size: 13))
        .fixedSize(horizontal: false, vertical: true)

      switch request.mode {
      case .form:
        formFields
        if !canSubmit && !isResolving {
          Text("Complete all required fields with valid values to continue.")
            .font(.caption2)
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
        }
      case .url:
        if let url = request.url {
          VStack(alignment: .leading, spacing: 8) {
            Text("Complete the requested step in your browser, then return to BYOKchat.")
              .font(.caption)
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
            Text(url.host ?? url.absoluteString)
              .font(.subheadline.weight(.semibold))
              .foregroundStyle(MacDesignTokens.Colors.textPrimary)
            Text(url.absoluteString)
              .font(.caption)
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
              .lineLimit(3)
              .truncationMode(.middle)
              .textSelection(.enabled)
            Link(destination: url) {
              Label("Open \(url.host ?? url.absoluteString)", systemImage: "arrow.up.right.square")
            }
            .buttonStyle(.borderedProminent)
          }
        }
      }

      if isResolving {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text("Submitting…")
            .font(.caption.weight(.medium))
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
        }
        .padding(.top, 2)
      } else {
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 8) {
            cancelButton
            declineButton
            Spacer()
            submitButton
          }
          VStack(alignment: .trailing, spacing: 8) {
            HStack(spacing: 8) {
              cancelButton
              declineButton
            }
            submitButton
          }
          .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .controlSize(.small)
        .disabled(isResolving)
      }
    }
    .padding(14)
    .background(MacDesignTokens.Colors.surface, in: RoundedRectangle(cornerRadius: MacDesignTokens.Radius.large))
    .overlay {
      RoundedRectangle(cornerRadius: MacDesignTokens.Radius.large)
        .stroke(MacDesignTokens.Colors.separator, lineWidth: 1)
    }
  }

  private func submitDecision(_ decision: MCPElicitationDecision) {
    guard !isResolving else { return }
    isResolving = true
    resolve(decision)
  }

  private var cancelButton: some View {
    Button("Cancel") { submitDecision(.cancel) }
      .buttonStyle(.bordered)
  }

  private var declineButton: some View {
    Button("Decline", role: .destructive) { submitDecision(.decline) }
      .buttonStyle(.bordered)
  }

  private var submitButton: some View {
    Button(request.mode == .url ? "Continue" : "Submit") {
      submitDecision(.accept(responseContent()))
    }
    .buttonStyle(.borderedProminent)
    .disabled(!canSubmit || isResolving)
  }

  @ViewBuilder
  private var formFields: some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach(request.fields) { field in
        VStack(alignment: .leading, spacing: 4) {
          switch field.kind {
          case .boolean:
            Toggle(
              field.displayName,
              isOn: Binding(
                get: { boolValues[field.name] ?? false },
                set: { boolValues[field.name] = $0 }
              )
            )
          case .string where !field.allowedValues.isEmpty:
            Picker(
              field.displayName,
              selection: Binding(
                get: { textValues[field.name] ?? "" },
                set: { textValues[field.name] = $0 }
              )
            ) {
              if !field.isRequired {
                Text("None").tag("")
              }
              ForEach(field.allowedValues, id: \.self) { value in Text(value).tag(value) }
            }
          default:
            TextField(
              field.isRequired ? field.displayName : "\(field.displayName) (optional)",
              text: Binding(
                get: { textValues[field.name] ?? "" },
                set: { textValues[field.name] = $0 }
              )
            )
            if field.kind == .stringArray, !field.allowedValues.isEmpty {
              Text("Allowed: \(field.allowedValues.joined(separator: ", "))")
                .font(.caption2)
                .foregroundStyle(MacDesignTokens.Colors.textMuted)
            }
          }

          if let description = field.description, !description.isEmpty {
            Text(description)
              .font(.caption2)
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
          }
        }
      }
    }
    .disabled(isResolving)
  }

  private var canSubmit: Bool {
    MacMCPElicitationFormSupport.canSubmit(
      mode: request.mode,
      url: request.url,
      fields: request.fields,
      textValues: textValues
    )
  }

  private func responseContent() -> [String: JSONValue] {
    MacMCPElicitationFormSupport.responseContent(
      fields: request.fields,
      textValues: textValues,
      boolValues: boolValues
    )
  }
}

private struct MacMCPToolRunningCard: View {
  let call: ChatToolCall
  let displayName: String
  let waitingForApproval: Bool

  var body: some View {
    DisclosureGroup {
      Text(call.arguments.macPrettyJSONString())
        .font(.system(size: 11, design: .monospaced))
        .textSelection(.enabled)
        .padding(.top, 6)
    } label: {
      HStack(spacing: 8) {
        ProgressView().controlSize(.mini)
        Text(displayName)
          .font(.system(size: 12, weight: .semibold))
        Spacer()
        Text(waitingForApproval ? "Waiting for approval" : "Tool requested")
          .font(.caption2)
          .foregroundStyle(MacDesignTokens.Colors.textMuted)
      }
    }
    .padding(11)
    .background(MacDesignTokens.Colors.surface, in: RoundedRectangle(cornerRadius: MacDesignTokens.Radius.large))
    .overlay {
      RoundedRectangle(cornerRadius: MacDesignTokens.Radius.large)
        .stroke(MacDesignTokens.Colors.separator, lineWidth: 1)
    }
  }
}

struct MacToolRoundsView: View {
  let rounds: [ChatToolRound]
  let displayName: (String) -> String

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(rounds) { round in
        ForEach(round.calls) { call in
          let result = round.results.first { $0.callID == call.id }
          MacToolResultCard(call: call, result: result, displayName: displayName(call.name))
        }
      }
    }
  }
}

private struct MacToolResultCard: View {
  let call: ChatToolCall
  let result: ChatToolResult?
  let displayName: String

  private var failed: Bool { result?.isError == true || result == nil }

  var body: some View {
    DisclosureGroup {
      VStack(alignment: .leading, spacing: 10) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Arguments").font(.caption.weight(.semibold))
          Text(call.arguments.macPrettyJSONString())
            .font(.system(size: 11, design: .monospaced))
            .textSelection(.enabled)
        }
        if let result {
          VStack(alignment: .leading, spacing: 4) {
            Text(result.isError ? "Error" : "Result")
              .font(.caption.weight(.semibold))
            Text(result.content.macPrettyJSONString())
              .font(.system(size: 11, design: .monospaced))
              .textSelection(.enabled)
          }
        } else {
          Text("No tool result was persisted. The tool round was interrupted or failed before completion.")
            .font(.caption)
            .foregroundStyle(.orange)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.top, 6)
    } label: {
      HStack(spacing: 8) {
        Image(systemName: failed ? "xmark.circle.fill" : "checkmark.circle.fill")
          .foregroundStyle(failed ? Color.orange : MacDesignTokens.Colors.textMuted)
        Text(displayName)
          .font(.system(size: 12, weight: .semibold))
          .lineLimit(2)
        Spacer()
        Text(failed ? "Failed" : "Done")
          .font(.caption2)
          .foregroundStyle(MacDesignTokens.Colors.textMuted)
      }
    }
    .padding(.horizontal, 11)
    .padding(.vertical, 9)
    .background(MacDesignTokens.Colors.surface, in: RoundedRectangle(cornerRadius: MacDesignTokens.Radius.large))
    .overlay {
      RoundedRectangle(cornerRadius: MacDesignTokens.Radius.large)
        .stroke(MacDesignTokens.Colors.separator, lineWidth: 1)
    }
  }
}

extension JSONValue {
  func macPrettyJSONString() -> String {
    if case .string(let value) = self { return value }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let encoded = try? encoder.encode(self),
      let object = try? JSONSerialization.jsonObject(with: encoded),
      JSONSerialization.isValidJSONObject(object),
      let pretty = try? JSONSerialization.data(
        withJSONObject: object,
        options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      ),
      let value = String(data: pretty, encoding: .utf8)
    else {
      return String(describing: self)
    }
    return value
  }
}
