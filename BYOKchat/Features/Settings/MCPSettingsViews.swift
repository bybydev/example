import AppFoundation
import BYOKchatProviderCore
import SwiftUI

nonisolated func mcpToolCountLabel(_ count: Int) -> String {
  count == 1 ? "1 tool" : "\(count) tools"
}

nonisolated enum MCPServerFormSupport {
  static func parseHeaders(_ value: String) throws -> [String: String] {
    var headers: [String: String] = [:]
    var seenNames: Set<String> = []
    for rawLine in value.split(whereSeparator: \.isNewline) {
      let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
      guard !line.isEmpty else { continue }
      guard let separator = line.firstIndex(of: ":") else {
        throw MCPError.invalidServer("Each additional header must use Name: Value.")
      }
      let name = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
      let headerValue = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
      guard !name.isEmpty, !headerValue.isEmpty else {
        throw MCPError.invalidServer("Each additional header needs both a name and value.")
      }
      guard seenNames.insert(name.lowercased()).inserted else {
        throw MCPError.invalidServer("Duplicate additional header: \(name)")
      }
      headers[name] = headerValue
    }
    return headers
  }
}

struct MCPServerListView: View {
  @Bindable var model: MCPManagementModel
  /// Set when the list renders as the app's main screen (sidebar MCP Servers
  /// destination), showing a leading sidebar-hamburger button. Left nil when
  /// pushed onto an existing stack, where the system back button applies.
  var openSidebar: (() -> Void)? = nil

  @Environment(PurchaseManager.self) private var purchaseManager
  @Environment(\.appFoundationTheme) private var theme
  @State private var showAddServer = false
  @State private var showProUpsell = false
  @State private var pendingDelete: MCPRemoteServer?
  @State private var errorPresenterID = UUID()

