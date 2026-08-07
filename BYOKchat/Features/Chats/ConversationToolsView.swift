import BYOKchatProviderCore
import SwiftUI

struct ConversationToolsView: View {
  let conversationID: ConversationID
  @Bindable var mcp: MCPManagementModel

  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        Section {
          Label(
            "Only tools enabled here are sent to the model for this chat. New tools default to Ask.",
            systemImage: "hand.raised"
          )
          .font(.footnote)
          .foregroundStyle(.secondary)
        }

        if mcp.servers.isEmpty {
          Section {
            ContentUnavailableView(
              "No MCP Servers",
              systemImage: "server.rack",
              description: Text("Add a remote MCP server in Settings first.")
            )
          }
        } else {
          ForEach(mcp.servers) { server in
            serverSection(server)
          }
        }
      }
      .navigationTitle("Tools")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
  }

  @ViewBuilder
  private func serverSection(_ server: MCPRemoteServer) -> some View {
    let enabledForChat = mcp.isServerEnabled(server.id, for: conversationID)
    let bindings = mcp.tools(for: server.id)

    Section {
      Toggle(
        isOn: Binding(
          get: { mcp.isServerEnabled(server.id, for: conversationID) },
          set: { value in
            Task { @MainActor in
              await mcp.setChatServerEnabled(
                value,
                serverID: server.id,
                conversationID: conversationID
              )
            }
          }
        )
      ) {
        VStack(alignment: .leading, spacing: 3) {
          Text("Enable for This Chat")
          if !server.isEnabled {
            Text("This server is disabled globally in Settings.")
              .font(.caption)
              .foregroundStyle(.orange)
          }
        }
      }
      .disabled(!server.isEnabled || mcp.isBusy)

      if server.isEnabled && enabledForChat {
        if bindings.isEmpty {
          VStack(alignment: .leading, spacing: 8) {
            Text("No tools are currently cached for this server.")
              .font(.footnote)
              .foregroundStyle(.secondary)
            Button("Refresh Tools", systemImage: "arrow.clockwise") {
              Task { @MainActor in await mcp.refresh(server.id) }
            }
          }
        } else {
          ForEach(bindings) { binding in
            toolRow(binding)
          }
        }
      }
    } header: {
      HStack {
        Text(server.name)
        Spacer()
        if let snapshot = mcp.snapshot(for: server.id) {
          Text("\(snapshot.tools.count) tools")
        }
      }
    } footer: {
      if let snapshot = mcp.snapshot(for: server.id) {
        Text("MCP \(snapshot.protocolVersion)")
      }
    }
  }

  private func toolRow(_ binding: MCPToolBinding) -> some View {
    let tool = binding.remoteTool
    return VStack(alignment: .leading, spacing: 7) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        VStack(alignment: .leading, spacing: 3) {
          Text(tool.title ?? tool.remoteName)
            .font(.body.weight(.medium))
          Text(tool.description)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(3)
        }

        Spacer(minLength: 8)

        Picker(
          "Permission",
          selection: Binding(
            get: { mcp.toolPolicy(binding.exposedName, for: conversationID) },
            set: { policy in
              Task { @MainActor in
                await mcp.setChatToolPolicy(
                  policy,
                  exposedToolName: binding.exposedName,
                  conversationID: conversationID
                )
              }
            }
          )
        ) {
          ForEach(ChatToolPermissionPolicy.allCases, id: \.self) { policy in
            Text(policy.displayName).tag(policy)
          }
        }
        .labelsHidden()
        .pickerStyle(.menu)
      }

      HStack(spacing: 8) {
        if annotationBool("readOnlyHint", tool: tool) == true {
          Label("Read-only", systemImage: "eye")
        }
        if annotationBool("destructiveHint", tool: tool) == true {
          Label("Destructive", systemImage: "exclamationmark.triangle")
            .foregroundStyle(.orange)
        }
      }
      .font(.caption2)
      .foregroundStyle(.tertiary)
    }
    .padding(.vertical, 3)
  }

  private func annotationBool(_ key: String, tool: MCPRemoteTool) -> Bool? {
    guard case .object(let annotations)? = tool.annotations,
      case .bool(let value)? = annotations[key]
    else { return nil }
    return value
  }
}
