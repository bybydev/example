import AppFoundation
import BYOKchatProviderCore
import SwiftUI

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
      Text("The server configuration, cached tool catalog, and its Keychain credential will be removed.")
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
        Text("Phase 2 only discovers and validates remote tools. Chat access and execution approvals are added in Phase 3, so MCP tools cannot silently run from a conversation yet.")
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
