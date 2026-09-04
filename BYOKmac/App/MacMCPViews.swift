import BYOKchatProviderCore
import SwiftUI

struct MacMCPServerListView: View {
  @Bindable var mcp: MacMCPModel

  @Environment(\.dismiss) private var dismiss
  @State private var showingAddServer = false
  @State private var editingServer: MCPRemoteServer?
  @State private var deleteServer: MCPRemoteServer?

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text("MCP Servers")
            .font(.headline)
          Text("Remote Streamable HTTP tool servers")
            .font(.caption)
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
        }
        Spacer()
        Button("Add Server", systemImage: "plus") { showingAddServer = true }
        Button("Done") { dismiss() }
          .keyboardShortcut(.cancelAction)
      }
      .padding(16)

      Divider()

      if mcp.servers.isEmpty {
        ContentUnavailableView(
          "No MCP Servers",
          systemImage: "shippingbox.and.arrow.backward",
          description: Text("Add a remote HTTPS MCP endpoint to discover tools.")
        )
      } else {
        List {
          ForEach(mcp.servers) { server in
            Button {
              editingServer = server
            } label: {
              serverRow(server)
            }
            .buttonStyle(.plain)
            .contextMenu {
              Button("Edit", systemImage: "pencil") { editingServer = server }
              Button("Refresh Tools", systemImage: "arrow.clockwise") {
                Task { _ = await mcp.refresh(server.id) }
              }
              Divider()
              Button("Delete", systemImage: "trash", role: .destructive) {
                deleteServer = server
              }
            }
          }
        }
        .listStyle(.inset)
      }
    }
    .frame(width: 720, height: 600)
    .background(MacDesignTokens.Colors.canvas)
    .sheet(isPresented: $showingAddServer) {
      MacMCPServerEditorView(mcp: mcp, server: nil)
    }
    .sheet(item: $editingServer) { server in
      MacMCPServerEditorView(mcp: mcp, server: server)
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
        Task { _ = await mcp.deleteServer(server.id) }
      }
      Button("Cancel", role: .cancel) { deleteServer = nil }
    } message: {
      Text("Its cached discovery data, chat selections, and Keychain credential will be removed.")
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

  private func serverRow(_ server: MCPRemoteServer) -> some View {
    HStack(spacing: 12) {
      Image(systemName: server.isEnabled ? "shippingbox.fill" : "shippingbox")
        .foregroundStyle(server.isEnabled ? MacDesignTokens.Colors.accent : MacDesignTokens.Colors.textMuted)
        .frame(width: 24)

      VStack(alignment: .leading, spacing: 4) {
        HStack {
          Text(server.name)
            .font(.system(size: 13.5, weight: .medium))
          if !server.isEnabled {
            Text("Disabled")
              .font(.caption2.weight(.semibold))
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
          }
        }
        Text(server.endpoint.absoluteString)
          .font(.caption)
          .foregroundStyle(MacDesignTokens.Colors.textMuted)
          .lineLimit(1)
        if let snapshot = mcp.snapshot(for: server.id) {
          Text(snapshotSummary(snapshot))
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
      }

      Spacer()

      if let snapshot = mcp.snapshot(for: server.id) {
        Text("\(snapshot.tools.count) tools")
          .font(.caption)
          .foregroundStyle(MacDesignTokens.Colors.textMuted)
      }

      Image(systemName: "chevron.right")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.tertiary)
    }
    .padding(.vertical, 5)
    .contentShape(Rectangle())
  }

  private func snapshotSummary(_ snapshot: MCPServerSnapshot) -> String {
    let mode = snapshot.era == .modern ? "Modern" : "Legacy"
    if let info = snapshot.serverInfo {
      return "\(mode) · MCP \(snapshot.protocolVersion) · \(info.name) \(info.version)"
    }
    return "\(mode) · MCP \(snapshot.protocolVersion)"
  }
}

private struct MacMCPServerEditorView: View {
  @Bindable var mcp: MacMCPModel
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
  @State private var isSaving = false