  var body: some View {
    VStack(spacing: 0) {
      if let warning = model.warningMessage {
        HStack(alignment: .top, spacing: 12) {
          Label(warning, systemImage: "exclamationmark.triangle")
            .font(.footnote)
            .fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 0)
          Button("Dismiss warning", systemImage: "xmark") {
            model.warningMessage = nil
          }
          .labelStyle(.iconOnly)
        }
        .padding()
        .background(theme.surfaceColor)
      }
      Group {
        if model.servers.isEmpty {
          ContentUnavailableView {
            Label("No MCP Servers", systemImage: "shippingbox.and.arrow.backward")
          } description: {
            Text("Add a remote Streamable HTTP MCP endpoint to discover its tools.")
          } actions: {
            Button("Add MCP Server", action: requestAddServer)
              .buttonStyle(.borderedProminent)
              .disabled(model.isBusy)
          }
        } else {
          serverList
        }
      }
    }
    .scrollContentBackground(.hidden)
    .foregroundStyle(theme.primaryForegroundColor)
    .background(AppThemeBackground(theme: theme))
    .navigationTitle("MCP Servers")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      if let openSidebar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Open Sidebar", systemImage: "text.alignleft", action: openSidebar)
            .labelStyle(.iconOnly)
            .accessibilityLabel("Open sidebar")
        }
      }
      ToolbarItem(placement: .topBarTrailing) {
        Button("Add MCP Server", systemImage: "plus", action: requestAddServer)
          .disabled(model.isBusy)
      }
    }
    .sheet(isPresented: $showAddServer) {
      NavigationStack {
        MCPServerEditorView(model: model, server: nil)
      }
    }
    .sheet(isPresented: $showProUpsell) {
      BYOKProUpsellFlow(feature: .mcpServers)
    }
    .alert(
      "MCP Error",
      isPresented: Binding(
        get: { model.shouldPresentError(in: errorPresenterID) },
        set: { if !$0, model.shouldPresentError(in: errorPresenterID) { model.errorMessage = nil } }
      )
    ) {
      Button("OK") { model.errorMessage = nil }
    } message: {
      Text(model.errorMessage ?? "Unknown error")
    }
    .onAppear { model.registerErrorPresenter(errorPresenterID) }
    .onDisappear { model.unregisterErrorPresenter(errorPresenterID) }
    .confirmationDialog(
      "Delete MCP server?",
      isPresented: Binding(
        get: { pendingDelete != nil },
        set: { if !$0 { pendingDelete = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("Delete", role: .destructive) {
        guard let server = pendingDelete else { return }
        pendingDelete = nil
        Task { await model.deleteServer(server.id) }
      }
      Button("Cancel", role: .cancel) { pendingDelete = nil }
    } message: {
      Text("The server configuration, cached tool catalog, chat selections, and its Keychain credential will be removed.")
    }
  }

  private func requestAddServer() {
    if BYOKProAccess.canCreateMCPServer(
      currentCount: model.servers.count,
      hasPro: purchaseManager.hasPro
    ) {
      showAddServer = true
    } else {
      showProUpsell = true
    }
  }

  private var serverList: some View {
    List {
      ForEach(model.servers) { server in
        NavigationLink {
          MCPServerEditorView(model: model, server: server)
        } label: {
          serverRow(server)
        }
        .swipeActions(edge: .leading) {
          if server.isEnabled {
            Button("Refresh", systemImage: "arrow.clockwise") {
              Task { await model.refresh(server.id) }
            }
            .tint(.accentColor)
          }
        }
        .swipeActions(edge: .trailing) {
          Button("Delete", systemImage: "trash", role: .destructive) {
            pendingDelete = server
          }
        }
        .contextMenu {
          if server.isEnabled {
            Button("Refresh Tools", systemImage: "arrow.clockwise") {
              Task { await model.refresh(server.id) }
            }
          }
          Button(
            server.isEnabled ? "Disable" : "Enable",
            systemImage: server.isEnabled ? "pause.circle" : "play.circle"
          ) {
            Task { await model.setEnabled(!server.isEnabled, serverID: server.id) }
          }
          Divider()
          Button("Delete", systemImage: "trash", role: .destructive) {
            pendingDelete = server
          }
        }
      }
      .listRowBackground(Color.clear)
    }
    .listStyle(.plain)
    .disabled(model.isBusy)
    .listRowSeparatorTint(theme.borderColor)
  }

  @ViewBuilder
  private func serverRow(_ server: MCPRemoteServer) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 8) {
        Text(server.name)
          .font(.body.weight(.medium))
        if !server.isEnabled {
          Text("Disabled")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.orange)
        }
        Spacer()
        if let snapshot = model.snapshot(for: server.id) {
          Text(mcpToolCountLabel(snapshot.tools.count))
            .font(.caption)
            .foregroundStyle(theme.secondaryForegroundColor)
        } else if server.isEnabled {
          Text("Not discovered")
            .font(.caption)
            .foregroundStyle(theme.secondaryForegroundColor)
        }
      }
      Text(server.endpoint.absoluteString)
        .font(.caption)
        .foregroundStyle(theme.secondaryForegroundColor)
        .lineLimit(1)
      if let snapshot = model.snapshot(for: server.id) {
        Text(statusText(snapshot))
          .font(.caption2)
          .foregroundStyle(theme.secondaryForegroundColor.opacity(0.72))
      }
    }
    .padding(.vertical, 3)
  }

  private func statusText(_ snapshot: MCPServerSnapshot) -> String {
    let era = snapshot.era == .modern ? "Modern" : "Legacy"
    if let info = snapshot.serverInfo {
      return "\(era) · MCP \(snapshot.protocolVersion) · \(info.name) \(info.version)"
    }
    return "\(era) · MCP \(snapshot.protocolVersion)"
  }
}

private struct MCPServerEditorView: View {
  @Bindable var model: MCPManagementModel
  let server: MCPRemoteServer?

  @Environment(\.dismiss) private var dismiss
  @Environment(\.appFoundationTheme) private var theme
  @State private var name: String
  @State private var endpoint: String
  @State private var authenticationKind: MCPAuthenticationKind
  @State private var authenticationHeader: String
  @State private var credential = ""
  @State private var additionalHeadersText: String
  @State private var isEnabled: Bool
  @State private var headerError: String?
  @State private var errorPresenterID = UUID()

  private let initialAdditionalHeadersText: String

  init(model: MCPManagementModel, server: MCPRemoteServer?) {
    self.model = model
    self.server = server
    let formattedHeaders = server?.additionalHeaders
      .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
      .map { "\($0.key): \($0.value)" }
      .joined(separator: "\n") ?? ""
    initialAdditionalHeadersText = formattedHeaders
    _name = State(initialValue: server?.name ?? "")
    _endpoint = State(initialValue: server?.endpoint.absoluteString ?? "https://")
    _authenticationKind = State(initialValue: server?.authentication.kind ?? .none)
    _authenticationHeader = State(initialValue: server?.authentication.headerName ?? "X-API-Key")
    _additionalHeadersText = State(initialValue: formattedHeaders)
    _isEnabled = State(initialValue: server?.isEnabled ?? true)
  }

