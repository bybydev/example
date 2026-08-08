import AppFoundation
import BYOKchatProviderCore
import Foundation
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ChatView: View {
  let conversationID: ConversationID
  let initialScrollMessageID: ChatMessageID?
  let openSidebar: () -> Void
  let startNewChat: () -> Void

  @Bindable var chats: ChatManagementModel
  @Bindable var providers: ProviderManagementModel
  @Bindable var projects: ProjectManagementModel
  @Bindable var mcp: MCPManagementModel

  @Environment(\.appFoundationTheme) private var theme
  @Environment(\.dismiss) var dismiss
  @State var draft = ""
  @State var restoredDraft = false
  @State var showTargetSettings = false
  @State var showToolSettings = false
  @State var showUsage = false
  @State var renameText = ""
  @State var showRename = false
  @State var editTarget: ChatMessage?
  @State var editText = ""
  @State var showRegenerateConfirmation = false
  @State var isNearBottom = true
  @State var followsLatest = true
  @State var isUserDraggingTimeline = false
  @State var showJumpToLatest = false
  @State var hasCompletedInitialScroll = false
  @State var chatScrollPosition = ScrollPosition(idType: String.self)
  @State var markdownDocument: MarkdownExportDocument?
  @State var showMarkdownExporter = false
  @State var pendingAttachments: [ChatAttachment] = []
  @State var showPhotoPicker = false
  @State var photoPickerItems: [PhotosPickerItem] = []
  @State var showFileImporter = false

  init(
    conversationID: ConversationID,
    initialScrollMessageID: ChatMessageID? = nil,
    chats: ChatManagementModel,
    providers: ProviderManagementModel,
    projects: ProjectManagementModel,
    mcp: MCPManagementModel,
    openSidebar: @escaping () -> Void = {},
    startNewChat: @escaping () -> Void = {}
  ) {
    self.conversationID = conversationID
    self.initialScrollMessageID = initialScrollMessageID
    self.chats = chats
    self.providers = providers
    self.projects = projects
    self.mcp = mcp
    self.openSidebar = openSidebar
    self.startNewChat = startNewChat
  }

  var conversation: ChatConversation? {
    chats.conversation(conversationID)
  }

  var project: ChatProject? {
    projects.project(for: conversationID)
  }

  var latestAssistantID: ChatMessageID? {
    conversation?.messages.last(where: { $0.role == .assistant })?.id
  }

  var markdownFilename: String {
    let title = conversation?.title ?? "BYOKchat-conversation"
    let safe = title.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" }
    return String(safe).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
  }

  var body: some View {
    Group {
      if let conversation {
        chatContent(conversation)
      } else {
        ContentUnavailableView("Conversation Missing", systemImage: "exclamationmark.bubble")
      }
    }
    .background(theme.backgroundColor)
    .toolbar(.hidden, for: .navigationBar)
    .safeAreaInset(edge: .top, spacing: 0) {
      ChatTopBar(openSidebar: openSidebar, newChat: startNewChat) {
        if let project, !project.projectPromptPresets.isEmpty {
          Menu("Prompts", systemImage: "text.bubble") {
            ForEach(project.projectPromptPresets) { preset in
              Button(preset.name) { applyPromptPreset(preset) }
            }
          }
        }
        Button("Chat Settings", systemImage: "slider.horizontal.3") {
          showTargetSettings = true
        }
        Button("Tools", systemImage: "wrench.and.screwdriver") {
          showToolSettings = true
        }
        Button("Usage", systemImage: "chart.bar.xaxis") {
          showUsage = true
        }
        Button("Rename", systemImage: "pencil") {
          renameText = conversation?.title ?? ""
          showRename = true
        }
        Button("Export Markdown", systemImage: "square.and.arrow.up") {
          prepareMarkdownExport()
        }
        Divider()
        Button("Delete", systemImage: "trash", role: .destructive) {
          Task { @MainActor in
            await chats.deleteConversation(conversationID)
            await projects.reloadFromStorage()
            await mcp.reloadFromStorage()
            startNewChat()
            dismiss()
          }
        }
      }
    }
    .sheet(isPresented: $showTargetSettings) {
      if let conversation {
        ConversationTargetView(
          conversation: conversation,
          chats: chats,
          providers: providers
        )
      }
    }
    .sheet(isPresented: $showToolSettings) {
      ConversationToolsView(
        conversationID: conversationID,
        projects: projects,
        mcp: mcp
      )
    }
    .sheet(isPresented: $showUsage) {
      UsageDashboardView(
        conversations: chats.conversations,
        currentConversationID: conversationID
      )
    }
    .sheet(item: $editTarget) { message in
      MessageEditorSheet(
        original: message.content,
        text: $editText,
        save: {
          followsLatest = true
          showJumpToLatest = false
          chats.editAndResend(
            conversationID: conversationID,
            messageID: message.id,
            text: editText
          )
          editTarget = nil
        },
        cancel: { editTarget = nil }
      )
    }
    .alert("Rename Chat", isPresented: $showRename) {
      TextField("Title", text: $renameText)
      Button("Cancel", role: .cancel) {}
      Button("Save") {
        Task { @MainActor in
          await chats.renameConversation(conversationID, title: renameText)
        }
      }
    }
    .alert("Regenerate response?", isPresented: $showRegenerateConfirmation) {
      Button("Cancel", role: .cancel) {}
      Button("Regenerate Anyway", role: .destructive) {
        followsLatest = true
        showJumpToLatest = false
        chats.regenerate(
          conversationID: conversationID,
          confirmingUncertainCompletion: true
        )
      }
    } message: {
      Text(
        "The previous request may have completed at the provider. Regenerating could create another billable request."
      )
    }
    .photosPicker(
      isPresented: $showPhotoPicker,
      selection: $photoPickerItems,
      maxSelectionCount: 8,
      matching: .images
    )
    .onChange(of: photoPickerItems) { _, items in
      importPhotos(items)
    }
    .fileImporter(
      isPresented: $showFileImporter,
      allowedContentTypes: [.item],
      allowsMultipleSelection: true
    ) { result in
      importFiles(result)
    }
    .fileExporter(
      isPresented: $showMarkdownExporter,
      document: markdownDocument,
      contentType: .byokMarkdown,
      defaultFilename: markdownFilename
    ) { result in
      if case .failure(let error) = result {
        chats.errorMessage = error.localizedDescription
      }
    }
    .task(id: conversationID) {
      pendingAttachments = []
      photoPickerItems = []
      guard !restoredDraft else { return }
      draft = chats.draft(for: conversationID)
      restoredDraft = true
    }
    .onChange(of: draft) { _, value in
      guard restoredDraft else { return }
      chats.saveDraft(value, conversationID: conversationID)
    }
  }

  private func applyPromptPreset(_ preset: ProjectPromptPreset) {
    let value = preset.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return }
    if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      draft = value
    } else {
      draft += "\n\n" + value
    }
  }

  private func prepareMarkdownExport() {
    guard let conversation else { return }
    let accountLabel = providers.accounts.first { $0.id == conversation.accountID }?.label
    markdownDocument = MarkdownExportDocument(
      data: Data(
        ConversationMarkdownFormatter.render(
          conversation,
          accountLabel: accountLabel
        ).utf8
      )
    )
    showMarkdownExporter = true
  }

  private func importPhotos(_ items: [PhotosPickerItem]) {
    guard !items.isEmpty else { return }
    Task { @MainActor in
      var imported: [ChatAttachment] = []
      for item in items {
        do {
          guard let data = try await item.loadTransferable(type: Data.self) else { continue }
          let attachment = try normalizedImageAttachment(
            data: data,
            suggestedName: "image-\(pendingAttachments.count + imported.count + 1)"
          )
          imported.append(attachment)
        } catch {
          chats.errorMessage = error.localizedDescription
        }
      }
      appendAttachments(imported)
      photoPickerItems = []
    }
  }

  private func importFiles(_ result: Result<[URL], Error>) {
    switch result {
    case .failure(let error):
      chats.errorMessage = error.localizedDescription
    case .success(let urls):
      do {
        let attachments = try urls.map(loadFileAttachment)
        appendAttachments(attachments)
      } catch {
        chats.errorMessage = error.localizedDescription
      }
    }
  }

  private func loadFileAttachment(_ url: URL) throws -> ChatAttachment {
    let access = url.startAccessingSecurityScopedResource()
    defer {
      if access { url.stopAccessingSecurityScopedResource() }
    }

    let values = try url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey])
    if let fileSize = values.fileSize, fileSize > 20 * 1_024 * 1_024 {
      throw ProviderError.invalidRequest("\(url.lastPathComponent) is larger than 20 MB.")
    }
    let data = try Data(contentsOf: url, options: [.mappedIfSafe])
    let type = values.contentType ?? UTType(filenameExtension: url.pathExtension) ?? .data

    if type.conforms(to: .image) {
      return try normalizedImageAttachment(data: data, suggestedName: url.deletingPathExtension().lastPathComponent)
    }

    return ChatAttachment(
      kind: .file,
      filename: url.lastPathComponent,
      mimeType: type.preferredMIMEType ?? "application/octet-stream",
      data: data
    )
  }

  private func normalizedImageAttachment(data: Data, suggestedName: String) throws -> ChatAttachment {
    guard let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.9) else {
      throw ProviderError.invalidRequest("The selected image could not be read.")
    }
    return ChatAttachment(
      kind: .image,
      filename: suggestedName + ".jpg",
      mimeType: "image/jpeg",
      data: jpeg
    )
  }

  private func appendAttachments(_ additions: [ChatAttachment]) {
    guard !additions.isEmpty else { return }
    let combined = pendingAttachments + additions
    guard combined.count <= 8 else {
      chats.errorMessage = "A message can include at most 8 attachments."
      return
    }
    guard combined.allSatisfy({ $0.byteCount <= 20 * 1_024 * 1_024 }) else {
      chats.errorMessage = "Each attachment must be no larger than 20 MB."
      return
    }
    guard combined.reduce(0, { $0 + $1.byteCount }) <= 40 * 1_024 * 1_024 else {
      chats.errorMessage = "Attachments in one message cannot exceed 40 MB total."
      return
    }
    pendingAttachments = combined
  }

  func removePendingAttachment(_ id: String) {
    pendingAttachments.removeAll { $0.id == id }
  }
}

private struct ConversationToolsView: View {
  let conversationID: ConversationID
  @Bindable var projects: ProjectManagementModel
  @Bindable var mcp: MCPManagementModel

  @Environment(\.dismiss) private var dismiss

  private var project: ChatProject? {
    projects.project(for: conversationID)
  }

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

          if mcp.inheritsProjectTools(conversationID), let project {
            Label("Inheriting defaults from \(project.name)", systemImage: "arrow.triangle.branch")
              .font(.footnote)
              .foregroundStyle(.secondary)
          } else if mcp.hasChatOverride(conversationID), project != nil {
            Button("Reset to Project Defaults", systemImage: "arrow.uturn.backward") {
              Task { @MainActor in
                await mcp.removeChatConfiguration(conversationID)
              }
            }
          }
        }

        if let project, !project.projectToolPresets.isEmpty {
          Section("Project Tool Presets") {
            ForEach(project.projectToolPresets) { preset in
              Button {
                Task { @MainActor in
                  await mcp.applyChatConfiguration(
                    preset.configuration,
                    conversationID: conversationID
                  )
                }
              } label: {
                Label(preset.name, systemImage: "wrench.adjustable")
              }
            }
          }
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