  init(mcp: MacMCPModel, server: MCPRemoteServer?) {
    self.mcp = mcp
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
    VStack(spacing: 0) {
      HStack {
        Text(server == nil ? "Add MCP Server" : "MCP Server")
          .font(.headline)
        Spacer()
        Button("Cancel") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Save") { save() }
          .keyboardShortcut(.defaultAction)
          .disabled(isSaving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
      .padding(16)

      Divider()

      Form {
        Section("Server") {
          TextField("Name", text: $name)
          TextField("Endpoint", text: $endpoint)
            .textFieldStyle(.roundedBorder)
          Toggle("Enabled", isOn: $isEnabled)
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

          Text("Credentials are stored in Keychain and never written into MCP configuration files.")
            .font(.caption)
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
        }

        Section("Additional Headers") {
          TextEditor(text: $additionalHeadersText)
            .font(.system(size: 12, design: .monospaced))
            .frame(minHeight: 90)
          if let headerError {
            Text(headerError)
              .font(.caption)
              .foregroundStyle(.red)
          }
          Text("Optional non-secret headers, one per line as Name: Value.")
            .font(.caption)
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
        }

        if let server {
          Section("Discovery") {
            if let snapshot = mcp.snapshot(for: server.id) {
              LabeledContent("Protocol", value: snapshot.protocolVersion)
              LabeledContent("Mode", value: snapshot.era == .modern ? "Modern" : "Legacy fallback")
              LabeledContent("Tools", value: snapshot.tools.count.formatted())
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
            } else {
              Text("Not discovered yet.")
                .foregroundStyle(MacDesignTokens.Colors.textMuted)
            }

            Button("Refresh Tools", systemImage: "arrow.clockwise") {
              Task { _ = await mcp.refresh(server.id) }
            }
            .disabled(mcp.isBusy)
          }

          if let tools = mcp.snapshot(for: server.id)?.tools, !tools.isEmpty {
            Section("Discovered Tools") {
              ForEach(tools) { tool in
                DisclosureGroup {
                  VStack(alignment: .leading, spacing: 8) {
                    Text(tool.description)
                    Text("Input Schema")
                      .font(.caption.weight(.semibold))
                    Text(tool.inputSchema.macPrettyJSONString())
                      .font(.system(size: 11, design: .monospaced))
                      .textSelection(.enabled)
                  }
                  .font(.caption)
                  .padding(.top, 5)
                } label: {
                  VStack(alignment: .leading, spacing: 2) {
                    Text(tool.title ?? tool.remoteName)
                      .font(.system(size: 13, weight: .medium))
                    if tool.title != nil {
                      Text(tool.remoteName)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                    }
                  }
                }
              }
            }
          }
        }
      }
      .formStyle(.grouped)
      .padding(10)
    }
    .frame(width: 680, height: 680)
    .background(MacDesignTokens.Colors.canvas)
  }

  private var credentialPlaceholder: String {
    guard let server, mcp.hasCredential(server.id) else { return "Credential" }
    return "Leave blank to keep current credential"
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

    isSaving = true
    Task { @MainActor in
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
        isEnabled: isEnabled
      )
      isSaving = false
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
      let key = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
      let headerValue = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
      guard !key.isEmpty, !headerValue.isEmpty else {
        throw MCPError.invalidServer("Each additional header needs both a name and value.")
      }
      guard headers[key] == nil else {
        throw MCPError.invalidServer("Duplicate additional header: \(key)")
      }
      headers[key] = headerValue
    }
    return headers
  }
}

struct MacChatToolsView: View {
  @Bindable var mcp: MacMCPModel
  let conversationID: ConversationID
  let presets: [ProjectToolPreset]

  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text("Chat Tools")
            .font(.headline)
          if mcp.inheritsProjectTools(conversationID) {
            Text("Inheriting this project’s tool defaults")
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
              Button(preset.name) {
                Task { _ = await mcp.applyChatConfiguration(preset.configuration, conversationID: conversationID) }
              }
            }
          }
        }

        if mcp.hasChatOverride(conversationID) {
          Button("Use Project Defaults") {
            Task { _ = await mcp.removeChatConfiguration(conversationID) }
          }
        }

        Button("Done") { dismiss() }
          .keyboardShortcut(.cancelAction)
      }
      .padding(16)

      Divider()

      MacMCPServerConfigurationList(
        mcp: mcp,
        configuration: mcp.chatConfiguration(for: conversationID),
        setServerEnabled: { serverID, enabled in
          Task { _ = await mcp.setChatServerEnabled(enabled, serverID: serverID, conversationID: conversationID) }
        },
        setPolicy: { name, policy in
          Task { _ = await mcp.setChatToolPolicy(policy, exposedToolName: name, conversationID: conversationID) }
        }
      )
    }
    .frame(width: 680, height: 620)
    .background(MacDesignTokens.Colors.canvas)
  }
}

struct MacProjectToolsConfigurationView: View {
  @Bindable var mcp: MacMCPModel
  @Binding var configuration: MCPChatToolConfiguration