  private var hasConnectionChanges: Bool {
    guard let server else {
      return endpoint.trimmingCharacters(in: .whitespacesAndNewlines) != "https://"
        || authenticationKind != .none
        || !credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !additionalHeadersText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    let trimmedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedHeader = authenticationHeader.trimmingCharacters(in: .whitespacesAndNewlines)
    let headerChanged = authenticationKind == .customHeader
      && trimmedHeader != (server.authentication.headerName ?? "")
    return trimmedEndpoint != server.endpoint.absoluteString
      || authenticationKind != server.authentication.kind
      || headerChanged
      || !credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || additionalHeadersText != initialAdditionalHeadersText
  }

  private var hasUnsavedChanges: Bool {
    guard let server else {
      return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !isEnabled
        || hasConnectionChanges
    }
    return name.trimmingCharacters(in: .whitespacesAndNewlines) != server.name
      || isEnabled != server.isEnabled
      || hasConnectionChanges
  }

  private var shouldDiscoverAfterSave: Bool {
    guard isEnabled else { return false }
    guard let server else { return true }
    return hasConnectionChanges || !server.isEnabled || model.snapshot(for: server.id) == nil
  }

  var body: some View {
    Form {
      serverSection
      authenticationSection
      additionalHeadersSection
      if let server {
        discoverySection(server)
        discoveredToolsSection(server)
      }
      usageNoteSection
    }
    .scrollContentBackground(.hidden)
    .foregroundStyle(theme.primaryForegroundColor)
    .background(AppThemeBackground(theme: theme))
    .navigationTitle(server == nil ? "Add MCP Server" : "MCP Server")
    .navigationBarTitleDisplayMode(.inline)
    .interactiveDismissDisabled(server == nil && (hasUnsavedChanges || model.isBusy))
    .onChange(of: additionalHeadersText) { _, _ in
      if headerError != nil { headerError = nil }
    }
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        if server == nil {
          Button("Cancel") { dismiss() }
        }
      }
      ToolbarItem(placement: .confirmationAction) {
        Button("Save") { save() }
          .disabled(model.isBusy)
      }
    }
    .alert(
      "MCP Error",
      isPresented: Binding(
        get: { model.shouldPresentError(in: errorPresenterID) },
        set: { if !$0, model.shouldPresentError(in: errorPresenterID) { model.errorMessage = nil } }
      )
    ) {
      Button("OK") { model.errorMessage = nil }
    } message: {
      Text(model.errorMessage ?? "Unknown error")
    }
    .onAppear { model.registerErrorPresenter(errorPresenterID) }
    .onDisappear { model.unregisterErrorPresenter(errorPresenterID) }
  }

  private var serverSection: some View {
    Section("Server") {
      TextField("Name", text: $name)
      TextField("https://example.com/mcp", text: $endpoint)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .keyboardType(.URL)
      Toggle("Enabled", isOn: $isEnabled)
    }
    .listRowBackground(theme.surfaceColor)
  }

  private var authenticationSection: some View {
    Section {
      Picker("Authentication", selection: $authenticationKind) {
        Text("None").tag(MCPAuthenticationKind.none)
        Text("Bearer Token").tag(MCPAuthenticationKind.bearer)
        Text("Custom Header").tag(MCPAuthenticationKind.customHeader)
      }

      if authenticationKind == .customHeader {
        TextField("Header name", text: $authenticationHeader)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
      }

      if authenticationKind != .none {
        let hasExistingCredential = server.map { model.hasCredential($0.id) } ?? false
        SecureField(
          hasExistingCredential
            ? "Leave blank to keep current credential"
            : "Credential",
          text: $credential
        )
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
      }
    } header: {
      Text("Authentication")
        .foregroundStyle(theme.secondaryForegroundColor)
    } footer: {
      Text("Credentials are stored in Keychain and are never written to the MCP server configuration file.")
        .foregroundStyle(theme.secondaryForegroundColor)
    }
    .listRowBackground(theme.surfaceColor)
  }

  private var additionalHeadersSection: some View {
    Section {
      TextEditor(text: $additionalHeadersText)
        .font(.system(.body, design: .monospaced))
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .frame(minHeight: 90)
      if let headerError {
        Text(headerError)
          .font(.footnote)
          .foregroundStyle(.red)
      }
    } header: {
      Text("Additional Headers")
        .foregroundStyle(theme.secondaryForegroundColor)
    } footer: {
      Text("Optional non-secret headers, one per line as Name: Value. Authentication and MCP protocol headers are managed by BYOKchat.")
        .foregroundStyle(theme.secondaryForegroundColor)
    }
    .listRowBackground(theme.surfaceColor)
  }

  private func discoverySection(_ server: MCPRemoteServer) -> some View {
    Section("Discovery") {
      if let snapshot = model.snapshot(for: server.id) {
        LabeledContent("Protocol", value: snapshot.protocolVersion)
        LabeledContent("Mode", value: snapshot.era == .modern ? "Modern" : "Legacy fallback")
        LabeledContent("Tools", value: "\(snapshot.tools.count)")
        if let info = snapshot.serverInfo {
          LabeledContent("Server", value: "\(info.name) \(info.version)")
        }
        LabeledContent(
          "Refreshed",
          value: snapshot.refreshedAt.formatted(date: .abbreviated, time: .shortened)
        )
        if !snapshot.warnings.isEmpty {
          ForEach(snapshot.warnings, id: \.self) { warning in
            Label(warning, systemImage: "exclamationmark.triangle")
              .font(.footnote)
              .foregroundStyle(theme.secondaryForegroundColor)
          }
        }
      } else {
        Text("Not discovered yet.")
          .foregroundStyle(theme.secondaryForegroundColor)
      }

      Button("Refresh Tools", systemImage: "arrow.clockwise") {
        Task { await model.refresh(server.id) }
      }
      .disabled(model.isBusy || hasConnectionChanges)

      if hasConnectionChanges {
        Text("Save changes before refreshing tools.")
          .font(.caption)
          .foregroundStyle(theme.secondaryForegroundColor)
      }
    }
    .listRowBackground(theme.surfaceColor)
  }

  @ViewBuilder
  private func discoveredToolsSection(_ server: MCPRemoteServer) -> some View {
    if let tools = model.snapshot(for: server.id)?.tools, !tools.isEmpty {
      Section("Discovered Tools") {
        ForEach(tools) { tool in
          VStack(alignment: .leading, spacing: 3) {
            Text(tool.title ?? tool.remoteName)
              .font(.body.weight(.medium))
            if tool.title != nil {
              Text(tool.remoteName)
                .font(.caption.monospaced())
                .foregroundStyle(theme.secondaryForegroundColor)
            }
            Text(tool.description)
              .font(.caption)
              .foregroundStyle(theme.secondaryForegroundColor)
              .lineLimit(3)
          }
          .padding(.vertical, 2)
        }
      }
      .listRowBackground(theme.surfaceColor)
    }
  }

  private var usageNoteSection: some View {
    Section {
      Text("Enable this server globally here, then choose which chats can use it from Chat → Tools. Each tool can Ask, Always Allow, or stay Disabled.")
        .font(.footnote)
        .foregroundStyle(theme.secondaryForegroundColor)
    }
    .listRowBackground(theme.surfaceColor)
  }

  private func save() {
    let headers: [String: String]
    do {
      headers = try MCPServerFormSupport.parseHeaders(additionalHeadersText)
      headerError = nil
    } catch {
      headerError = error.localizedDescription
      return
    }

    let shouldDiscover = shouldDiscoverAfterSave
    Task { @MainActor in
      let trimmedCredential = credential.trimmingCharacters(in: .whitespacesAndNewlines)
      let newCredential: String?
      if authenticationKind == .none {
        newCredential = ""
      } else if trimmedCredential.isEmpty, server != nil {
        newCredential = nil
      } else {
        newCredential = trimmedCredential
      }
      let saved = await model.saveServer(
        existing: server,
        name: name,
        endpoint: endpoint,
        authenticationKind: authenticationKind,
        authenticationHeader: authenticationHeader,
        credential: newCredential,
        additionalHeaders: headers,
        isEnabled: isEnabled
      )
      if let saved {
        dismiss()
        if shouldDiscover {
          await model.discoverSavedServer(saved)
        }
      }
    }
  }
}
