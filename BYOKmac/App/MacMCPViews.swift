import AppKit
import BYOKchatProviderCore
import Foundation
import MacAppFoundation
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

nonisolated enum MacMCPWorkspaceRoute: Equatable, Sendable {
  case list
  case addServer
  case server(MCPServerID)
  case serverTools(MCPServerID)

  var activeServerID: MCPServerID? {
    switch self {
    case .list, .addServer: nil
    case .server(let id), .serverTools(let id): id
    }
  }
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

  @Environment(PurchaseManager.self) private var purchaseManager
  @State private var route: MacMCPWorkspaceRoute = .list
  @State private var deleteServer: MCPRemoteServer?

  private var isCheckingEntitlement: Bool {
    purchaseManager.entitlementState == .checking
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
      switch route {
      case .list:
        serverList
      case .addServer:
        MacMCPServerSettingsView(
          mcp: mcp,
          server: nil,
          backTitle: "MCP Servers",
          back: { route = .list },
          onCreated: { createdID in
            if let createdID {
              route = .server(createdID)
            } else {
              route = .list
            }
          },
          openTools: nil,
          requestDelete: nil
        )
        .id("add-mcp-server")
      case .server(let serverID):
        if let server = server(for: serverID) {
          MacMCPServerSettingsView(
            mcp: mcp,
            server: server,
            backTitle: "MCP Servers",
            back: { route = .list },
            onCreated: nil,
            openTools: { route = .serverTools(server.id) },
            requestDelete: { deleteServer = server }
          )
          .id("server-\(server.id.rawValue)")
        } else {
          serverList
        }
      case .serverTools(let serverID):
        if let server = server(for: serverID) {
          MacMCPServerToolsCatalogView(
            mcp: mcp,
            server: server,
            back: { route = .server(server.id) }
          )
          .id("tools-\(server.id.rawValue)")
        } else {
          serverList
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(MacDesignTokens.Colors.canvas)
    .onChange(of: mcp.servers.map(\.id)) { _, ids in
      if let activeID = route.activeServerID, !ids.contains(activeID) {
        route = .list
      }
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
        Task { @MainActor in
          if await mcp.deleteServer(server.id), route.activeServerID == server.id {
            route = .list
          }
        }
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

  private func server(for id: MCPServerID) -> MCPRemoteServer? {
    mcp.servers.first { $0.id == id }
  }

  @ViewBuilder
  private var serverList: some View {
    if mcp.servers.isEmpty {
      ContentUnavailableView {
        Label("No MCP Servers", systemImage: "shippingbox.and.arrow.backward")
      } description: {
        Text("Add a remote Streamable HTTP MCP endpoint to discover its tools.")
      } actions: {
        Button("Add Server", systemImage: "plus") {
          beginAddServer()
        }
        .buttonStyle(MacActionButtonStyle(.primary))
        .disabled(isCheckingEntitlement)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      let partition = MacActiveDisabledPartition(mcp.servers, isEnabled: \.isEnabled)
      VStack(spacing: 0) {
        HStack(spacing: 12) {
          Text(
            "\(enabledServerCount) enabled · \(discoveredToolCount) \(discoveredToolCount == 1 ? "tool" : "tools") discovered"
          )
          .font(.system(size: 12.5))
          .foregroundStyle(MacDesignTokens.Colors.textMuted)

          Spacer()

          Button("Add Server", systemImage: "plus") {
            beginAddServer()
          }
          .buttonStyle(MacActionButtonStyle(.primary))
          .disabled(isCheckingEntitlement)
        }
        .padding(.horizontal, 16)
        .frame(height: 54)
        .background(MacDesignTokens.Colors.surface.opacity(0.45))

        Divider()

        ScrollView {
          VStack(alignment: .leading, spacing: 18) {
            if !partition.active.isEmpty {
              serverGroup(
                title: partition.showsSectionHeaders ? "Active" : nil,
                servers: partition.active
              )
            }

            if !partition.disabled.isEmpty {
              serverGroup(
                title: "Disabled",
                servers: partition.disabled
              )
            }
          }
          .padding(16)
        }
      }
    }
  }

  private func serverGroup(title: String?, servers: [MCPRemoteServer]) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      if let title {
        Text(title)
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(MacDesignTokens.Colors.textMuted)
          .textCase(.uppercase)
          .tracking(0.4)
          .padding(.leading, 4)
          .accessibilityAddTraits(.isHeader)
      }

      MacMCPInsetGroup {
        ForEach(Array(servers.enumerated()), id: \.element.id) { index, server in
          if index > 0 {
            Rectangle()
              .fill(MacDesignTokens.Colors.separator.opacity(0.65))
              .frame(height: 0.5)
              .padding(.leading, 55)
          }
          serverRow(server)
        }
      }
    }
  }

  private func serverRow(_ server: MCPRemoteServer) -> some View {
    let missingCredential = server.authentication.kind != .none && !mcp.hasCredential(server.id)
    let isRefreshing = mcp.refreshingServerIDs.contains(server.id)
    let snapshot = mcp.snapshot(for: server.id)
    return MacMCPServerListRow(
      server: server,
      snapshot: snapshot,
      missingCredential: missingCredential,
      presentationState: macMCPServerPresentationState(server: server, snapshot: snapshot),
      isRefreshing: isRefreshing,
      isBusy: mcp.isBusy,
      open: { route = .server(server.id) },
      openTools: { route = .serverTools(server.id) },
      setEnabled: { enabled in
        Task { _ = await mcp.setEnabled(enabled, serverID: server.id) }
      },
      refresh: {
        Task { _ = await mcp.refresh(server.id) }
      },
      requestDelete: {
        deleteServer = server
      }
    )
  }

  private func beginAddServer() {
    guard MacProAccess.requireMCPServerCapacity(currentCount: mcp.servers.count) else { return }
    route = .addServer
  }
}

private struct MacMCPInsetGroup<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
    VStack(alignment: .leading, spacing: 0) {
      content
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(MacDesignTokens.Colors.surface, in: shape)
    .clipShape(shape)
    .overlay {
      shape.stroke(MacDesignTokens.Colors.separator.opacity(0.75), lineWidth: 0.5)
        .allowsHitTesting(false)
    }
  }
}

private struct MacMCPServerIcon: View {
  let isEnabled: Bool
  let hasIssue: Bool
  let size: CGFloat

  private var tint: Color {
    if !isEnabled { return MacDesignTokens.Colors.textMuted }
    if hasIssue { return .orange }
    return MacDesignTokens.Colors.accent
  }

  var body: some View {
    Image(systemName: "shippingbox")
      .font(.system(size: size * 0.45, weight: .semibold))
      .foregroundStyle(tint)
      .frame(width: size, height: size)
      .background(
        tint.opacity(isEnabled ? 0.13 : 0.08),
        in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
      )
      .accessibilityHidden(true)
  }
}

private func macMCPCompactEndpoint(_ url: URL) -> String {
  var value = url.absoluteString
  if value.hasPrefix("https://") {
    value.removeFirst("https://".count)
  } else if value.hasPrefix("http://") {
    value.removeFirst("http://".count)
  }
  while value.hasSuffix("/") && value.count > 1 {
    value.removeLast()
  }
  return value
}

private func macMCPShortAuthLabel(_ authentication: MCPAuthentication) -> String {
  switch authentication.kind {
  case .none: "None"
  case .bearer: "Bearer"
  case .customHeader: "Custom header"
  }
}

private struct MacMCPServerListRow: View {
  let server: MCPRemoteServer
  let snapshot: MCPServerSnapshot?
  let missingCredential: Bool
  let presentationState: MacMCPServerPresentationState
  let isRefreshing: Bool
  let isBusy: Bool
  let open: () -> Void
  let openTools: () -> Void
  let setEnabled: (Bool) -> Void
  let refresh: () -> Void
  let requestDelete: () -> Void

  @State private var isHovered = false

  private var middleSummary: String {
    let auth = macMCPShortAuthLabel(server.authentication)
    if let snapshot {
      let count = snapshot.tools.count
      return "\(count) \(count == 1 ? "tool" : "tools") · \(auth)"
    }
    if !server.isEnabled {
      return "Not discovered · \(auth)"
    }
    if missingCredential {
      return "Credential required · \(auth)"
    }
    return "Needs discovery · \(auth)"
  }

  var body: some View {
    HStack(spacing: 14) {
      HStack(spacing: 11) {
        MacMCPServerIcon(
          isEnabled: server.isEnabled,
          hasIssue: server.isEnabled && missingCredential,
          size: 30
        )

        VStack(alignment: .leading, spacing: 2) {
          Text(server.name)
            .font(.system(size: 13.5, weight: .semibold))
            .foregroundStyle(
              server.isEnabled
                ? MacDesignTokens.Colors.textPrimary
                : MacDesignTokens.Colors.textMuted
            )
            .lineLimit(1)
          Text(macMCPCompactEndpoint(server.endpoint))
            .font(.system(size: 11.5))
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
            .lineLimit(1)
            .truncationMode(.middle)
        }
      }
      .frame(width: 244, alignment: .leading)

      Text(middleSummary)
        .font(.system(size: 12.5))
        .foregroundStyle(MacDesignTokens.Colors.textMuted)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)

      HStack(spacing: 8) {
        ZStack(alignment: .trailing) {
          statusIndicator
            .opacity(isHovered ? 0 : 1)
            .allowsHitTesting(false)

          HStack(spacing: 4) {
            if isRefreshing {
              ProgressView()
                .controlSize(.mini)
                .padding(.trailing, 4)
                .accessibilityLabel("Refreshing \(server.name)")
            } else if server.isEnabled && !missingCredential {
              Button(action: refresh) {
                Image(systemName: "arrow.clockwise")
                  .font(.system(size: 12, weight: .medium))
              }
              .buttonStyle(MacIconButtonStyle())
              .disabled(isBusy)
              .help("Refresh Tools")
              .accessibilityLabel("Refresh tools for \(server.name)")
            } else if !server.isEnabled {
              Button("Enable") { setEnabled(true) }
                .buttonStyle(MacActionButtonStyle(.subtle, size: .small))
                .disabled(isBusy)
            }

            Menu {
              rowMenuItems
            } label: {
              MacIconMenuLabel(systemImage: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Server actions")
          }
          .opacity(isHovered ? 1 : 0)
          .allowsHitTesting(isHovered)
        }
        .frame(minWidth: 148, alignment: .trailing)

        Image(systemName: "chevron.right")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(
            isHovered
              ? MacDesignTokens.Colors.textPrimary.opacity(0.75)
              : MacDesignTokens.Colors.textMuted.opacity(0.5)
          )
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
    .frame(minHeight: 52)
    .background(Color.primary.opacity(isHovered ? 0.035 : 0))
    .contentShape(Rectangle())
    .onTapGesture(perform: open)
    .onHover { isHovered = $0 }
    .animation(.easeOut(duration: MacDesignTokens.Control.interactionDuration), value: isHovered)
    .contextMenu {
      rowMenuItems
    }
  }

  @ViewBuilder
  private var statusIndicator: some View {
    if isRefreshing {
      HStack(spacing: 6) {
        ProgressView()
          .controlSize(.mini)
        Text("Refreshing…")
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(MacDesignTokens.Colors.textMuted)
      }
    } else if server.isEnabled && missingCredential {
      HStack(spacing: 5) {
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.system(size: 10.5))
          .foregroundStyle(.orange)
        Text("Missing credential")
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(.orange)
          .lineLimit(1)
      }
    } else {
      switch presentationState {
      case .discovered:
        HStack(spacing: 6) {
          Circle()
            .fill(MacDesignTokens.Colors.accent)
            .frame(width: 6, height: 6)
          Text("Ready")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
        }
      case .needsDiscovery:
        HStack(spacing: 6) {
          Circle()
            .fill(Color.orange)
            .frame(width: 6, height: 6)
          Text("Needs sync")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.orange)
        }
      case .disabled:
        Text("Disabled")
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(MacDesignTokens.Colors.textMuted.opacity(0.8))
      }
    }
  }

  @ViewBuilder
  private var rowMenuItems: some View {
    Button("Configure", systemImage: "slider.horizontal.3", action: open)
    Button("Browse Tools", systemImage: "wrench.and.screwdriver", action: openTools)
    Button("Refresh Tools", systemImage: "arrow.clockwise", action: refresh)
      .disabled(isBusy || !server.isEnabled || missingCredential)
    Button(
      server.isEnabled ? "Disable Server" : "Enable Server",
      systemImage: server.isEnabled ? "pause.circle" : "play.circle"
    ) {
      setEnabled(!server.isEnabled)
    }
    .disabled(isBusy)
    Divider()
    Button("Delete Server…", systemImage: "trash", role: .destructive, action: requestDelete)
  }
}

struct MacMCPServerSettingsView: View {
  private enum PendingNavigation {
    case back
    case tools
  }

  @Bindable var mcp: MacMCPModel
  let server: MCPRemoteServer?
  let backTitle: String
  let back: () -> Void
  let onCreated: ((MCPServerID?) -> Void)?
  let openTools: (() -> Void)?
  let requestDelete: (() -> Void)?

  @Environment(\.macToastCenter) private var toastCenter
  @FocusState private var nameFocused: Bool
  @State private var name: String
  @State private var endpoint: String
  @State private var authenticationKind: MCPAuthenticationKind
  @State private var authenticationHeader: String
  @State private var credential = ""
  @State private var additionalHeaders: [MacAdditionalHeaderItem]
  @State private var headerEditorTarget: MacAdditionalHeaderEditorTarget?
  @State private var showingAdvanced: Bool
  @State private var showingInstructions = false
  @State private var copiedEndpoint = false
  @State private var isSaving = false
  @State private var saveError: String?
  @State private var showingDiscardAlert = false
  @State private var pendingNavigation: PendingNavigation?
  @State private var isToolsRowHovered = false

  private var isCreate: Bool { server == nil }

  init(
    mcp: MacMCPModel,
    server: MCPRemoteServer?,
    backTitle: String,
    back: @escaping () -> Void,
    onCreated: ((MCPServerID?) -> Void)?,
    openTools: (() -> Void)?,
    requestDelete: (() -> Void)?
  ) {
    self.mcp = mcp
    self.server = server
    self.backTitle = backTitle
    self.back = back
    self.onCreated = onCreated
    self.openTools = openTools
    self.requestDelete = requestDelete
    let savedHeaders = server?.additionalHeaders ?? [:]
    _name = State(initialValue: server?.name ?? "")
    _endpoint = State(initialValue: server?.endpoint.absoluteString ?? "https://")
    _authenticationKind = State(initialValue: server?.authentication.kind ?? .none)
    _authenticationHeader = State(initialValue: server?.authentication.headerName ?? "X-API-Key")
    _additionalHeaders = State(initialValue: MacAdditionalHeaderItem.items(from: savedHeaders))
    _showingAdvanced = State(initialValue: !savedHeaders.isEmpty)
  }

  private var snapshot: MCPServerSnapshot? {
    server.flatMap { mcp.snapshot(for: $0.id) }
  }

  private var isRefreshing: Bool {
    server.map { mcp.refreshingServerIDs.contains($0.id) } ?? false
  }

  private var hasExistingCredential: Bool {
    server.map { mcp.hasCredential($0.id) } ?? false
  }

  private var missingSavedCredential: Bool {
    guard let server else { return false }
    return server.authentication.kind != .none && !mcp.hasCredential(server.id)
  }

  private var presentationState: MacMCPServerPresentationState? {
    server.map { macMCPServerPresentationState(server: $0, snapshot: snapshot) }
  }

  private var trimmedName: String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var trimmedEndpoint: String {
    endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var trimmedAuthHeader: String {
    authenticationHeader.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var trimmedCredential: String {
    credential.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var isEndpointValid: Bool {
    guard let url = URL(string: trimmedEndpoint),
      let scheme = url.scheme?.lowercased(),
      scheme == "https" || scheme == "http",
      let host = url.host,
      !host.isEmpty
    else { return false }
    return true
  }

  private var requiresNewCredential: Bool {
    authenticationKind != .none && !hasExistingCredential && trimmedCredential.isEmpty
  }

  private var endpointValidationHint: String? {
    guard !trimmedEndpoint.isEmpty, trimmedEndpoint != "https://", trimmedEndpoint != "http://" else {
      return nil
    }
    return isEndpointValid ? nil : "Enter a valid http:// or https:// endpoint URL."
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

  private var additionalHeadersDictionary: [String: String] {
    MacAdditionalHeaderItem.dictionary(from: additionalHeaders)
  }

  private var hasUnsavedChanges: Bool {
    if let server {
      if hasInvalidAdditionalHeaders { return true }
      if trimmedName != server.name { return true }
      if trimmedEndpoint != server.endpoint.absoluteString { return true }
      if authenticationKind != server.authentication.kind { return true }
      if authenticationKind == .customHeader {
        let savedHeader = server.authentication.headerName ?? ""
        if trimmedAuthHeader != savedHeader { return true }
      }
      if authenticationKind != .none && !trimmedCredential.isEmpty { return true }
      if additionalHeadersDictionary != server.additionalHeaders { return true }
      return false
    }

    return !trimmedName.isEmpty
      || (!trimmedEndpoint.isEmpty && trimmedEndpoint != "https://")
      || authenticationKind != .none
      || !trimmedCredential.isEmpty
      || !additionalHeaders.isEmpty
  }

  private var canSave: Bool {
    guard !isSaving else { return false }
    guard !hasInvalidAdditionalHeaders else { return false }
    guard !trimmedName.isEmpty, isEndpointValid else { return false }
    if authenticationKind == .customHeader, trimmedAuthHeader.isEmpty { return false }
    if requiresNewCredential { return false }
    return true
  }

  private var showsBottomBar: Bool {
    isCreate || hasUnsavedChanges || isSaving
  }

  private var credentialPlaceholder: String {
    hasExistingCredential ? "Leave blank to keep current" : "Enter credential"
  }

  var body: some View {
    VStack(spacing: 0) {
      headerBar
      Divider()

      if let saveError {
        MacMCPInlineErrorBanner(message: saveError) {
          self.saveError = nil
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        Divider()
      }

      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          if let server {
            toolsAndDiscoverySection(server)
          }

          connectionSection
          authenticationSection
          additionalHeadersSection

          if !isCreate, let requestDelete {
            Button(role: .destructive, action: requestDelete) {
              Text("Delete Server…")
                .foregroundStyle(.red)
            }
            .buttonStyle(MacActionButtonStyle(.subtle, size: .small))
            .padding(.top, 2)
          }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: 600, alignment: .leading)
        .frame(maxWidth: .infinity)
      }
      .disabled(isSaving)

      if showsBottomBar {
        Divider()
        bottomActionBar
      }
    }
    .background(MacDesignTokens.Colors.canvas)
    .interactiveDismissDisabled(isSaving || hasUnsavedChanges)
    .onAppear {
      if isCreate {
        nameFocused = true
      }
    }
    .onChange(of: hasInvalidAdditionalHeaders) { _, hasErrors in
      if hasErrors && !showingAdvanced {
        showingAdvanced = true
      }
    }
    .alert("Unsaved Changes", isPresented: $showingDiscardAlert) {
      Button("Discard Changes", role: .destructive) {
        let target = pendingNavigation ?? .back
        pendingNavigation = nil
        if let server {
          syncDraft(from: server)
        }
        performNavigation(target)
      }
      if canSave {
        Button(isCreate ? "Add Server" : "Save") {
          let target = pendingNavigation ?? .back
          pendingNavigation = nil
          save(then: target)
        }
      }
      Button("Keep Editing", role: .cancel) {
        pendingNavigation = nil
      }
    } message: {
      Text(
        canSave
          ? "You have unsaved changes to this MCP server. Do you want to save them before leaving?"
          : "You have unsaved changes to this MCP server that will be lost if you leave."
      )
    }
  }

  private var headerBar: some View {
    HStack(spacing: 12) {
      Button {
        requestNavigation(.back)
      } label: {
        Label(backTitle, systemImage: "chevron.left")
          .foregroundStyle(MacDesignTokens.Colors.accent)
      }
      .buttonStyle(MacActionButtonStyle(.subtle, size: .small))
      .keyboardShortcut(.cancelAction)
      .disabled(isSaving)

      Divider().frame(height: 24)

      MacMCPServerIcon(
        isEnabled: server?.isEnabled ?? true,
        hasIssue: (server?.isEnabled ?? true) && missingSavedCredential,
        size: 34
      )

      VStack(alignment: .leading, spacing: 2) {
        Text(isCreate ? "New MCP Server" : (server?.name ?? name))
          .font(.system(size: 14.5, weight: .semibold))
          .foregroundStyle(MacDesignTokens.Colors.textPrimary)
          .lineLimit(1)
        headerSubtitle
      }

      Spacer()

      if let server {
        Button {
          Task { _ = await mcp.refresh(server.id) }
        } label: {
          HStack(spacing: 5) {
            if isRefreshing {
              ProgressView()
                .controlSize(.mini)
            } else {
              Image(systemName: "arrow.clockwise")
            }
            Text(isRefreshing ? "Refreshing…" : "Refresh")
          }
        }
        .buttonStyle(MacActionButtonStyle(.secondary, size: .small))
        .disabled(mcp.isBusy || !server.isEnabled || missingSavedCredential || isSaving)

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
        .disabled(mcp.isBusy || isSaving)
        .help(server.isEnabled ? "Disable server" : "Enable server")

        Menu {
          if openTools != nil {
            Button("Browse Tools", systemImage: "wrench.and.screwdriver") {
              requestNavigation(.tools)
            }
          }
          Button("Copy Endpoint URL", systemImage: "doc.on.doc") {
            copyEndpoint(server.endpoint.absoluteString)
          }
          Button(
            server.isEnabled ? "Disable Server" : "Enable Server",
            systemImage: server.isEnabled ? "pause.circle" : "play.circle"
          ) {
            Task { _ = await mcp.setEnabled(!server.isEnabled, serverID: server.id) }
          }
          .disabled(mcp.isBusy || isSaving)
          if let requestDelete {
            Divider()
            Button("Delete Server…", systemImage: "trash", role: .destructive, action: requestDelete)
          }
        } label: {
          MacIconMenuLabel(systemImage: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
      }
    }
    .padding(.horizontal, 18)
    .frame(height: 62)
    .background(MacDesignTokens.Colors.surface.opacity(0.45))
  }

  @ViewBuilder
  private var headerSubtitle: some View {
    if isCreate {
      Text("Configure remote Streamable HTTP endpoint.")
        .font(.caption)
        .foregroundStyle(MacDesignTokens.Colors.textMuted)
    } else if let server, let state = presentationState {
      HStack(spacing: 6) {
        if server.isEnabled && missingSavedCredential {
          Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 10))
            .foregroundStyle(.orange)
          Text("Missing credential")
            .font(.caption)
            .foregroundStyle(.orange)
        } else {
          switch state {
          case .discovered:
            Circle()
              .fill(MacDesignTokens.Colors.accent)
              .frame(width: 6, height: 6)
            Text(snapshot.map { "Ready · MCP \($0.protocolVersion)" } ?? "Ready")
              .font(.caption)
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
          case .needsDiscovery:
            Circle()
              .fill(Color.orange)
              .frame(width: 6, height: 6)
            Text("Needs discovery")
              .font(.caption)
              .foregroundStyle(.orange)
          case .disabled:
            Circle()
              .strokeBorder(MacDesignTokens.Colors.textMuted.opacity(0.65), lineWidth: 1.2)
              .frame(width: 6, height: 6)
            Text("Disabled")
              .font(.caption)
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
          }
        }
      }
    }
  }

  private func toolsAndDiscoverySection(_ server: MCPRemoteServer) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      sectionHeader("Tools & Discovery")

      MacMCPInsetGroup {
        Button {
          requestNavigation(.tools)
        } label: {
          HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
              Text("Tools")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(MacDesignTokens.Colors.textPrimary)
              toolsRowSubtitle(server)
            }

            Spacer(minLength: 12)

            Text("Browse Tools")
              .font(.system(size: 12.5, weight: .medium))
              .foregroundStyle(
                isToolsRowHovered
                  ? MacDesignTokens.Colors.accent
                  : MacDesignTokens.Colors.textMuted
              )

            Image(systemName: "chevron.right")
              .font(.system(size: 11, weight: .semibold))
              .foregroundStyle(
                isToolsRowHovered
                  ? MacDesignTokens.Colors.textPrimary.opacity(0.75)
                  : MacDesignTokens.Colors.textMuted.opacity(0.5)
              )
          }
          .padding(.horizontal, 14)
          .padding(.vertical, 10)
          .frame(minHeight: 48)
          .background(Color.primary.opacity(isToolsRowHovered ? 0.035 : 0))
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isToolsRowHovered = $0 }
        .animation(.easeOut(duration: MacDesignTokens.Control.interactionDuration), value: isToolsRowHovered)

        if let snapshot {
          settingsDivider
          settingsRow("Protocol") {
            Text(
              "MCP \(snapshot.protocolVersion) (\(snapshot.era == .modern ? "Modern" : "Legacy fallback"))"
            )
            .font(.system(size: 12.5))
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
          }

          if let info = snapshot.serverInfo {
            settingsDivider
            settingsRow("Server") {
              Text("\(info.name) \(info.version)")
                .font(.system(size: 12.5))
                .foregroundStyle(MacDesignTokens.Colors.textMuted)
            }
          }

          if let instructions = snapshot.instructions,
            !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          {
            settingsDivider
            VStack(alignment: .leading, spacing: 0) {
              Button {
                withAnimation(.easeOut(duration: MacDesignTokens.Control.interactionDuration)) {
                  showingInstructions.toggle()
                }
              } label: {
                HStack(spacing: 8) {
                  Image(systemName: showingInstructions ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(MacDesignTokens.Colors.textMuted)
                    .frame(width: 12)
                  Text("Server Instructions")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(MacDesignTokens.Colors.textPrimary)
                  Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .frame(minHeight: 42)
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)

              if showingInstructions {
                Text(instructions)
                  .font(.caption)
                  .foregroundStyle(MacDesignTokens.Colors.textMuted)
                  .textSelection(.enabled)
                  .fixedSize(horizontal: false, vertical: true)
                  .padding(.horizontal, 14)
                  .padding(.bottom, 12)
              }
            }
          }

          ForEach(snapshot.warnings, id: \.self) { warning in
            settingsDivider
            Label(warning, systemImage: "exclamationmark.triangle.fill")
              .font(.caption)
              .foregroundStyle(.orange)
              .fixedSize(horizontal: false, vertical: true)
              .padding(.horizontal, 14)
              .padding(.vertical, 9)
          }
        }
      }
    }
  }

  @ViewBuilder
  private func toolsRowSubtitle(_ server: MCPRemoteServer) -> some View {
    if let snapshot {
      let count = snapshot.tools.count
      let refreshed = snapshot.refreshedAt.formatted(date: .abbreviated, time: .shortened)
      Text("\(count) discovered · Updated \(refreshed)")
        .font(.caption)
        .foregroundStyle(MacDesignTokens.Colors.textMuted)
    } else if server.isEnabled && missingSavedCredential {
      Text("Add a credential to discover tools")
        .font(.caption)
        .foregroundStyle(.orange)
    } else if !server.isEnabled {
      Text("Enable server to discover tools")
        .font(.caption)
        .foregroundStyle(MacDesignTokens.Colors.textMuted)
    } else {
      Text("Not discovered yet — refresh to inspect tools")
        .font(.caption)
        .foregroundStyle(MacDesignTokens.Colors.textMuted)
    }
  }

  private var connectionSection: some View {
    VStack(alignment: .leading, spacing: 7) {
      sectionHeader("Connection")

      MacMCPInsetGroup {
        settingsRow("Name") {
          TextField("Server name", text: $name)
            .textFieldStyle(.roundedBorder)
            .frame(width: 280)
            .focused($nameFocused)
        }

        settingsDivider

        VStack(alignment: .leading, spacing: 0) {
          settingsRow("Server URL") {
            HStack(spacing: 6) {
              TextField("Server URL", text: $endpoint, prompt: Text("https://example.com/mcp"))
                .textFieldStyle(.roundedBorder)
                .frame(width: isCreate ? 280 : 250)

              if !isCreate {
                Button {
                  copyEndpoint(trimmedEndpoint)
                } label: {
                  Image(systemName: copiedEndpoint ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(
                      copiedEndpoint
                        ? MacDesignTokens.Colors.accent
                        : MacDesignTokens.Colors.textMuted
                    )
                }
                .buttonStyle(MacIconButtonStyle())
                .disabled(trimmedEndpoint.isEmpty)
                .help("Copy endpoint URL")
                .accessibilityLabel("Copy endpoint URL")
              }
            }
          }

          if let endpointValidationHint {
            Text(endpointValidationHint)
              .font(.caption)
              .foregroundStyle(.red)
              .padding(.horizontal, 14)
              .padding(.bottom, 8)
          }
        }
      }
    }
  }

  private var authenticationSection: some View {
    VStack(alignment: .leading, spacing: 7) {
      sectionHeader("Authentication")

      MacMCPInsetGroup {
        settingsRow("Method") {
          Picker("Authentication", selection: $authenticationKind) {
            Text("None").tag(MCPAuthenticationKind.none)
            Text("Bearer Token").tag(MCPAuthenticationKind.bearer)
            Text("Custom Header").tag(MCPAuthenticationKind.customHeader)
          }
          .labelsHidden()
          .frame(maxWidth: 200, alignment: .trailing)
        }

        if authenticationKind == .customHeader {
          settingsDivider
          VStack(alignment: .leading, spacing: 0) {
            settingsRow("Header Name") {
              TextField("X-API-Key", text: $authenticationHeader)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
            }
            if trimmedAuthHeader.isEmpty {
              Text("Enter the HTTP header name for this credential.")
                .font(.caption)
                .foregroundStyle(.red)
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
            }
          }
        }

        if authenticationKind != .none {
          settingsDivider
          VStack(alignment: .leading, spacing: 0) {
            settingsRow("Credential") {
              SecureField(credentialPlaceholder, text: $credential)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
            }
            if requiresNewCredential {
              Text("Enter a credential before saving.")
                .font(.caption)
                .foregroundStyle(.orange)
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
            } else if hasExistingCredential && trimmedCredential.isEmpty {
              Text("Stored in Keychain — leave blank to keep current credential.")
                .font(.caption)
                .foregroundStyle(MacDesignTokens.Colors.textMuted)
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
            }
          }
        }
      }

      Text("Credentials are stored securely in Keychain.")
        .font(.caption)
        .foregroundStyle(MacDesignTokens.Colors.textMuted)
        .padding(.leading, 4)
    }
  }

  private var additionalHeadersSection: some View {
    MacMCPInsetGroup {
      Button {
        withAnimation(.easeOut(duration: MacDesignTokens.Control.interactionDuration)) {
          showingAdvanced.toggle()
        }
      } label: {
        HStack(spacing: 8) {
          Image(systemName: showingAdvanced ? "chevron.down" : "chevron.right")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
            .frame(width: 12)
          Text("Additional Headers")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(MacDesignTokens.Colors.textPrimary)
          Spacer()
          if hasInvalidAdditionalHeaders {
            Image(systemName: "exclamationmark.triangle.fill")
              .font(.caption)
              .foregroundStyle(.red)
          }
          Text(additionalHeaders.isEmpty ? "None" : "\(additionalHeaders.count)")
            .font(.caption)
            .foregroundStyle(
              hasInvalidAdditionalHeaders ? Color.red : MacDesignTokens.Colors.textMuted
            )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      if showingAdvanced {
        settingsDivider
        MacAdditionalHeadersSection(
          headers: $additionalHeaders,
          policy: headerValidationPolicy,
          footerText:
            "Optional non-secret headers. Authentication and MCP protocol headers are managed by BYOKchat.",
          editorTarget: $headerEditorTarget
        )
        .padding(14)
      }
    }
    .macAdditionalHeaderEditorPopover(
      target: $headerEditorTarget,
      headers: $additionalHeaders,
      policy: headerValidationPolicy
    )
  }

  private var bottomActionBar: some View {
    HStack(spacing: 10) {
      if isSaving {
        HStack(spacing: 8) {
          ProgressView()
            .controlSize(.small)
          Text("Saving & discovering…")
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
        }
      } else if !isCreate {
        HStack(spacing: 6) {
          Circle()
            .fill(MacDesignTokens.Colors.accent)
            .frame(width: 6, height: 6)
          Text("Unsaved changes")
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
        }
      }

      Spacer()

      if isCreate {
        Button("Cancel") { requestNavigation(.back) }
          .buttonStyle(MacActionButtonStyle(.secondary))
          .disabled(isSaving)
        Button(isSaving ? "Adding…" : "Add Server") { save() }
          .buttonStyle(MacActionButtonStyle(.primary))
          .keyboardShortcut(.defaultAction)
          .disabled(!canSave)
      } else {
        Button("Discard") {
          if let server {
            syncDraft(from: server)
          }
        }
        .buttonStyle(MacActionButtonStyle(.secondary))
        .disabled(isSaving)
        Button(isSaving ? "Saving…" : "Save") { save() }
          .buttonStyle(MacActionButtonStyle(.primary))
          .keyboardShortcut(.defaultAction)
          .disabled(!canSave)
      }
    }
    .padding(.horizontal, 18)
    .frame(height: 54)
    .background(MacDesignTokens.Colors.surface.opacity(0.65))
  }

  private func sectionHeader(_ title: String) -> some View {
    Text(title)
      .font(.system(size: 11, weight: .semibold))
      .foregroundStyle(MacDesignTokens.Colors.textMuted)
      .textCase(.uppercase)
      .tracking(0.4)
      .padding(.leading, 4)
      .accessibilityAddTraits(.isHeader)
  }

  private var settingsDivider: some View {
    Rectangle()
      .fill(MacDesignTokens.Colors.separator.opacity(0.6))
      .frame(height: 0.5)
      .padding(.leading, 14)
  }

  private func settingsRow<Control: View>(
    _ title: String,
    @ViewBuilder control: () -> Control
  ) -> some View {
    HStack(alignment: .center, spacing: 12) {
      Text(title)
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(MacDesignTokens.Colors.textPrimary)
      Spacer(minLength: 12)
      control()
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 9)
    .frame(minHeight: 44)
  }

  private func copyEndpoint(_ value: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
    copiedEndpoint = true
    toastCenter?.success("Copied endpoint URL")
    Task { @MainActor in
      try? await Task.sleep(for: .seconds(1.5))
      copiedEndpoint = false
    }
  }

  private func syncDraft(from server: MCPRemoteServer) {
    name = server.name
    endpoint = server.endpoint.absoluteString
    authenticationKind = server.authentication.kind
    authenticationHeader = server.authentication.headerName ?? "X-API-Key"
    credential = ""
    additionalHeaders = MacAdditionalHeaderItem.items(from: server.additionalHeaders)
    headerEditorTarget = nil
    saveError = nil
  }

  private func requestNavigation(_ target: PendingNavigation) {
    guard !isSaving else { return }
    if hasUnsavedChanges {
      pendingNavigation = target
      showingDiscardAlert = true
    } else {
      performNavigation(target)
    }
  }

  private func performNavigation(_ target: PendingNavigation) {
    switch target {
    case .back:
      back()
    case .tools:
      openTools?()
    }
  }

  private func save(then nextNavigation: PendingNavigation? = nil) {
    guard canSave else { return }
    let headers: [String: String]
    do {
      headers = try MacAdditionalHeaderItem.validatedDictionary(
        from: additionalHeaders,
        policy: headerValidationPolicy
      )
    } catch {
      showingAdvanced = true
      saveError = error.localizedDescription
      return
    }

    let existingServerIDs = Set(mcp.servers.map(\.id))
    let existingServer = server
    isSaving = true
    saveError = nil
    Task { @MainActor in
      defer { isSaving = false }
      let newCredential: String?
      if authenticationKind == .none {
        newCredential = ""
      } else if credential.isEmpty, hasExistingCredential {
        newCredential = nil
      } else {
        newCredential = credential
      }

      let saved = await mcp.saveServer(
        existing: existingServer,
        name: name,
        endpoint: endpoint,
        authenticationKind: authenticationKind,
        authenticationHeader: authenticationHeader,
        credential: newCredential,
        additionalHeaders: headers,
        isEnabled: existingServer?.isEnabled ?? true
      )
      if saved {
        if let existingServer {
          if let updated = mcp.servers.first(where: { $0.id == existingServer.id }) {
            syncDraft(from: updated)
          }
          if let nextNavigation {
            performNavigation(nextNavigation)
          }
        } else {
          let createdID = mcp.servers.first(where: { !existingServerIDs.contains($0.id) })?.id
          if let nextNavigation {
            performNavigation(nextNavigation)
          } else if let onCreated {
            onCreated(createdID)
          } else {
            back()
          }
        }
      } else {
        saveError = mcp.consumeErrorMessage() ?? "Could not save MCP server."
      }
    }
  }
}

private struct MacMCPServerToolsCatalogView: View {
  @Bindable var mcp: MacMCPModel
  let server: MCPRemoteServer
  let back: () -> Void

  @State private var searchText = ""

  private var snapshot: MCPServerSnapshot? { mcp.snapshot(for: server.id) }
  private var isRefreshing: Bool { mcp.refreshingServerIDs.contains(server.id) }
  private var missingCredential: Bool {
    server.authentication.kind != .none && !mcp.hasCredential(server.id)
  }

  private var trimmedSearchQuery: String {
    searchText.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var allTools: [MCPRemoteTool] {
    snapshot?.tools ?? []
  }

  private var filteredTools: [MCPRemoteTool] {
    let query = trimmedSearchQuery
    guard !query.isEmpty else { return allTools }
    return allTools.filter {
      $0.remoteName.localizedCaseInsensitiveContains(query)
        || ($0.title?.localizedCaseInsensitiveContains(query) ?? false)
        || $0.description.localizedCaseInsensitiveContains(query)
    }
  }

  private var catalogState: MacMCPToolCatalogState {
    macMCPToolCatalogState(
      snapshot: snapshot,
      filteredToolCount: filteredTools.count,
      searchText: searchText
    )
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Button(action: back) {
          Label(server.name, systemImage: "chevron.left")
            .foregroundStyle(MacDesignTokens.Colors.accent)
        }
        .buttonStyle(MacActionButtonStyle(.subtle, size: .small))
        .keyboardShortcut(.cancelAction)

        Divider().frame(height: 24)

        VStack(alignment: .leading, spacing: 2) {
          Text("Tools")
            .font(.system(size: 14.5, weight: .semibold))
            .foregroundStyle(MacDesignTokens.Colors.textPrimary)
          Text(
            "\(allTools.count) discovered · Permissions are set per chat or project"
          )
          .font(.caption)
          .foregroundStyle(MacDesignTokens.Colors.textMuted)
        }

        Spacer()

        Button {
          Task { _ = await mcp.refresh(server.id) }
        } label: {
          HStack(spacing: 5) {
            if isRefreshing {
              ProgressView()
                .controlSize(.mini)
            } else {
              Image(systemName: "arrow.clockwise")
            }
            Text(isRefreshing ? "Refreshing…" : "Refresh")
          }
        }
        .buttonStyle(MacActionButtonStyle(.secondary, size: .small))
        .disabled(mcp.isBusy || !server.isEnabled || missingCredential)
      }
      .padding(.horizontal, 18)
      .frame(height: 62)
      .background(MacDesignTokens.Colors.surface.opacity(0.45))

      Divider()

      if !allTools.isEmpty {
        HStack(spacing: 12) {
          HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
              .font(.system(size: 12))
              .foregroundStyle(.secondary)
            TextField("Search tools", text: $searchText)
              .textFieldStyle(.plain)
              .font(.system(size: 13))
            if !searchText.isEmpty {
              Button {
                searchText = ""
              } label: {
                Image(systemName: "xmark.circle.fill")
                  .foregroundStyle(.tertiary)
              }
              .buttonStyle(.plain)
              .accessibilityLabel("Clear search")
            }
          }
          .padding(.horizontal, 10)
          .frame(height: 32)
          .frame(maxWidth: 340)
          .background(MacDesignTokens.Colors.surface, in: RoundedRectangle(cornerRadius: 8))
          .overlay {
            RoundedRectangle(cornerRadius: 8)
              .stroke(MacDesignTokens.Colors.separator.opacity(0.75), lineWidth: 0.5)
          }

          Spacer()

          Text(
            trimmedSearchQuery.isEmpty
              ? "\(allTools.count) \(allTools.count == 1 ? "tool" : "tools")"
              : "\(filteredTools.count) of \(allTools.count)"
          )
          .font(.caption.monospacedDigit())
          .foregroundStyle(MacDesignTokens.Colors.textMuted)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)

        Divider()
      }

      switch catalogState {
      case .notDiscovered:
        ContentUnavailableView {
          Label("Tools Not Discovered", systemImage: "wrench.and.screwdriver")
        } description: {
          Text("Refresh this server to discover its available tools.")
        } actions: {
          if server.isEnabled && !missingCredential {
            Button("Refresh Tools", systemImage: "arrow.clockwise") {
              Task { _ = await mcp.refresh(server.id) }
            }
            .buttonStyle(MacActionButtonStyle(.primary))
            .disabled(mcp.isBusy)
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      case .noTools:
        ContentUnavailableView {
          Label("No Tools Available", systemImage: "wrench.and.screwdriver")
        } description: {
          Text("This server returned no tools. Refresh to check again.")
        } actions: {
          if server.isEnabled && !missingCredential {
            Button("Refresh Tools", systemImage: "arrow.clockwise") {
              Task { _ = await mcp.refresh(server.id) }
            }
            .buttonStyle(MacActionButtonStyle(.secondary))
            .disabled(mcp.isBusy)
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      case .noSearchResults:
        ContentUnavailableView.search(text: trimmedSearchQuery)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      case .results:
        ScrollView {
          MacMCPInsetGroup {
            ForEach(Array(filteredTools.enumerated()), id: \.element.id) { index, tool in
              if index > 0 {
                Rectangle()
                  .fill(MacDesignTokens.Colors.separator.opacity(0.6))
                  .frame(height: 0.5)
                  .padding(.leading, 14)
              }
              MacMCPToolCatalogRow(tool: tool)
            }
          }
          .padding(16)
        }
      }
    }
    .background(MacDesignTokens.Colors.canvas)
  }
}

private struct MacMCPToolCatalogRow: View {
  let tool: MCPRemoteTool
  @State private var isHovered = false
  @State private var copiedSchema = false

  var body: some View {
    DisclosureGroup {
      VStack(alignment: .leading, spacing: 10) {
        if !tool.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          Text(tool.description)
            .font(.caption)
            .foregroundStyle(MacDesignTokens.Colors.textPrimary)
            .textSelection(.enabled)
        }
        HStack(spacing: 6) {
          Text("Remote name")
            .font(.caption)
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
          Text(tool.remoteName)
            .font(.caption.monospaced())
            .foregroundStyle(MacDesignTokens.Colors.textPrimary)
            .textSelection(.enabled)
        }
        DisclosureGroup {
          MacMCPScrollableCodeBlock(
            text: tool.inputSchema.macPrettyJSONString(),
            maxHeight: 220,
            copied: $copiedSchema
          )
          .padding(.top, 4)
        } label: {
          Text("Input schema")
            .font(.caption.weight(.medium))
        }
      }
      .padding(.vertical, 8)
    } label: {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        VStack(alignment: .leading, spacing: 3) {
          Text(tool.title ?? tool.remoteName)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(MacDesignTokens.Colors.textPrimary)
          if !tool.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text(tool.description)
              .font(.caption)
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
              .lineLimit(1)
          }
        }
        Spacer()
        HStack(spacing: 8) {
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
      .padding(.vertical, 8)
    }
    .padding(.horizontal, 14)
    .background(isHovered ? Color.primary.opacity(0.025) : Color.clear)
    .onHover { isHovered = $0 }
    .animation(.easeOut(duration: MacDesignTokens.Control.interactionDuration), value: isHovered)
  }
}

struct MacChatToolsView: View {
  @Bindable var mcp: MacMCPModel
  let conversationID: ConversationID?
  let projectID: ProjectID?
  let draftConfiguration: Binding<MCPChatToolConfiguration?>?
  let isGenerating: Bool
  let modelSupportsTools: Bool
  let manageServers: (() -> Void)?

  @Environment(\.dismiss) private var dismiss
  @Environment(MacWorkspaceModel.self) private var workspace
  @State private var showingAddServer = false
  @State private var localToastCenter = MacToastCenter()

  init(
    mcp: MacMCPModel,
    conversationID: ConversationID?,
    projectID: ProjectID? = nil,
    draftConfiguration: Binding<MCPChatToolConfiguration?>? = nil,
    presets: [ProjectToolPreset] = [],
    isGenerating: Bool = false,
    modelSupportsTools: Bool = true,
    manageServers: (() -> Void)? = nil
  ) {
    self.mcp = mcp
    self.conversationID = conversationID
    self.projectID = projectID
    self.draftConfiguration = draftConfiguration
    _ = presets
    self.isGenerating = isGenerating
    self.modelSupportsTools = modelSupportsTools
    self.manageServers = manageServers
  }

  private var project: ChatProject? {
    if let conversationID {
      return workspace.project(for: conversationID)
    }
    return workspace.project(projectID)
  }

  private var currentConfiguration: MCPChatToolConfiguration {
    if let conversationID {
      return mcp.chatConfiguration(for: conversationID)
    }
    return mcp.effectiveDraftConfiguration(
      draft: draftConfiguration?.wrappedValue,
      projectID: projectID
    )
  }

  private var inheritsProjectTools: Bool {
    if let conversationID {
      return mcp.inheritsProjectTools(conversationID)
    }
    return mcp.inheritsProjectToolsForDraft(
      draft: draftConfiguration?.wrappedValue,
      projectID: projectID
    )
  }

  private var hasChatOverride: Bool {
    if let conversationID {
      return mcp.hasChatOverride(conversationID)
    }
    return draftConfiguration?.wrappedValue != nil
  }

  private var isMutationDisabled: Bool {
    mcp.isBusy || isGenerating
  }

  private var headerSubtitle: String {
    let toolCount = mcp.activeToolCount(for: currentConfiguration)
    let toolSummary = "\(toolCount) active \(toolCount == 1 ? "tool" : "tools")"
    if inheritsProjectTools, let project {
      return "\(toolSummary) · Inheriting defaults from \(project.name)"
    }
    if hasChatOverride {
      return conversationID == nil
        ? "\(toolSummary) · Custom tools apply when this chat starts"
        : "\(toolSummary) · Custom configuration for this chat"
    }
    return toolSummary
  }

  var body: some View {
    Group {
      if showingAddServer {
        MacMCPServerSettingsView(
          mcp: mcp,
          server: nil,
          backTitle: "Chat Tools",
          back: { showingAddServer = false },
          onCreated: { _ in showingAddServer = false },
          openTools: nil,
          requestDelete: nil
        )
        .id("chat-tools-add-mcp-server")
      } else {
        VStack(spacing: 0) {
          HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
              Text("Chat Tools")
                .font(.headline)
              Text(headerSubtitle)
                .font(.caption)
                .foregroundStyle(MacDesignTokens.Colors.textMuted)
            }
            Spacer()

            if hasChatOverride, project != nil {
              Button("Reset") {
                resetToProjectDefaults()
              }
              .buttonStyle(MacActionButtonStyle(.secondary, size: .small))
              .help("Reset to Project Defaults")
              .disabled(isMutationDisabled)
            }

            if let manageServers, !mcp.servers.isEmpty {
              Button("Servers…", systemImage: "shippingbox") {
                dismiss()
                manageServers()
              }
              .buttonStyle(MacActionButtonStyle(.secondary, size: .small))
              .help("Manage MCP Servers")
            }

            Button("Done") { dismiss() }
              .buttonStyle(MacActionButtonStyle(.primary, size: .small))
              .keyboardShortcut(.cancelAction)
          }
          .padding(16)
          .background(MacDesignTokens.Colors.surface)

          Divider()

          MacMCPServerConfigurationList(
            mcp: mcp,
            configuration: currentConfiguration,
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
            manageServers: manageServers.map { handler in
              {
                dismiss()
                handler()
              }
            },
            setServerEnabled: { serverID, enabled in
              setServerEnabled(serverID, enabled: enabled)
            },
            setPolicy: { name, policy in
              setPolicy(name, policy: policy)
            },
            setAllPolicies: { serverID, policy in
              setAllPolicies(serverID, policy: policy)
            }
          )
        }
      }
    }
    .frame(
      width: MacDesignTokens.Sheet.standardWidth,
      height: MacDesignTokens.Sheet.standardHeight
    )
    .background(MacDesignTokens.Colors.canvas)
    .macToastOverlay(localToastCenter)
    .onChange(of: mcp.statusMessage) { _, message in
      guard let message else { return }
      localToastCenter.showStatus(message)
      mcp.statusMessage = nil
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

  private func resetToProjectDefaults() {
    if let conversationID {
      Task { _ = await mcp.removeChatConfiguration(conversationID) }
    } else {
      draftConfiguration?.wrappedValue = nil
    }
  }

  private func setServerEnabled(_ serverID: MCPServerID, enabled: Bool) {
    if let conversationID {
      Task {
        _ = await mcp.setChatServerEnabled(
          enabled,
          serverID: serverID,
          conversationID: conversationID
        )
      }
    } else {
      Task {
        let result = await mcp.updatedDraftServerEnabled(
          enabled,
          serverID: serverID,
          currentDraft: draftConfiguration?.wrappedValue,
          projectID: projectID
        )
        if result.succeeded {
          draftConfiguration?.wrappedValue = result.configuration
        }
      }
    }
  }

  private func setPolicy(_ name: String, policy: ChatToolPermissionPolicy) {
    if let conversationID {
      Task {
        _ = await mcp.setChatToolPolicy(
          policy,
          exposedToolName: name,
          conversationID: conversationID
        )
      }
    } else {
      let result = mcp.updatedDraftToolPolicy(
        policy,
        exposedToolName: name,
        currentDraft: draftConfiguration?.wrappedValue,
        projectID: projectID
      )
      if result.succeeded {
        draftConfiguration?.wrappedValue = result.configuration
      }
    }
  }

  private func setAllPolicies(_ serverID: MCPServerID, policy: ChatToolPermissionPolicy) {
    if let conversationID {
      Task {
        _ = await mcp.setAllChatToolPolicies(
          policy,
          serverID: serverID,
          conversationID: conversationID
        )
      }
    } else {
      let result = mcp.updatedDraftAllToolPolicies(
        policy,
        serverID: serverID,
        currentDraft: draftConfiguration?.wrappedValue,
        projectID: projectID
      )
      if result.succeeded {
        draftConfiguration?.wrappedValue = result.configuration
        localToastCenter.showStatus("Updated tool permissions")
      }
    }
  }
}

struct MacProjectToolsConfigurationView: View {
  @Bindable var mcp: MacMCPModel
  let configuration: MCPChatToolConfiguration
  var isDisabled: Bool = false
  var addServer: (() -> Void)? = nil
  var manageServers: (() -> Void)? = nil
  var showsGuidanceBanner: Bool = false
  var maxContentWidth: CGFloat? = 640
  let onConfigurationChange: (MCPChatToolConfiguration) -> Void
  @State private var showingAddServer = false

  var body: some View {
    if showingAddServer {
      MacMCPServerSettingsView(
        mcp: mcp,
        server: nil,
        backTitle: "Project Tools",
        back: { showingAddServer = false },
        onCreated: { _ in showingAddServer = false },
        openTools: nil,
        requestDelete: nil
      )
      .id("project-tools-add-mcp-server")
    } else {
      MacMCPServerConfigurationList(
        mcp: mcp,
        configuration: configuration,
        context: .project,
        isReadOnly: isDisabled,
        showsGuidanceBanner: showsGuidanceBanner,
        maxContentWidth: maxContentWidth,
        addServer: {
          if let addServer {
            addServer()
          } else if MacProAccess.requireMCPServerCapacity(currentCount: mcp.servers.count) {
            showingAddServer = true
          }
        },
        manageServers: manageServers,
        setServerEnabled: { serverID, enabled in
          var updated = configuration
          updated.enabledServerIDs.removeAll { $0 == serverID }
          if enabled { updated.enabledServerIDs.append(serverID) }
          updated.enabledServerIDs.sort { $0.rawValue < $1.rawValue }
          onConfigurationChange(updated)
        },
        setPolicy: { name, policy in
          var updated = configuration
          if policy == .ask {
            updated.toolPolicies.removeValue(forKey: name)
          } else {
            updated.toolPolicies[name] = policy
          }
          onConfigurationChange(updated)
        },
        setAllPolicies: { serverID, policy in
          var updated = configuration
          for binding in mcp.tools(for: serverID) {
            if policy == .ask {
              updated.toolPolicies.removeValue(forKey: binding.exposedName)
            } else {
              updated.toolPolicies[binding.exposedName] = policy
            }
          }
          onConfigurationChange(updated)
        }
      )
    }
  }
}

private struct MacMCPServerConfigurationList: View {
  @Bindable var mcp: MacMCPModel
  let configuration: MCPChatToolConfiguration
  let context: MacMCPConfigurationContext
  var isGenerating: Bool = false
  var modelSupportsTools: Bool = true
  var isReadOnly: Bool = false
  var showsGuidanceBanner: Bool = true
  var maxContentWidth: CGFloat? = nil
  var addServer: (() -> Void)? = nil
  var manageServers: (() -> Void)? = nil
  let setServerEnabled: (MCPServerID, Bool) -> Void
  let setPolicy: (String, ChatToolPermissionPolicy) -> Void
  var setAllPolicies: ((MCPServerID, ChatToolPermissionPolicy) -> Void)? = nil

  private var isMutationDisabled: Bool {
    isGenerating || isReadOnly || (mcp.isBusy && isChatContext)
  }

  private var showsTopWarningBar: Bool {
    isGenerating || !modelSupportsTools
  }

  var body: some View {
    VStack(spacing: 0) {
      if showsTopWarningBar {
        VStack(alignment: .leading, spacing: 8) {
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.08))

        Divider()
      }

      if mcp.servers.isEmpty {
        ContentUnavailableView {
          Label("No MCP Servers", systemImage: "shippingbox.and.arrow.backward")
        } description: {
          Text("Add a remote MCP server to discover and enable tools.")
        } actions: {
          if let addServer {
            Button("Add MCP Server", systemImage: "plus") {
              addServer()
            }
            .buttonStyle(MacActionButtonStyle(.primary))
            .disabled(mcp.isBusy || isReadOnly)
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 14) {
            if !isChatContext {
              Text("Servers")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(MacDesignTokens.Colors.textMuted)
                .textCase(.uppercase)
                .tracking(0.4)
                .padding(.leading, 4)
                .accessibilityAddTraits(.isHeader)
            }

            VStack(alignment: .leading, spacing: 10) {
              ForEach(mcp.servers) { server in
                MacMCPServerConfigCard(
                  mcp: mcp,
                  server: server,
                  configuration: configuration,
                  context: context,
                  isGenerating: isGenerating,
                  isReadOnly: isReadOnly,
                  isMutationDisabled: isMutationDisabled,
                  manageServers: manageServers,
                  setServerEnabled: { setServerEnabled(server.id, $0) },
                  setPolicy: setPolicy,
                  setAllPolicies: setAllPolicies.map { handler in
                    { policy in handler(server.id, policy) }
                  }
                )
              }
            }

            if showsGuidanceBanner {
              Text(context.guidance)
                .font(.caption)
                .foregroundStyle(MacDesignTokens.Colors.textMuted)
                .padding(.horizontal, 4)
                .padding(.top, 2)
            } else {
              Text("Changes save automatically. New tools default to Ask.")
                .font(.caption)
                .foregroundStyle(MacDesignTokens.Colors.textMuted)
                .padding(.horizontal, 4)
                .padding(.top, 2)
            }
          }
          .padding(.horizontal, 18)
          .padding(.vertical, 16)
          .frame(maxWidth: maxContentWidth ?? .infinity, alignment: .leading)
          .frame(maxWidth: .infinity)
        }
      }
    }
  }

  private var isChatContext: Bool {
    if case .chat = context { return true }
    return false
  }
}

private struct MacMCPServerConfigCard: View {
  @Bindable var mcp: MacMCPModel
  let server: MCPRemoteServer
  let configuration: MCPChatToolConfiguration
  let context: MacMCPConfigurationContext
  let isGenerating: Bool
  let isReadOnly: Bool
  let isMutationDisabled: Bool
  let manageServers: (() -> Void)?
  let setServerEnabled: (Bool) -> Void
  let setPolicy: (String, ChatToolPermissionPolicy) -> Void
  let setAllPolicies: ((ChatToolPermissionPolicy) -> Void)?

  @State private var isExpanded = false
  @State private var isHeaderHovered = false

  private var isEnabledInScope: Bool {
    configuration.isServerEnabled(server.id)
  }

  private var missingCredential: Bool {
    server.authentication.kind != .none && !mcp.hasCredential(server.id)
  }

  private var isRefreshing: Bool {
    mcp.refreshingServerIDs.contains(server.id)
  }

  private var tools: [MCPToolBinding] {
    mcp.tools(for: server.id)
  }

  private var activeCount: Int {
    tools.filter { configuration.policy(for: $0.exposedName) != .disabled }.count
  }

  private var snapshot: MCPServerSnapshot? {
    mcp.snapshot(for: server.id)
  }

  private var isServerAvailable: Bool {
    server.isEnabled && !missingCredential
  }

  private var canExpand: Bool {
    isServerAvailable && isEnabledInScope
  }

  var body: some View {
    MacMCPInsetGroup {
      headerRow

      if canExpand && isExpanded {
        Rectangle()
          .fill(MacDesignTokens.Colors.separator.opacity(0.6))
          .frame(height: 0.5)

        expandedToolsSection
      }
    }
    .onChange(of: isEnabledInScope) { oldValue, newValue in
      if !oldValue && newValue && isServerAvailable {
        withAnimation(.easeOut(duration: MacDesignTokens.Control.interactionDuration)) {
          isExpanded = true
        }
      } else if !newValue {
        isExpanded = false
      }
    }
  }

  private var headerRow: some View {
    HStack(spacing: 10) {
      HStack(spacing: 10) {
        if canExpand {
          Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
            .frame(width: 12)
        } else {
          Color.clear
            .frame(width: 12, height: 12)
        }

        MacMCPServerIcon(
          isEnabled: server.isEnabled,
          hasIssue: server.isEnabled && missingCredential,
          size: 30
        )

        VStack(alignment: .leading, spacing: 2) {
          Text(server.name)
            .font(.system(size: 13.5, weight: .semibold))
            .foregroundStyle(
              server.isEnabled
                ? MacDesignTokens.Colors.textPrimary
                : MacDesignTokens.Colors.textMuted
            )
            .lineLimit(1)
          statusSubtitle
        }

        Spacer(minLength: 8)
      }
      .contentShape(Rectangle())
      .onTapGesture {
        guard canExpand else { return }
        withAnimation(.easeOut(duration: MacDesignTokens.Control.interactionDuration)) {
          isExpanded.toggle()
        }
      }

      if !isServerAvailable {
        if let manageServers {
          Button("Open Servers", action: manageServers)
            .buttonStyle(MacActionButtonStyle(.secondary, size: .small))
        }
        if isEnabledInScope {
          serverToggle
        }
      } else {
        if isRefreshing {
          ProgressView()
            .controlSize(.small)
            .frame(width: 24, height: 24)
            .accessibilityLabel("Refreshing tools for \(server.name)")
        } else {
          Button {
            Task { _ = await mcp.refresh(server.id) }
          } label: {
            Image(systemName: "arrow.clockwise")
              .font(.system(size: 12, weight: .medium))
          }
          .buttonStyle(MacIconButtonStyle())
          .disabled(mcp.isBusy || isReadOnly)
          .help("Refresh tools for \(server.name)")
          .accessibilityLabel("Refresh tools for \(server.name)")
        }

        serverToggle
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
    .frame(minHeight: 54)
    .background(Color.primary.opacity(canExpand && isHeaderHovered ? 0.03 : 0))
    .onHover { isHeaderHovered = $0 }
    .animation(.easeOut(duration: MacDesignTokens.Control.interactionDuration), value: isHeaderHovered)
  }

  private var serverToggle: some View {
    Toggle(
      context.enableTitle,
      isOn: Binding(
        get: { isEnabledInScope },
        set: { setServerEnabled($0) }
      )
    )
    .labelsHidden()
    .toggleStyle(.switch)
    .controlSize(.small)
    .disabled(
      (!isServerAvailable && !isEnabledInScope)
        || mcp.isBusy
        || isGenerating
        || isReadOnly
    )
    .help(context.enableTitle)
    .accessibilityLabel("\(context.enableTitle): \(server.name)")
  }

  @ViewBuilder
  private var statusSubtitle: some View {
    if !server.isEnabled {
      Text("Globally disabled")
        .font(.caption)
        .foregroundStyle(MacDesignTokens.Colors.textMuted)
    } else if missingCredential {
      Text("Missing credential")
        .font(.caption)
        .foregroundStyle(.orange)
    } else if isEnabledInScope && !tools.isEmpty {
      Text("\(activeCount) of \(tools.count) \(tools.count == 1 ? "tool" : "tools") active")
        .font(.caption)
        .foregroundStyle(MacDesignTokens.Colors.textMuted)
    } else if isEnabledInScope && tools.isEmpty {
      Text("No cached tools — refresh to discover")
        .font(.caption)
        .foregroundStyle(MacDesignTokens.Colors.textMuted)
    } else if snapshot != nil {
      Text("\(tools.count) \(tools.count == 1 ? "tool" : "tools") discovered")
        .font(.caption)
        .foregroundStyle(MacDesignTokens.Colors.textMuted)
    } else {
      Text("Not discovered yet")
        .font(.caption)
        .foregroundStyle(MacDesignTokens.Colors.textMuted)
    }
  }

  @ViewBuilder
  private var expandedToolsSection: some View {
    if tools.isEmpty {
      HStack(spacing: 12) {
        Text("No cached tools yet.")
          .font(.caption)
          .foregroundStyle(MacDesignTokens.Colors.textMuted)
        Spacer()
        Button("Refresh Tools", systemImage: "arrow.clockwise") {
          Task { _ = await mcp.refresh(server.id) }
        }
        .buttonStyle(MacActionButtonStyle(.secondary, size: .small))
        .disabled(mcp.isBusy || isReadOnly)
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 12)
    } else {
      VStack(alignment: .leading, spacing: 0) {
        if tools.count > 1, let setAllPolicies {
          HStack(spacing: 10) {
            Text("\(activeCount) of \(tools.count) active")
              .font(.caption)
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
            Spacer()
            Menu {
              ForEach(ChatToolPermissionPolicy.allCases, id: \.self) { policy in
                Button("Set All to \(policy.displayName)") {
                  setAllPolicies(policy)
                }
              }
            } label: {
              MacMenuButtonLabel(title: "Set All", size: .small)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(isMutationDisabled)
          }
          .padding(.horizontal, 14)
          .padding(.vertical, 8)
          .background(MacDesignTokens.Colors.canvas.opacity(0.35))

          Rectangle()
            .fill(MacDesignTokens.Colors.separator.opacity(0.55))
            .frame(height: 0.5)
        }

        ForEach(Array(tools.enumerated()), id: \.element.id) { index, binding in
          if index > 0 {
            Rectangle()
              .fill(MacDesignTokens.Colors.separator.opacity(0.5))
              .frame(height: 0.5)
              .padding(.leading, 14)
          }
          toolPermissionRow(binding)
        }
      }
    }
  }

  private func toolPermissionRow(_ binding: MCPToolBinding) -> some View {
    let tool = binding.remoteTool
    let description = tool.description.trimmingCharacters(in: .whitespacesAndNewlines)
    let isReadOnlyTool = macMCPAnnotationBool("readOnlyHint", tool: tool) == true
    let isDestructiveTool = macMCPAnnotationBool("destructiveHint", tool: tool) == true

    return HStack(alignment: .center, spacing: 12) {
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 7) {
          Text(tool.title ?? tool.remoteName)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(MacDesignTokens.Colors.textPrimary)
            .lineLimit(1)
          if isReadOnlyTool {
            Label("Read-only", systemImage: "eye")
              .font(.caption2)
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
          }
          if isDestructiveTool {
            Label("Destructive", systemImage: "exclamationmark.triangle")
              .font(.caption2)
              .foregroundStyle(.orange)
          }
        }
        if !description.isEmpty {
          Text(description)
            .font(.caption)
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
        }
        if tool.title != nil {
          Text(tool.remoteName)
            .font(.caption2.monospaced())
            .foregroundStyle(.tertiary)
        }
      }

      Spacer(minLength: 8)

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
      .frame(width: 118)
      .disabled(isMutationDisabled)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
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
  @State private var copiedArguments = false

  private var isDestructive: Bool {
    request.destructiveHint == true
  }

  private var trimmedDescription: String {
    request.toolDescription.trimmingCharacters(in: .whitespacesAndNewlines)
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
          if !trimmedDescription.isEmpty {
            Text(trimmedDescription)
              .font(.caption)
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
              .fixedSize(horizontal: false, vertical: true)
          }
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
        MacMCPScrollableCodeBlock(
          text: request.arguments.macPrettyJSONString(),
          maxHeight: 220,
          copied: $copiedArguments
        )
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
    .onChange(of: request.id) { _, _ in
      isResolving = false
      copiedArguments = false
    }
  }

  private func submit(_ decision: MCPToolApprovalDecision) {
    guard !isResolving else { return }
    isResolving = true
    resolve(decision)
  }

  private var denyButton: some View {
    Button("Deny", role: .destructive) { submit(.deny) }
      .buttonStyle(MacActionButtonStyle(.destructive, size: .small))
  }

  @ViewBuilder
  private var allowOnceButton: some View {
    if isDestructive {
      Button("Allow Once") { submit(.allowOnce) }
        .buttonStyle(MacActionButtonStyle(.primary, size: .small, tint: Color.orange))
    } else {
      Button("Allow Once") { submit(.allowOnce) }
        .buttonStyle(MacActionButtonStyle(.secondary, size: .small))
    }
  }

  @ViewBuilder
  private var alwaysAllowButton: some View {
    if isDestructive {
      Button("Always Allow") { submit(.alwaysAllow) }
        .buttonStyle(MacActionButtonStyle(.secondary, size: .small))
    } else {
      Button("Always Allow") { submit(.alwaysAllow) }
        .buttonStyle(MacActionButtonStyle(.primary, size: .small))
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

  static func fieldError(
    for field: MCPElicitationField,
    storedValue: String
  ) -> String? {
    if field.kind == .string, !field.allowedValues.isEmpty {
      if storedValue.isEmpty {
        return field.isRequired ? "Choose an option." : nil
      }
      return field.allowedValues.contains(storedValue) ? nil : "Choose one of the allowed options."
    }

    let raw = storedValue.trimmingCharacters(in: .whitespacesAndNewlines)
    switch field.kind {
    case .boolean:
      return nil
    case .string:
      return field.isRequired && raw.isEmpty ? "This field is required." : nil
    case .integer:
      if raw.isEmpty {
        return field.isRequired ? "Enter a whole number." : nil
      }
      return Int(raw) != nil ? nil : "Enter a valid whole number."
    case .number:
      if raw.isEmpty {
        return field.isRequired ? "Enter a number." : nil
      }
      if let value = Double(raw), value.isFinite { return nil }
      return "Enter a valid number."
    case .stringArray:
      let items = parseStringArray(raw)
      if items.isEmpty {
        return field.isRequired ? "Enter at least one value (comma-separated)." : nil
      }
      if !field.allowedValues.isEmpty, !items.allSatisfy(field.allowedValues.contains) {
        return "Values must be from: \(field.allowedValues.joined(separator: ", "))"
      }
      return nil
    }
  }

  static func canSubmit(
    mode: MCPElicitationMode,
    url: URL?,
    fields: [MCPElicitationField],
    textValues: [String: String]
  ) -> Bool {
    guard mode == .form else { return url != nil }
    return fields.allSatisfy { field in
      fieldError(for: field, storedValue: textValues[field.name] ?? "") == nil
    }
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

  @Environment(\.openURL) private var openURL
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
            Button {
              openURL(url)
            } label: {
              Label("Open \(url.host ?? url.absoluteString)", systemImage: "arrow.up.right.square")
            }
            .buttonStyle(MacActionButtonStyle(.primary, size: .small))
          }
        } else {
          Label(
            "This server requested a browser step without providing a valid URL. Cancel or decline to continue.",
            systemImage: "exclamationmark.triangle.fill"
          )
          .font(.caption)
          .foregroundStyle(.orange)
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
        .disabled(isResolving)
      }
    }
    .padding(14)
    .background(MacDesignTokens.Colors.surface, in: RoundedRectangle(cornerRadius: MacDesignTokens.Radius.large))
    .overlay {
      RoundedRectangle(cornerRadius: MacDesignTokens.Radius.large)
        .stroke(MacDesignTokens.Colors.separator, lineWidth: 1)
    }
    .onChange(of: request.id) { _, _ in
      let initial = MacMCPElicitationFormSupport.initialValues(for: request.fields)
      textValues = initial.text
      boolValues = initial.bools
      isResolving = false
    }
  }

  private func submitDecision(_ decision: MCPElicitationDecision) {
    guard !isResolving else { return }
    isResolving = true
    resolve(decision)
  }

  private var cancelButton: some View {
    Button("Cancel") { submitDecision(.cancel) }
      .buttonStyle(MacActionButtonStyle(.secondary, size: .small))
  }

  private var declineButton: some View {
    Button("Decline", role: .destructive) { submitDecision(.decline) }
      .buttonStyle(MacActionButtonStyle(.destructive, size: .small))
  }

  private var submitButton: some View {
    Button(request.mode == .url ? "Continue" : "Submit") {
      submitDecision(.accept(responseContent()))
    }
    .buttonStyle(MacActionButtonStyle(.primary, size: .small))
    .disabled(!canSubmit || isResolving)
  }

  @ViewBuilder
  private var formFields: some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach(request.fields) { field in
        let currentValue = textValues[field.name] ?? ""
        let validationError = MacMCPElicitationFormSupport.fieldError(
          for: field,
          storedValue: currentValue
        )
        let showInlineError = !currentValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          && validationError != nil

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
            .textFieldStyle(.roundedBorder)
            if field.kind == .stringArray, !field.allowedValues.isEmpty {
              Text("Allowed: \(field.allowedValues.joined(separator: ", "))")
                .font(.caption2)
                .foregroundStyle(MacDesignTokens.Colors.textMuted)
            }
          }

          if showInlineError, let validationError {
            Text(validationError)
              .font(.caption2)
              .foregroundStyle(.red)
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

  @State private var copiedArguments = false

  var body: some View {
    DisclosureGroup {
      MacMCPScrollableCodeBlock(
        text: call.arguments.macPrettyJSONString(),
        maxHeight: 200,
        copied: $copiedArguments
      )
      .padding(.top, 6)
    } label: {
      HStack(spacing: 8) {
        ProgressView().controlSize(.mini)
        Text(displayName)
          .font(.system(size: 12, weight: .semibold))
          .lineLimit(1)
        Spacer()
        Text(waitingForApproval ? "Waiting for approval" : "Running…")
          .font(.caption2)
          .foregroundStyle(waitingForApproval ? Color.orange : MacDesignTokens.Colors.textMuted)
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

  @State private var copiedArguments = false
  @State private var copiedResult = false

  private var failed: Bool { result?.isError == true || result == nil }

  var body: some View {
    DisclosureGroup {
      VStack(alignment: .leading, spacing: 10) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Arguments").font(.caption.weight(.semibold))
          MacMCPScrollableCodeBlock(
            text: call.arguments.macPrettyJSONString(),
            maxHeight: 220,
            copied: $copiedArguments
          )
        }
        if let result {
          VStack(alignment: .leading, spacing: 4) {
            Text(result.isError ? "Error" : "Result")
              .font(.caption.weight(.semibold))
            MacMCPScrollableCodeBlock(
              text: result.content.macPrettyJSONString(),
              maxHeight: 260,
              copied: $copiedResult
            )
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
          .foregroundStyle(failed ? Color.orange : Color.green)
        Text(displayName)
          .font(.system(size: 12, weight: .semibold))
          .lineLimit(2)
        Spacer()
        Text(failed ? "Failed" : "Done")
          .font(.caption2)
          .foregroundStyle(failed ? Color.orange : MacDesignTokens.Colors.textMuted)
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

private struct MacMCPScrollableCodeBlock: View {
  let text: String
  let maxHeight: CGFloat
  @Binding var copied: Bool

  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.macAppTheme) private var theme

  private var needsScrolling: Bool {
    text.count > 450 || text.components(separatedBy: .newlines).count > 10
  }

  private var highlightedJSON: AttributedString {
    MacJSONSyntaxHighlighter.highlight(
      text,
      isDark: colorScheme == .dark,
      accentColor: theme.accent,
      textColor: theme.textPrimary,
      mutedColor: theme.textMuted
    )
  }

  var body: some View {
    ZStack(alignment: .topTrailing) {
      Group {
        if needsScrolling {
          ScrollView([.vertical, .horizontal]) {
            codeText
          }
          .frame(height: maxHeight)
        } else {
          codeText
        }
      }
      .background(
        theme.codeSurface,
        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
          .stroke(theme.separator.opacity(0.65), lineWidth: 0.5)
      }

      Button {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        Task { @MainActor in
          try? await Task.sleep(for: .seconds(1.5))
          copied = false
        }
      } label: {
        Image(systemName: copied ? "checkmark" : "doc.on.doc")
          .font(.system(size: 10.5, weight: .semibold))
          .foregroundStyle(copied ? theme.accent : theme.textMuted)
          .frame(width: 22, height: 22)
          .background(theme.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: 5))
          .overlay {
            RoundedRectangle(cornerRadius: 5)
              .stroke(theme.separator.opacity(0.6), lineWidth: 0.5)
          }
      }
      .buttonStyle(.plain)
      .padding(5)
      .help(copied ? "Copied" : "Copy payload")
      .accessibilityLabel(copied ? "Copied" : "Copy payload")
    }
  }

  private var codeText: some View {
    Text(highlightedJSON)
      .font(.system(size: 11.5, design: .monospaced))
      .textSelection(.enabled)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(8)
      .padding(.trailing, 28)
  }
}

enum MacJSONSyntaxHighlighter {
  private static let tokenRegex = try? NSRegularExpression(
    pattern: #"("(?:\\.|[^"\\])*")(\s*:)?|\b(true|false|null)\b|-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?"#
  )

  static func highlight(
    _ source: String,
    isDark: Bool,
    accentColor: Color,
    textColor: Color,
    mutedColor: Color
  ) -> AttributedString {
    var attributed = AttributedString(source)
    attributed.foregroundColor = textColor

    guard let regex = tokenRegex, !source.isEmpty else { return attributed }

    let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("{") || trimmed.hasPrefix("[") else { return attributed }

    let fullRange = NSRange(source.startIndex..<source.endIndex, in: source)
    let stringColor = isDark ? Color(red: 0.56, green: 0.84, blue: 0.55) : Color(red: 0.12, green: 0.50, blue: 0.22)
    let numberColor = isDark ? Color(red: 0.96, green: 0.72, blue: 0.44) : Color(red: 0.74, green: 0.36, blue: 0.05)
    let keywordColor = isDark ? Color(red: 0.82, green: 0.62, blue: 0.98) : Color(red: 0.55, green: 0.20, blue: 0.76)

    for match in regex.matches(in: source, range: fullRange) {
      guard let swiftRange = Range(match.range, in: source),
        let attrLower = AttributedString.Index(swiftRange.lowerBound, within: attributed),
        let attrUpper = AttributedString.Index(swiftRange.upperBound, within: attributed)
      else { continue }

      if match.range(at: 1).location != NSNotFound {
        if match.range(at: 2).location != NSNotFound {
          if let keyRange = Range(match.range(at: 1), in: source),
            let keyLower = AttributedString.Index(keyRange.lowerBound, within: attributed),
            let keyUpper = AttributedString.Index(keyRange.upperBound, within: attributed)
          {
            attributed[keyLower..<keyUpper].foregroundColor = accentColor
          }
          if let colonRange = Range(match.range(at: 2), in: source),
            let colonLower = AttributedString.Index(colonRange.lowerBound, within: attributed),
            let colonUpper = AttributedString.Index(colonRange.upperBound, within: attributed)
          {
            attributed[colonLower..<colonUpper].foregroundColor = mutedColor
          }
        } else {
          attributed[attrLower..<attrUpper].foregroundColor = stringColor
        }
      } else if match.range(at: 3).location != NSNotFound {
        attributed[attrLower..<attrUpper].foregroundColor = keywordColor
      } else {
        attributed[attrLower..<attrUpper].foregroundColor = numberColor
      }
    }

    return attributed
  }
}

private struct MacMCPInlineErrorBanner: View {
  let message: String
  let dismiss: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.red)
        .padding(.top, 1)
      Text(message)
        .font(.caption)
        .foregroundStyle(MacDesignTokens.Colors.textPrimary)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 4)
      Button(action: dismiss) {
        Image(systemName: "xmark")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(MacDesignTokens.Colors.textMuted)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Dismiss error")
    }
    .padding(10)
    .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(Color.red.opacity(0.28), lineWidth: 0.75)
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
