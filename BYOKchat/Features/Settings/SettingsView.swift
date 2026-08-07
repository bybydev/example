import AppFoundation
import BYOKchatProviderCore
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
  @Bindable var model: AppModel

  @Environment(\.appFoundationTheme) private var theme
  @State private var backupDocument: JSONExportDocument?
  @State private var providerDocument: JSONExportDocument?
  @State private var showBackupExporter = false
  @State private var showProviderExporter = false
  @State private var showImporter = false
  @State private var showImportStrategy = false
  @State private var importKind: ImportKind = .backup
  @State private var importStrategy: ProviderImportStrategy = .keepExisting
  @State private var confirmDeleteConversations = false
  @State private var confirmDeleteCredentials = false

  private enum ImportKind {
    case backup
    case providers
  }

  var body: some View {
    failureAlertView
  }

  private var navigationContent: some View {
    NavigationStack {
      settingsForm
        .navigationTitle("Settings")
    }
  }

  private var importConfiguredView: some View {
    navigationContent
      .confirmationDialog(
        "How should imported data be applied?",
        isPresented: $showImportStrategy
      ) {
        Button("Merge, Keep Existing") {
          importStrategy = .keepExisting
          showImporter = true
        }
        Button("Replace Existing", role: .destructive) {
          importStrategy = .replaceExisting
          showImporter = true
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text(
          "Replace removes matching local configuration. Imported credentials must be entered again."
        )
      }
      .fileImporter(
        isPresented: $showImporter,
        allowedContentTypes: [.json],
        allowsMultipleSelection: false,
        onCompletion: handleImportResult
      )
  }

  private var exportConfiguredView: some View {
    importConfiguredView
      .fileExporter(
        isPresented: $showBackupExporter,
        document: backupDocument,
        contentType: .json,
        defaultFilename: "BYOKchat-backup",
        onCompletion: handleExportResult
      )
      .fileExporter(
        isPresented: $showProviderExporter,
        document: providerDocument,
        contentType: .json,
        defaultFilename: "BYOKchat-providers",
        onCompletion: handleExportResult
      )
  }

  private var deletionConfiguredView: some View {
    exportConfiguredView
      .alert("Delete all conversations?", isPresented: $confirmDeleteConversations) {
        Button("Cancel", role: .cancel) {}
        Button("Delete", role: .destructive) {
          Task { await model.dataPortability.deleteAllConversations() }
        }
      } message: {
        Text("This removes every locally stored conversation and cannot be undone without a backup.")
      }
      .alert("Delete all credentials?", isPresented: $confirmDeleteCredentials) {
        Button("Cancel", role: .cancel) {}
        Button("Delete", role: .destructive) {
          Task { await model.dataPortability.deleteAllCredentials() }
        }
      } message: {
        Text("Provider accounts remain configured, but every API key and MCP credential must be entered again.")
      }
  }

  private var failureAlertView: some View {
    deletionConfiguredView
      .alert(
        "Data Operation Failed",
        isPresented: Binding(
          get: { model.dataPortability.errorMessage != nil },
          set: { if !$0 { model.dataPortability.errorMessage = nil } }
        )
      ) {
        Button("OK") { model.dataPortability.errorMessage = nil }
      } message: {
        Text(model.dataPortability.errorMessage ?? "Unknown error")
      }
  }

  private var settingsForm: some View {
    Form {
      Section("Appearance") {
        ThemePickerView(
          manager: model.themeManager,
          title: nil,
          showsCountdown: false
        ) { candidate in
          ChatThemePreview(theme: candidate)
        }
      }

      Section("AI Providers") {
        NavigationLink {
          ProviderListView(model: model.providers)
        } label: {
          Label("Providers & Accounts", systemImage: "key.horizontal")
        }

        NavigationLink {
          ProviderConsoleView(model: model.providers)
        } label: {
          Label("Provider Console", systemImage: "terminal")
        }
      }

      Section("Tools & MCP") {
        NavigationLink {
          MCPServerListView(model: model.mcp)
        } label: {
          Label("MCP Servers", systemImage: "shippingbox.and.arrow.backward")
        }
      }

      Section("New Chats") {
        NavigationLink {
          DefaultSystemPromptView(preferences: model.preferences)
        } label: {
          LabeledContent("Default System Prompt") {
            Text(model.preferences.defaultSystemPrompt.isEmpty ? "None" : "Configured")
              .foregroundStyle(.secondary)
          }
        }
      }

      Section {
        Button("Export Full Backup", systemImage: "archivebox") {
          exportBackup()
        }

        Button("Import Full Backup", systemImage: "square.and.arrow.down") {
          importKind = .backup
          showImportStrategy = true
        }

        Button("Export Provider Configuration", systemImage: "key.viewfinder") {
          exportProviderConfiguration()
        }

        Button("Import Provider Configuration", systemImage: "key.radiowaves.forward") {
          importKind = .providers
          showImportStrategy = true
        }
      } header: {
        Text("Data Portability")
      } footer: {
        Text("Backups and provider configuration never include API keys or secret headers.")
      }

      Section("Destructive Actions") {
        Button("Delete All Conversations", systemImage: "trash", role: .destructive) {
          confirmDeleteConversations = true
        }
        Button("Delete All Credentials", systemImage: "key.slash", role: .destructive) {
          confirmDeleteCredentials = true
        }
      }

      if let status = model.dataPortability.statusMessage {
        Section("Last Data Operation") {
          Text(status)
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }

      Section("About") {
        LabeledContent("Storage", value: "Local on this iPhone")
        LabeledContent("Credentials", value: "Keychain")
        Text("Requests go directly to the provider account or remote MCP endpoint selected by the app.")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
    }
    .scrollContentBackground(.hidden)
    .background(theme.backgroundColor)
  }

  private func exportBackup() {
    Task { @MainActor in
      guard let document = await model.dataPortability.makeBackupDocument() else { return }
      backupDocument = document
      showBackupExporter = true
    }
  }

  private func exportProviderConfiguration() {
    Task { @MainActor in
      guard let document = await model.dataPortability.makeProviderConfigurationDocument() else {
        return
      }
      providerDocument = document
      showProviderExporter = true
    }
  }

  private func handleImportResult(_ result: Result<[URL], any Error>) {
    guard case .success(let urls) = result, let url = urls.first else {
      if case .failure(let error) = result {
        model.dataPortability.errorMessage = error.localizedDescription
      }
      return
    }

    Task { @MainActor in
      switch importKind {
      case .backup:
        await model.dataPortability.importBackup(from: url, strategy: importStrategy)
      case .providers:
        await model.dataPortability.importProviderConfiguration(
          from: url,
          strategy: importStrategy
        )
      }
    }
  }

  private func handleExportResult(_ result: Result<URL, any Error>) {
    if case .failure(let error) = result {
      model.dataPortability.errorMessage = error.localizedDescription
    }
  }
}

private struct ChatThemePreview: View {
  let theme: AppTheme

  var body: some View {
    ZStack {
      theme.backgroundColor

      VStack(alignment: .leading, spacing: 7) {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
          .fill(theme.secondaryForegroundColor.opacity(0.26))
          .frame(width: 54, height: 6)

        HStack {
          Spacer()
          RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(theme.elevatedSurfaceColor)
            .frame(width: 64, height: 22)
        }

        RoundedRectangle(cornerRadius: 5, style: .continuous)
          .fill(theme.accentColor.opacity(0.72))
          .frame(width: 74, height: 6)
      }
      .padding(12)
    }
  }
}

private struct DefaultSystemPromptView: View {
  @Bindable var preferences: AppPreferencesModel
  @State private var text: String

  init(preferences: AppPreferencesModel) {
    self.preferences = preferences
    _text = State(initialValue: preferences.defaultSystemPrompt)
  }

  var body: some View {
    Form {
      Section {
        TextEditor(text: $text)
          .frame(minHeight: 220)
      } footer: {
        Text("This prompt is copied into new conversations. Existing conversations are unchanged.")
      }

      Section {
        Button("Clear", role: .destructive) { text = "" }
      }
    }
    .navigationTitle("Default Prompt")
    .navigationBarTitleDisplayMode(.inline)
    .onChange(of: text) { _, value in preferences.defaultSystemPrompt = value }
  }
}

struct MCPServerListView: View {
  @Bindable var model: MCPManagementModel
  @State private var showAddServer = false
  @State private var pendingDelete: MCPRemoteServer?

  var body: some View {
    List {
      if model.servers.isEmpty {
        ContentUnavailableView(
          "No MCP Servers",
          systemImage: "shippingbox.and.arrow.backward",
          description: Text("Add a remote Streamable HTTP MCP endpoint to discover its tools.")
        )
      } else {
        ForEach(model.servers) { server in
          NavigationLink {
            MCPServerEditorView(model: model, server: server)
          } label: {
            serverRow(server)
          }
          .swipeActions(edge: .trailing) {
            Button("Delete", systemImage: "trash", role: .destructive) {
              pendingDelete = server
            }
          }
        }
      }
    }
    .navigationTitle("MCP Servers")
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button("Add MCP Server", systemImage: "plus") {
          showAddServer = true
        }
      }
    }
    .sheet(isPresented: $showAddServer) {
      NavigationStack {
        MCPServerEditorView(model: model, server: nil)
      }
    }
    .alert(
      "MCP Error",
      isPresented: Binding(
        get: { model.errorMessage != nil },
        set: { if !$0 { model.errorMessage = nil } }
      )
    ) {
      Button("OK") { model.errorMessage = nil }
    } message: {
      Text(model.errorMessage ?? "Unknown error")
    }
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

  @ViewBuilder
  private func serverRow(_ server: MCPRemoteServer) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 8) {
        Text(server.name)
          .font(.body.weight(.medium))
        if !server.isEnabled {
          Text("Disabled")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
        }
        Spacer()
        if let snapshot = model.snapshot(for: server.id) {
          Text("\(snapshot.tools.count) tools")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      Text(server.endpoint.absoluteString)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
      if let snapshot = model.snapshot(for: server.id) {
        Text(statusText(snapshot))
          .font(.caption2)
          .foregroundStyle(.tertiary)
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
  @State private var name: String
  @State private var endpoint: String
  @State private var authenticationKind: MCPAuthenticationKind
  @State private var authenticationHeader: String
  @State private var credential = ""
  @State private var additionalHeadersText: String
  @State private var isEnabled: Bool
  @State private var headerError: String?

  init(model: MCPManagementModel, server: MCPRemoteServer?) {
    self.model = model
    self.server = server
    _name = State(initialValue: server?.name ?? "")
    _endpoint = State(initialValue: server?.endpoint.absoluteString ?? "https://")
    _authenticationKind = State(initialValue: server?.authentication.kind ?? .none)
    _authenticationHeader = State(initialValue: server?.authentication.headerName ?? "X-API-Key")
    _additionalHeadersText = State(
      initialValue: server?.additionalHeaders
        .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
        .map { "\($0.key): \($0.value)" }
        .joined(separator: "\n") ?? ""
    )
    _isEnabled = State(initialValue: server?.isEnabled ?? true)
  }

  var body: some View {
    Form {
      Section("Server") {
        TextField("Name", text: $name)
        TextField("https://example.com/mcp", text: $endpoint)
          .textInputAutocapitalization(.never)
          .keyboardType(.URL)
        Toggle("Enabled", isOn: $isEnabled)
      }

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
          SecureField(
            server != nil && model.hasCredential(server!.id)
              ? "Leave blank to keep current credential"
              : "Credential",
            text: $credential
          )
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
        }
      } header: {
        Text("Authentication")
      } footer: {
        Text("Credentials are stored in Keychain and are never written to the MCP server configuration file.")
      }

      Section {
        TextEditor(text: $additionalHeadersText)
          .font(.system(.body, design: .monospaced))
          .frame(minHeight: 90)
        if let headerError {
          Text(headerError)
            .font(.footnote)
            .foregroundStyle(.red)
        }
      } header: {
        Text("Additional Headers")
      } footer: {
        Text("Optional non-secret headers, one per line as Name: Value. Authentication and MCP protocol headers are managed by BYOKchat.")
      }

      if let server {
        Section("Discovery") {
          if let snapshot = model.snapshot(for: server.id) {
            LabeledContent("Protocol", value: snapshot.protocolVersion)
            LabeledContent("Mode", value: snapshot.era == .modern ? "Modern" : "Legacy fallback")
            LabeledContent("Tools", value: "\(snapshot.tools.count)")
            if let info = snapshot.serverInfo {
              LabeledContent("Server", value: "\(info.name) \(info.version)")
            }
            if !snapshot.warnings.isEmpty {
              ForEach(snapshot.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                  .font(.footnote)
                  .foregroundStyle(.secondary)
              }
            }
          } else {
            Text("Not discovered yet.")
              .foregroundStyle(.secondary)
          }

          Button("Refresh Tools", systemImage: "arrow.clockwise") {
            Task { await model.refresh(server.id) }
          }
          .disabled(model.isBusy)
        }

        if let tools = model.snapshot(for: server.id)?.tools, !tools.isEmpty {
          Section("Discovered Tools") {
            ForEach(tools) { tool in
              VStack(alignment: .leading, spacing: 3) {
                Text(tool.title ?? tool.remoteName)
                  .font(.body.weight(.medium))
                if tool.title != nil {
                  Text(tool.remoteName)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                }
                Text(tool.description)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .lineLimit(3)
              }
              .padding(.vertical, 2)
            }
          }
        }
      }

      Section {
        Text("Enable this server globally here, then choose which chats can use it from Chat → Tools. Each tool can Ask, Always Allow, or stay Disabled.")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
    }
    .navigationTitle(server == nil ? "Add MCP Server" : "MCP Server")
    .navigationBarTitleDisplayMode(.inline)
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
  }

  private func save() {
    let headers: [String: String]
    do {
      headers = try parseHeaders(additionalHeadersText)
      headerError = nil
    } catch {
      headerError = error.localizedDescription
      return
    }

    Task { @MainActor in
      let newCredential: String?
      if authenticationKind == .none {
        newCredential = ""
      } else if credential.isEmpty, server != nil {
        newCredential = nil
      } else {
        newCredential = credential
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
      if saved { dismiss() }
    }
  }

  private func parseHeaders(_ value: String) throws -> [String: String] {
    var headers: [String: String] = [:]
    for rawLine in value.split(separator: "\n", omittingEmptySubsequences: true) {
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
      guard headers[name] == nil else {
        throw MCPError.invalidServer("Duplicate additional header: \(name)")
      }
      headers[name] = headerValue
    }
    return headers
  }
}