  var body: some View {
    MacMCPServerConfigurationList(
      mcp: mcp,
      configuration: configuration,
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
  }
}

private struct MacMCPServerConfigurationList: View {
  @Bindable var mcp: MacMCPModel
  let configuration: MCPChatToolConfiguration
  let setServerEnabled: (MCPServerID, Bool) -> Void
  let setPolicy: (String, ChatToolPermissionPolicy) -> Void

  var body: some View {
    if mcp.servers.isEmpty {
      ContentUnavailableView(
        "No MCP Servers",
        systemImage: "wrench.and.screwdriver",
        description: Text("Add an MCP server in Settings before enabling tools.")
      )
    } else {
      List {
        ForEach(mcp.servers) { server in
          Section {
            Toggle(
              "Enable \(server.name)",
              isOn: Binding(
                get: { configuration.isServerEnabled(server.id) },
                set: { setServerEnabled(server.id, $0) }
              )
            )
            .labelsHidden()
            .disabled(!server.isEnabled && !configuration.isServerEnabled(server.id))

            if !server.isEnabled {
              Label("Globally disabled in Settings", systemImage: "pause.circle")
                .font(.caption)
                .foregroundStyle(MacDesignTokens.Colors.textMuted)
            } else if configuration.isServerEnabled(server.id) {
              let tools = mcp.tools(for: server.id)
              if tools.isEmpty {
                HStack {
                  Text("No discovered tools")
                    .foregroundStyle(MacDesignTokens.Colors.textMuted)
                  Spacer()
                  Button("Refresh") { Task { _ = await mcp.refresh(server.id) } }
                }
              } else {
                ForEach(tools) { binding in
                  HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                      Text(binding.remoteTool.title ?? binding.remoteTool.remoteName)
                        .font(.system(size: 13, weight: .medium))
                      Text(binding.remoteTool.description)
                        .font(.caption)
                        .foregroundStyle(MacDesignTokens.Colors.textMuted)
                        .lineLimit(2)
                    }
                    Spacer(minLength: 20)
                    Picker(
                      "Permission",
                      selection: Binding(
                        get: { configuration.policy(for: binding.exposedName) },
                        set: { setPolicy(binding.exposedName, $0) }
                      )
                    ) {
                      ForEach(ChatToolPermissionPolicy.allCases, id: \.rawValue) { policy in
                        Text(policy.displayName).tag(policy)
                      }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                  }
                  .padding(.vertical, 3)
                }
              }
            }
          } header: {
            HStack {
              Text(server.name)
              Spacer()
              if let snapshot = mcp.snapshot(for: server.id) {
                Text("\(snapshot.tools.count) tools")
                  .font(.caption)
                  .foregroundStyle(.tertiary)
              }
            }
          }
        }
      }
      .listStyle(.inset)
    }
  }
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

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: request.destructiveHint == true ? "exclamationmark.shield" : "hand.raised")
          .font(.system(size: 18, weight: .semibold))
          .foregroundStyle(request.destructiveHint == true ? Color.orange : MacDesignTokens.Colors.accent)
          .frame(width: 28, height: 28)

        VStack(alignment: .leading, spacing: 3) {
          Text("Allow tool call?")
            .font(.system(size: 14, weight: .semibold))
          Text("\(request.serverName) · \(request.displayName)")
            .font(.system(size: 12.5, weight: .medium))
          Text(request.toolDescription)
            .font(.caption)
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
        }
      }

      HStack(spacing: 8) {
        if request.readOnlyHint == true {
          Label("Read-only", systemImage: "eye")
        }
        if request.destructiveHint == true {
          Label("Destructive", systemImage: "exclamationmark.triangle")
            .foregroundStyle(.orange)
        }
      }
      .font(.caption2.weight(.medium))
      .foregroundStyle(MacDesignTokens.Colors.textMuted)

      DisclosureGroup("Arguments") {
        Text(request.arguments.macPrettyJSONString())
          .font(.system(size: 11, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.top, 6)
      }
      .font(.caption.weight(.semibold))

      HStack {
        Button("Deny", role: .destructive) { resolve(.deny) }
        Spacer()
        Button("Allow Once") { resolve(.allowOnce) }
        Button("Always Allow") { resolve(.alwaysAllow) }
          .buttonStyle(.borderedProminent)
      }
      .controlSize(.small)
    }
    .padding(14)
    .background(MacDesignTokens.Colors.surface, in: RoundedRectangle(cornerRadius: MacDesignTokens.Radius.large))
    .overlay {
      RoundedRectangle(cornerRadius: MacDesignTokens.Radius.large)
        .stroke(request.destructiveHint == true ? Color.orange.opacity(0.45) : MacDesignTokens.Colors.separator, lineWidth: 1)
    }
  }
}

