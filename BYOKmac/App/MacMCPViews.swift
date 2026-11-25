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

  @Environment(PurchaseManager.self) private var purchaseManager
  @State private var showingAddServer = false
  @State private var selectedServerID: MCPServerID?
  @State private var deleteServer: MCPRemoteServer?

  private var selectedServer: MCPRemoteServer? {
    guard let selectedServerID else { return nil }
    return mcp.servers.first { $0.id == selectedServerID }
  }

  private var isCheckingEntitlement: Bool {
    purchaseManager.entitlementState == .checking
  }

  private var enabledServerCount: Int {
    mcp.servers.filter { $0.isEnabled && !mcp.isServerRestricted($0.id) }.count
  }

  private var discoveredToolCount: Int {
    mcp.servers.reduce(0) { count, server in
      guard !mcp.isServerRestricted(server.id) else { return count }
      return count + (mcp.snapshot(for: server.id)?.tools.count ?? 0)
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
    .onChange(of: mcp.servers.map(\.id)) { _, ids in
      if let selectedServerID, !ids.contains(selectedServerID) {
        self.selectedServerID = nil
      }
    }
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
        Task { @MainActor in
          if await mcp.deleteServer(server.id), selectedServerID == server.id {
            selectedServerID = nil
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

  private var serverList: some View {
    VStack(spacing: 0) {
      HStack(alignment: .center, spacing: 12) {
        VStack(alignment: .leading, spacing: 3) {
          Text("Connect external tools and services to BYOKchat.")
            .font(.subheadline)
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
          Text("\(enabledServerCount) enabled · \(discoveredToolCount) \(discoveredToolCount == 1 ? "tool" : "tools") discovered")
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        Spacer()
        Button("Add Server", systemImage: "plus") {
          beginAddServer()
        }
        .buttonStyle(MacActionButtonStyle(.primary))
        .disabled(isCheckingEntitlement)
      }
      .padding(.horizontal, 18)
      .padding(.vertical, 14)

      Divider()

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
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 16) {
            if !partition.active.isEmpty {
              VStack(alignment: .leading, spacing: 10) {
                if partition.showsSectionHeaders {
                  serverSectionHeader("Active", count: partition.active.count)
                }
                ForEach(partition.active) { server in
                  serverCard(server)
                }
              }
            }

            if !partition.disabled.isEmpty {
              VStack(alignment: .leading, spacing: 10) {
                serverSectionHeader("Disabled", count: partition.disabled.count)
                ForEach(partition.disabled) { server in
                  serverCard(server)
                }
              }
            }
          }
          .padding(16)
        }
      }
    }
  }

  private func beginAddServer() {
    guard MacProAccess.requireMCPServerCapacity(currentCount: mcp.servers.count) else { return }
    showingAddServer = true
  }

  private func serverSectionHeader(_ title: String, count: Int) -> some View {
    HStack(spacing: 6) {
      Text(title)
        .font(.caption.weight(.semibold))
        .foregroundStyle(MacDesignTokens.Colors.textMuted)
      Text("\(count)")
        .font(.caption2.weight(.medium))
        .foregroundStyle(MacDesignTokens.Colors.textMuted.opacity(0.8))
        .padding(.horizontal, 6)
        .padding(.vertical, 1.5)
        .background(MacDesignTokens.Colors.surface, in: Capsule())
    }
    .accessibilityAddTraits(.isHeader)
  }

  private func serverCard(_ server: MCPRemoteServer) -> some View {
    let isRestricted = mcp.isServerRestricted(server.id)
    let missingCredential = server.authentication.kind != .none && !mcp.hasCredential(server.id)
    let isRefreshing = mcp.refreshingServerIDs.contains(server.id)
    return MacMCPServerRowCard(
      server: server,
      snapshot: mcp.snapshot(for: server.id),
      statusTitle: statusTitle(server, isRestricted: isRestricted, missingCredential: missingCredential),
      statusColor: statusColor(server, isRestricted: isRestricted, missingCredential: missingCredential),
      isRestricted: isRestricted,
      isRefreshing: isRefreshing,
      isBusy: mcp.isBusy,
      open: { selectedServerID = server.id },
      setEnabled: { enabled in
        Task { _ = await mcp.setEnabled(enabled, serverID: server.id) }
      },
      refresh: {
        Task { _ = await mcp.refresh(server.id) }
      },
      upgrade: {
        MacProAccess.requestUpgrade(.mcpServers)
      },
      requestDelete: {
        deleteServer = server
      }
    )
  }

  private func statusTitle(
    _ server: MCPRemoteServer,
    isRestricted: Bool,
    missingCredential: Bool
  ) -> String {
    if isRestricted { return "Requires BYOK Pro" }
    if server.isEnabled && missingCredential { return "Missing credential" }
    return macMCPServerPresentationState(
      server: server,
      snapshot: mcp.snapshot(for: server.id)
    ).rawValue
  }

  private func statusColor(
    _ server: MCPRemoteServer,
    isRestricted: Bool,
    missingCredential: Bool
  ) -> Color {
    if isRestricted || (server.isEnabled && missingCredential) { return .orange }
    switch macMCPServerPresentationState(server: server, snapshot: mcp.snapshot(for: server.id)) {
    case .disabled:
      return MacDesignTokens.Colors.textMuted.opacity(0.55)
    case .needsDiscovery:
      return .orange
    case .discovered:
      return MacDesignTokens.Colors.accent
    }
  }
}

private struct MacMCPServerRowCard: View {
  let server: MCPRemoteServer
  let snapshot: MCPServerSnapshot?
  let statusTitle: String
  let statusColor: Color
  let isRestricted: Bool
  let isRefreshing: Bool
  let isBusy: Bool
  let open: () -> Void
  let setEnabled: (Bool) -> Void
  let refresh: () -> Void
  let upgrade: () -> Void
  let requestDelete: () -> Void

  @State private var isHovered = false

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
    HStack(spacing: 12) {
      Button(action: open) {
        HStack(spacing: 12) {
          Circle()
            .fill(statusColor)
            .frame(width: 9, height: 9)
            .accessibilityHidden(true)

          VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
              Text(server.name)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(MacDesignTokens.Colors.textPrimary)
              if isRestricted {
                Label("Pro", systemImage: "crown.fill")
                  .font(.caption2.weight(.semibold))
                  .foregroundStyle(.orange)
                  .padding(.horizontal, 6)
                  .padding(.vertical, 1.5)
                  .background(Color.orange.opacity(0.14), in: Capsule())
              } else if let snapshot {
                Text("\(snapshot.tools.count) \(snapshot.tools.count == 1 ? "tool" : "tools")")
                  .font(.caption2)
                  .foregroundStyle(MacDesignTokens.Colors.textMuted)
              }
            }
            Text(statusTitle)
              .font(.caption)
              .foregroundStyle(
                statusColor == .orange ? Color.orange : MacDesignTokens.Colors.textMuted
              )
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

      if isRefreshing {
        ProgressView()
          .controlSize(.small)
          .accessibilityLabel("Refreshing \(server.name)")
      }

      if isRestricted {
        Button("Upgrade", systemImage: "crown.fill", action: upgrade)
          .buttonStyle(MacActionButtonStyle(.secondary, size: .small))
      } else {
        Toggle(
          "Enabled",
          isOn: Binding(
            get: { server.isEnabled },
            set: { setEnabled($0) }
          )
        )
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(.small)
        .disabled(isBusy)
      }

      Menu {
        Button("Configure", systemImage: "slider.horizontal.3", action: open)
        if !isRestricted {
          Button("Refresh Tools", systemImage: "arrow.clockwise", action: refresh)
            .disabled(isBusy || !server.isEnabled)
        } else {
          Button("Upgrade to Pro…", systemImage: "crown.fill", action: upgrade)
        }
        Divider()
        Button("Delete…", systemImage: "trash", role: .destructive, action: requestDelete)
      } label: {
        MacIconMenuLabel(systemImage: "ellipsis")
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .help("Server actions")
    }
    .padding(14)
    .background(MacDesignTokens.Colors.surface, in: shape)
    .overlay {
      if isHovered {
        shape.fill(Color.primary.opacity(0.025))
          .allowsHitTesting(false)
      }
    }
    .overlay {
      shape.stroke(
        isHovered
          ? MacDesignTokens.Colors.accent.opacity(0.35)
          : MacDesignTokens.Colors.separator.opacity(0.8),
        lineWidth: 0.75
      )
    }
    .onHover { isHovered = $0 }
    .animation(.easeOut(duration: MacDesignTokens.Control.interactionDuration), value: isHovered)
    .contextMenu {
      Button("Configure", systemImage: "slider.horizontal.3", action: open)
      if !isRestricted {
        Button("Refresh Tools", systemImage: "arrow.clockwise", action: refresh)
          .disabled(isBusy || !server.isEnabled)
      } else {
        Button("Upgrade to Pro…", systemImage: "crown.fill", action: upgrade)
      }
      Divider()
      Button("Delete…", systemImage: "trash", role: .destructive, action: requestDelete)
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
  @State private var copiedEndpoint = false

  private var snapshot: MCPServerSnapshot? { mcp.snapshot(for: server.id) }
  private var isRestricted: Bool { mcp.isServerRestricted(server.id) }
  private var isRefreshing: Bool { mcp.refreshingServerIDs.contains(server.id) }
  private var missingCredential: Bool {
    server.authentication.kind != .none && !mcp.hasCredential(server.id)
  }

  private var presentationState: MacMCPServerPresentationState {
    macMCPServerPresentationState(server: server, snapshot: snapshot)
  }

  private var trimmedSearchQuery: String {
    searchText.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var filteredTools: [MCPRemoteTool] {
    guard let tools = snapshot?.tools else { return [] }
    let query = trimmedSearchQuery
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
        Button {
          dismissDetail()
        } label: {
          Label("MCP Servers", systemImage: "chevron.left")
            .foregroundStyle(MacDesignTokens.Colors.accent)
        }
        .buttonStyle(MacActionButtonStyle(.subtle, size: .small))
        Divider().frame(height: 18)
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 6) {
            Text(server.name).font(.headline)
            if isRestricted {
              Label("Pro", systemImage: "crown.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.orange)
                .padding(.horizontal, 6)
                .padding(.vertical, 1.5)
                .background(Color.orange.opacity(0.14), in: Capsule())
            }
          }
          Text(
            isRestricted
              ? "Requires BYOK Pro"
              : (server.isEnabled && missingCredential ? "Missing credential" : presentationState.rawValue)
          )
          .font(.caption)
          .foregroundStyle(
            (isRestricted || (server.isEnabled && missingCredential))
              ? Color.orange
              : MacDesignTokens.Colors.textMuted
          )
        }
        Spacer()
        if isRestricted {
          Button("Upgrade to Pro", systemImage: "crown.fill") {
            MacProAccess.requestUpgrade(.mcpServers)
          }
          .buttonStyle(MacActionButtonStyle(.primary, size: .small))
        } else {
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
      }
      .padding(.horizontal, 18)
      .padding(.vertical, 12)

      Divider()

      if isRestricted {
        HStack(spacing: 10) {
          Image(systemName: "crown.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.orange)
          Text("This restored MCP server exceeds the Free tier limit. Upgrade to BYOK Pro to use or edit it, or delete another server to free a slot.")
            .font(.caption)
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
          Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .background(Color.orange.opacity(0.08))
        Divider()
      }

      MacSegmentedControl(
        options: MacMCPServerDetailTab.allCases,
        selection: $tab,
        title: \.rawValue
      )
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
    .onChange(of: server.id) { _, _ in
      tab = .overview
      searchText = ""
      copiedEndpoint = false
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
          let toolCount = snapshot?.tools.count ?? 0
          statusMetric(
            "\(toolCount) \(toolCount == 1 ? "tool" : "tools")",
            systemImage: "wrench.and.screwdriver"
          )
          if let snapshot {
            statusMetric("MCP \(snapshot.protocolVersion)", systemImage: "network")
          }
          Spacer()
          Button {
            Task { _ = await mcp.refresh(server.id) }
          } label: {
            HStack(spacing: 6) {
              if isRefreshing {
                ProgressView()
                  .controlSize(.mini)
              } else {
                Image(systemName: "arrow.clockwise")
              }
              Text(isRefreshing ? "Refreshing…" : "Refresh Tools")
            }
          }
          .buttonStyle(MacActionButtonStyle(.secondary))
          .disabled(mcp.isBusy || !server.isEnabled || isRestricted || missingCredential)
        }

        detailCard("Server") {
          LabeledContent("Name", value: server.name)
          LabeledContent("Endpoint", value: server.endpoint.absoluteString)
            .textSelection(.enabled)
          LabeledContent("Authentication", value: authenticationDisplayTitle)
          LabeledContent("Credential") {
            credentialStatusText
          }
        }

        if let snapshot {
          detailCard("Discovery") {
            LabeledContent("Protocol", value: snapshot.protocolVersion)
            LabeledContent("Mode", value: snapshot.era == .modern ? "Modern" : "Legacy fallback")
            if let info = snapshot.serverInfo {
              LabeledContent("Server", value: "\(info.name) \(info.version)")
            }
            LabeledContent(
              "Last refreshed",
              value: snapshot.refreshedAt.formatted(date: .abbreviated, time: .shortened)
            )
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
          .buttonStyle(MacActionButtonStyle(.secondary))
          .disabled(isRestricted)
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
        .padding(.horizontal, 9)
        .frame(height: 30)
        .frame(maxWidth: 300)
        .background(MacDesignTokens.Colors.surface, in: RoundedRectangle(cornerRadius: 7))
        .overlay {
          RoundedRectangle(cornerRadius: 7)
            .stroke(MacDesignTokens.Colors.separator.opacity(0.75), lineWidth: 0.5)
        }

        Spacer()

        Text("Permissions are configured per chat or project.")
          .font(.caption)
          .foregroundStyle(MacDesignTokens.Colors.textMuted)

        Button {
          Task { _ = await mcp.refresh(server.id) }
        } label: {
          HStack(spacing: 5) {
            if isRefreshing {
              ProgressView().controlSize(.mini)
            } else {
              Image(systemName: "arrow.clockwise")
            }
            Text("Refresh")
          }
        }
        .buttonStyle(MacActionButtonStyle(.secondary, size: .small))
        .disabled(mcp.isBusy || !server.isEnabled || isRestricted || missingCredential)
      }
      .padding(14)

      Divider()

      switch macMCPToolCatalogState(
        snapshot: snapshot,
        filteredToolCount: filteredTools.count,
        searchText: searchText
      ) {
      case .notDiscovered:
        ContentUnavailableView {
          Label("Tools Not Discovered", systemImage: "wrench.and.screwdriver")
        } description: {
          Text("Refresh this server to discover its available tools.")
        } actions: {
          if server.isEnabled && !isRestricted && !missingCredential {
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
          if server.isEnabled && !isRestricted && !missingCredential {
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
          LazyVStack(spacing: 0) {
            ForEach(filteredTools) { tool in
              MacMCPToolCatalogRow(tool: tool)
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
          LabeledContent("Endpoint") {
            HStack(spacing: 8) {
              Text(server.endpoint.absoluteString)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
              Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(server.endpoint.absoluteString, forType: .string)
                copiedEndpoint = true
                Task { @MainActor in
                  try? await Task.sleep(for: .seconds(1.5))
                  copiedEndpoint = false
                }
              } label: {
                Image(systemName: copiedEndpoint ? "checkmark" : "doc.on.doc")
                  .font(.caption)
              }
              .buttonStyle(MacIconButtonStyle())
              .help("Copy endpoint URL")
            }
          }
          LabeledContent("Authentication", value: authenticationDisplayTitle)
          LabeledContent("Credential") {
            credentialStatusText
          }
          if server.additionalHeaders.isEmpty {
            LabeledContent("Additional Headers", value: "None")
          } else {
            let names = server.additionalHeaders.keys.sorted().joined(separator: ", ")
            LabeledContent("Additional Headers") {
              Text("\(server.additionalHeaders.count) (\(names))")
                .foregroundStyle(MacDesignTokens.Colors.textMuted)
                .lineLimit(2)
            }
          }
        }

        HStack {
          Button("Delete Server…", role: .destructive) { requestDelete() }
            .buttonStyle(MacActionButtonStyle(.destructive))
          Spacer()
          Button("Edit Connection…", systemImage: "pencil") { showingConnectionEditor = true }
            .buttonStyle(MacActionButtonStyle(.secondary))
            .disabled(isRestricted)
        }
      }
      .padding(18)
    }
  }

  private var authenticationDisplayTitle: String {
    switch server.authentication.kind {
    case .none:
      return "None"
    case .bearer:
      return "Bearer Token"
    case .customHeader:
      if let header = server.authentication.headerName?.trimmingCharacters(in: .whitespacesAndNewlines),
        !header.isEmpty
      {
        return "Custom Header (\(header))"
      }
      return "Custom Header"
    }
  }

  @ViewBuilder
  private var credentialStatusText: some View {
    if server.authentication.kind == .none {
      Text("None")
        .foregroundStyle(MacDesignTokens.Colors.textMuted)
    } else if mcp.hasCredential(server.id) {
      Text("Stored in Keychain")
    } else {
      Label("Missing", systemImage: "exclamationmark.triangle.fill")
        .font(.caption)
        .foregroundStyle(.orange)
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
            .textSelection(.enabled)
        }
        LabeledContent("Remote name", value: tool.remoteName)
          .font(.caption)
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
          if !tool.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text(tool.description)
              .font(.caption)
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
              .lineLimit(1)
          }
        }
        Spacer()
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
      .padding(.vertical, 8)
    }
    .padding(.horizontal, 16)
    .background(isHovered ? Color.primary.opacity(0.025) : Color.clear)
    .onHover { isHovered = $0 }
    .animation(.easeOut(duration: MacDesignTokens.Control.interactionDuration), value: isHovered)
  }
}

private struct MacMCPServerConnectionEditorView: View {
  @Bindable var mcp: MacMCPModel
  let server: MCPRemoteServer?

  @Environment(\.dismiss) private var dismiss
  @FocusState private var nameFocused: Bool
  @State private var name: String
  @State private var endpoint: String
  @State private var authenticationKind: MCPAuthenticationKind
  @State private var authenticationHeader: String
  @State private var credential = ""
  @State private var additionalHeaders: [MacAdditionalHeaderItem]
  @State private var headerEditorTarget: MacAdditionalHeaderEditorTarget?
  @State private var showingAdvanced: Bool
  @State private var isSaving = false
  @State private var saveError: String?

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

  private var hasExistingCredential: Bool {
    guard let server else { return false }
    return mcp.hasCredential(server.id)
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

  private var canSave: Bool {
    guard !isSaving else { return false }
    guard !hasInvalidAdditionalHeaders else { return false }
    guard !trimmedName.isEmpty, isEndpointValid else { return false }
    if authenticationKind == .customHeader, trimmedAuthHeader.isEmpty { return false }
    if requiresNewCredential { return false }
    return true
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Text(server == nil ? "Add MCP Server" : "Edit Connection")
          .font(.headline)
        Spacer()
        if isSaving {
          HStack(spacing: 6) {
            ProgressView()
              .controlSize(.small)
            Text("Connecting…")
              .font(.caption)
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
          }
          .padding(.trailing, 4)
        }
        Button("Cancel") { dismiss() }
          .buttonStyle(MacActionButtonStyle(.secondary))
          .keyboardShortcut(.cancelAction)
          .disabled(isSaving)
        Button(server == nil ? "Add Server" : "Save") { save() }
          .buttonStyle(MacActionButtonStyle(.primary))
          .keyboardShortcut(.defaultAction)
          .disabled(!canSave)
      }
      .padding(16)
      .background(MacDesignTokens.Colors.surface)

      Divider()

      VStack(spacing: 0) {
        if let saveError {
          MacMCPInlineErrorBanner(message: saveError) {
            self.saveError = nil
          }
          .padding([.horizontal, .top], 16)
        }

        Form {
          Section("Server") {
            TextField("Name", text: $name)
              .textFieldStyle(.roundedBorder)
              .focused($nameFocused)
            TextField("Server URL", text: $endpoint, prompt: Text("https://example.com/mcp"))
              .textFieldStyle(.roundedBorder)
            if let endpointValidationHint {
              Text(endpointValidationHint)
                .font(.caption)
                .foregroundStyle(.red)
            }
          }

          Section("Authentication") {
            Picker("Authentication", selection: $authenticationKind) {
              Text("None").tag(MCPAuthenticationKind.none)
              Text("Bearer Token").tag(MCPAuthenticationKind.bearer)
              Text("Custom Header").tag(MCPAuthenticationKind.customHeader)
            }
            if authenticationKind == .customHeader {
              TextField("Header Name", text: $authenticationHeader)
                .textFieldStyle(.roundedBorder)
              if trimmedAuthHeader.isEmpty {
                Text("Enter the HTTP header name for this credential.")
                  .font(.caption)
                  .foregroundStyle(.red)
              }
            }
            if authenticationKind != .none {
              SecureField(credentialPlaceholder, text: $credential)
                .textFieldStyle(.roundedBorder)
              if requiresNewCredential {
                Text("Enter a credential before saving.")
                  .font(.caption)
                  .foregroundStyle(.orange)
              }
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
        .scrollContentBackground(.hidden)
        .padding(10)
        .disabled(isSaving)
      }
    }
    .frame(width: 560, height: 540)
    .background(MacDesignTokens.Colors.canvas)
    .onAppear {
      nameFocused = true
    }
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
    guard hasExistingCredential else { return "Credential" }
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
      saveError = error.localizedDescription
      return
    }

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
        existing: server,
        name: name,
        endpoint: endpoint,
        authenticationKind: authenticationKind,
        authenticationHeader: authenticationHeader,
        credential: newCredential,
        additionalHeaders: headers,
        isEnabled: server?.isEnabled ?? true
      )
      if saved {
        dismiss()
      } else {
        saveError = mcp.consumeErrorMessage() ?? "Could not save MCP server."
      }
    }
  }
}

struct MacChatToolsView: View {
  @Bindable var mcp: MacMCPModel
  let conversationID: ConversationID?
  let projectID: ProjectID?
  let draftConfiguration: Binding<MCPChatToolConfiguration?>?
  let presets: [ProjectToolPreset]
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
    presets: [ProjectToolPreset],
    isGenerating: Bool = false,
    modelSupportsTools: Bool = true,
    manageServers: (() -> Void)? = nil
  ) {
    self.mcp = mcp
    self.conversationID = conversationID
    self.projectID = projectID
    self.draftConfiguration = draftConfiguration
    self.presets = presets
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
    let activeConfig = normalizedToolConfiguration(currentConfiguration)
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

        if !presets.isEmpty {
          Menu {
            ForEach(presets) { preset in
              let isApplied = normalizedToolConfiguration(preset.configuration) == activeConfig
              Button {
                applyPreset(preset)
              } label: {
                if isApplied {
                  Label(preset.name, systemImage: "checkmark")
                } else {
                  Text(preset.name)
                }
              }
            }
          } label: {
            MacMenuButtonLabel(title: "Apply Preset")
          }
          .menuStyle(.borderlessButton)
          .menuIndicator(.hidden)
          .fixedSize()
          .disabled(isMutationDisabled)
        }

        if hasChatOverride, project != nil {
          Button("Reset to Project Defaults") {
            resetToProjectDefaults()
          }
          .buttonStyle(MacActionButtonStyle(.secondary))
          .disabled(isMutationDisabled)
        }

        if let manageServers, !mcp.servers.isEmpty {
          Button("Manage Servers…", systemImage: "shippingbox") {
            dismiss()
            manageServers()
          }
          .buttonStyle(MacActionButtonStyle(.secondary))
        }

        Button("Done") { dismiss() }
          .buttonStyle(MacActionButtonStyle(.primary))
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
    .frame(width: 720, height: 650)
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
    .sheet(isPresented: $showingAddServer) {
      MacMCPServerConnectionEditorView(mcp: mcp, server: nil)
    }
  }

  private func applyPreset(_ preset: ProjectToolPreset) {
    if let conversationID {
      Task {
        _ = await mcp.applyChatConfiguration(
          preset.configuration,
          conversationID: conversationID
        )
      }
    } else {
      let result = mcp.validatedDraftPresetConfiguration(
        preset.configuration,
        projectID: projectID
      )
      if result.succeeded {
        draftConfiguration?.wrappedValue = result.configuration
      }
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
  let configuration: MCPChatToolConfiguration
  var isDisabled: Bool = false
  let onConfigurationChange: (MCPChatToolConfiguration) -> Void
  @State private var showingAddServer = false

  var body: some View {
    MacMCPServerConfigurationList(
      mcp: mcp,
      configuration: configuration,
      context: .project,
      isReadOnly: isDisabled,
      addServer: {
        guard MacProAccess.requireMCPServerCapacity(currentCount: mcp.servers.count) else { return }
        showingAddServer = true
      },
      setServerEnabled: { serverID, enabled in
        if enabled, mcp.isServerRestricted(serverID) {
          if MacProAccess.isCheckingEntitlement {
            mcp.errorMessage = MacProAccess.restoredResourceBlockedMessage("MCP server")
          }
          MacProAccess.requestUpgrade(.mcpServers)
          return
        }
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
        if policy != .disabled, mcp.isServerRestricted(serverID) {
          if MacProAccess.isCheckingEntitlement {
            mcp.errorMessage = MacProAccess.restoredResourceBlockedMessage("MCP server")
          }
          MacProAccess.requestUpgrade(.mcpServers)
          return
        }
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
  var isReadOnly: Bool = false
  var addServer: (() -> Void)? = nil
  var manageServers: (() -> Void)? = nil
  let setServerEnabled: (MCPServerID, Bool) -> Void
  let setPolicy: (String, ChatToolPermissionPolicy) -> Void
  var setAllPolicies: ((MCPServerID, ChatToolPermissionPolicy) -> Void)? = nil

  private var isMutationDisabled: Bool {
    isGenerating || isReadOnly || (mcp.isBusy && isChatContext)
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
            .buttonStyle(MacActionButtonStyle(.primary))
            .disabled(mcp.isBusy || isReadOnly)
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVStack(spacing: 10) {
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
          .padding(14)
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

  @State private var isHovered = false

  var body: some View {
    let enabled = configuration.isServerEnabled(server.id)
    let isRestricted = mcp.isServerRestricted(server.id)
    let missingCredential = server.authentication.kind != .none && !mcp.hasCredential(server.id)
    let isRefreshing = mcp.refreshingServerIDs.contains(server.id)
    let tools = mcp.tools(for: server.id)
    let activeCount = tools.filter { configuration.policy(for: $0.exposedName) != .disabled }.count
    let snapshot = mcp.snapshot(for: server.id)
    let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

    VStack(alignment: .leading, spacing: 0) {
      DisclosureGroup {
        VStack(alignment: .leading, spacing: 8) {
          if isRestricted {
            Label(
              "This restored MCP server requires BYOK Pro to use.",
              systemImage: "crown.fill"
            )
            .font(.caption)
            .foregroundStyle(.orange)
          } else if !server.isEnabled {
            HStack {
              Label(
                "Enable this server globally in MCP Servers before using its tools here.",
                systemImage: "pause.circle"
              )
              .font(.caption)
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
              Spacer()
              if let manageServers {
                Button("Open MCP Servers", action: manageServers)
                  .buttonStyle(MacActionButtonStyle(.secondary, size: .small))
              }
            }
          } else if missingCredential {
            HStack {
              Label(
                "Missing credential. Add it in MCP Servers before enabling.",
                systemImage: "exclamationmark.triangle.fill"
              )
              .font(.caption)
              .foregroundStyle(.orange)
              Spacer()
              if let manageServers {
                Button("Open MCP Servers", action: manageServers)
                  .buttonStyle(MacActionButtonStyle(.secondary, size: .small))
              }
            }
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
              .buttonStyle(MacActionButtonStyle(.secondary, size: .small))
              .disabled(mcp.isBusy || isReadOnly)
            }
          } else {
            if tools.count > 1, let setAllPolicies {
              HStack {
                Text("\(activeCount) of \(tools.count) tools active")
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
                  MacMenuButtonLabel(title: "Set All…", size: .small)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(isMutationDisabled)
              }
              .padding(.bottom, 2)
              Divider()
            }

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
              isRestricted
                ? Color.orange
                : (!server.isEnabled
                  ? MacDesignTokens.Colors.textMuted.opacity(0.5)
                  : (missingCredential ? Color.orange : MacDesignTokens.Colors.accent))
            )
            .frame(width: 8, height: 8)
          VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
              Text(server.name)
                .font(.system(size: 13.5, weight: .medium))
              if isRestricted {
                Label("Pro", systemImage: "crown.fill")
                  .font(.caption2.weight(.semibold))
                  .foregroundStyle(.orange)
                  .padding(.horizontal, 6)
                  .padding(.vertical, 1.5)
                  .background(Color.orange.opacity(0.14), in: Capsule())
              }
            }
            if isRestricted {
              Text("Requires BYOK Pro")
                .font(.caption)
                .foregroundStyle(.orange)
            } else if !server.isEnabled {
              Text("Globally disabled")
                .font(.caption)
                .foregroundStyle(MacDesignTokens.Colors.textMuted)
            } else if missingCredential {
              Text("Missing credential. Add it in MCP Servers before enabling.")
                .font(.caption)
                .foregroundStyle(.orange)
            } else if enabled && !tools.isEmpty {
              Text("\(activeCount) of \(tools.count) \(tools.count == 1 ? "tool" : "tools") active")
                .font(.caption)
                .foregroundStyle(MacDesignTokens.Colors.textMuted)
            } else {
              Text("\(tools.count) \(tools.count == 1 ? "tool" : "tools") discovered")
                .font(.caption)
                .foregroundStyle(MacDesignTokens.Colors.textMuted)
            }
          }
          Spacer()
          if server.isEnabled && !missingCredential && !isRestricted {
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
                  .font(.system(size: 12, weight: .semibold))
              }
              .buttonStyle(MacIconButtonStyle())
              .disabled(mcp.isBusy || isReadOnly)
              .help("Refresh tools for \(server.name)")
              .accessibilityLabel("Refresh tools for \(server.name)")
            }
          }
          Toggle(
            context.enableTitle,
            isOn: Binding(
              get: { configuration.isServerEnabled(server.id) },
              set: { setServerEnabled($0) }
            )
          )
          .toggleStyle(.switch)
          .controlSize(.small)
          .disabled(
            ((!server.isEnabled || missingCredential || isRestricted) && !enabled)
              || mcp.isBusy
              || isGenerating
              || isReadOnly
          )
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
    .background(MacDesignTokens.Colors.surface, in: shape)
    .overlay {
      shape.stroke(
        isHovered
          ? MacDesignTokens.Colors.accent.opacity(0.3)
          : MacDesignTokens.Colors.separator.opacity(0.75),
        lineWidth: 0.75
      )
    }
    .onHover { isHovered = $0 }
    .animation(.easeOut(duration: MacDesignTokens.Control.interactionDuration), value: isHovered)
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

  private var needsScrolling: Bool {
    text.count > 450 || text.components(separatedBy: .newlines).count > 10
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
        MacDesignTokens.Colors.canvas.opacity(0.75),
        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
          .stroke(MacDesignTokens.Colors.separator.opacity(0.65), lineWidth: 0.5)
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
          .foregroundStyle(copied ? MacDesignTokens.Colors.accent : MacDesignTokens.Colors.textMuted)
          .frame(width: 22, height: 22)
          .background(MacDesignTokens.Colors.surface.opacity(0.9), in: RoundedRectangle(cornerRadius: 5))
      }
      .buttonStyle(.plain)
      .padding(5)
      .help(copied ? "Copied" : "Copy")
      .accessibilityLabel(copied ? "Copied" : "Copy")
    }
  }

  private var codeText: some View {
    Text(text)
      .font(.system(size: 11, design: .monospaced))
      .textSelection(.enabled)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(8)
      .padding(.trailing, 28)
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