private struct MacMCPElicitationCard: View {
  let request: MCPElicitationRequest
  let resolve: (MCPElicitationDecision) -> Void

  @State private var textValues: [String: String]
  @State private var boolValues: [String: Bool]

  init(request: MCPElicitationRequest, resolve: @escaping (MCPElicitationDecision) -> Void) {
    self.request = request
    self.resolve = resolve

    var text: [String: String] = [:]
    var bools: [String: Bool] = [:]
    for field in request.fields {
      switch (field.kind, field.defaultValue) {
      case (.boolean, .bool(let value)):
        bools[field.name] = value
      case (.string, .string(let value)):
        text[field.name] = value
      case (.integer, .number(let value)), (.number, .number(let value)):
        text[field.name] = String(value)
      case (.stringArray, .array(let values)):
        text[field.name] = values.compactMap {
          if case .string(let value) = $0 { return value }
          return nil
        }.joined(separator: ", ")
      default:
        if field.kind == .boolean { bools[field.name] = false }
      }
    }
    _textValues = State(initialValue: text)
    _boolValues = State(initialValue: bools)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label("\(request.serverName) needs input", systemImage: "text.bubble")
        .font(.system(size: 14, weight: .semibold))

      Text(request.message)
        .font(.system(size: 13))

      switch request.mode {
      case .form:
        formFields
      case .url:
        if let url = request.url {
          VStack(alignment: .leading, spacing: 8) {
            Text("Complete the requested step, then return to BYOKchat.")
              .font(.caption)
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
            Link(destination: url) {
              Label("Open Link", systemImage: "arrow.up.right.square")
            }
          }
        }
      }

      HStack {
        Button("Cancel") { resolve(.cancel) }
        Button("Decline", role: .destructive) { resolve(.decline) }
        Spacer()
        Button(request.mode == .url ? "Continue" : "Submit") {
          resolve(.accept(responseContent()))
        }
        .buttonStyle(.borderedProminent)
        .disabled(!canSubmit)
      }
      .controlSize(.small)
    }
    .padding(14)
    .background(MacDesignTokens.Colors.surface, in: RoundedRectangle(cornerRadius: MacDesignTokens.Radius.large))
    .overlay {
      RoundedRectangle(cornerRadius: MacDesignTokens.Radius.large)
        .stroke(MacDesignTokens.Colors.separator, lineWidth: 1)
    }
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
                get: { textValues[field.name] ?? field.allowedValues.first ?? "" },
                set: { textValues[field.name] = $0 }
              )
            ) {
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
          }

          if let description = field.description, !description.isEmpty {
            Text(description)
              .font(.caption2)
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
          }
        }
      }
    }
  }

  private var canSubmit: Bool {
    guard request.mode == .form else { return request.url != nil }
    for field in request.fields {
      let raw = (textValues[field.name] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      if field.isRequired, field.kind != .boolean, raw.isEmpty { return false }
      if raw.isEmpty { continue }
      switch field.kind {
      case .integer:
        guard Int(raw) != nil else { return false }
      case .number:
        guard let value = Double(raw), value.isFinite else { return false }
      case .string, .boolean, .stringArray:
        break
      }
    }
    return true
  }

  private func responseContent() -> [String: JSONValue] {
    var values: [String: JSONValue] = [:]
    for field in request.fields {
      switch field.kind {
      case .boolean:
        values[field.name] = .bool(boolValues[field.name] ?? false)
      case .integer:
        if let value = Int(textValues[field.name] ?? "") {
          values[field.name] = .number(Double(value))
        }
      case .number:
        if let value = Double(textValues[field.name] ?? ""), value.isFinite {
          values[field.name] = .number(value)
        }
      case .string:
        let value = textValues[field.name] ?? ""
        if !value.isEmpty || field.isRequired { values[field.name] = .string(value) }
      case .stringArray:
        let value = (textValues[field.name] ?? "")
          .split(separator: ",")
          .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
          .filter { !$0.isEmpty }
          .map(JSONValue.string)
        if !value.isEmpty || field.isRequired { values[field.name] = .array(value) }
      }
    }
    return values
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
        ProgressView()
          .controlSize(.mini)
        Text(displayName)
          .font(.system(size: 12, weight: .semibold))
        Spacer()
        Text(waitingForApproval ? "Waiting for approval" : "Running")
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
          Text("Arguments")
            .font(.caption.weight(.semibold))
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
  fileprivate func macPrettyJSONString() -> String {
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
