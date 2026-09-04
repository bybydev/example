import BYOKchatProviderCore
import SwiftUI

struct MacShellView: View {
  let model: MacAppModel

  @Environment(MacUtilitySheetCoordinator.self) private var utilitySheets
  @State private var columnVisibility: NavigationSplitViewVisibility = .all
  @State private var selectedConversationID: ConversationID?
  @State private var searchText = ""
  @State private var composerFocusRequestID = 0
  @State private var showingTargetPicker = false
  @State private var showingChatTools = false
  @State private var renameTarget: ChatConversation?
  @State private var deleteTarget: ChatConversation?
  @State private var pendingAttachmentsByKey: [String: [ChatAttachment]] = [:]

  private static let newChatAttachmentKey = "__new_chat__"

  var body: some View {
    Group {
      if let providers = model.providers, let chats = model.chats, let mcp = model.mcp {
        shell(providers: providers, chats: chats, mcp: mcp)
      } else {
        ContentUnavailableView(
          "Chat Runtime Unavailable",
          systemImage: "exclamationmark.triangle",
          description: Text("Restart BYOKchat to reload the shared runtime.")
        )
      }
    }
  }

  private func shell(
    providers: MacProviderModel,
    chats: MacChatSessionModel,
    mcp: MacMCPModel
  ) -> some View {
    NavigationSplitView(columnVisibility: $columnVisibility) {
      MacSidebarView(
        chats: chats,
        selection: $selectedConversationID,
        searchText: $searchText,
        searchFocusRequestID: model.conversationSearchRequestID,
        newChat: { startNewChat(chats: chats) },
        rename: { renameTarget = $0 },
        delete: { deleteTarget = $0 }
      )
      .navigationSplitViewColumnWidth(
        min: MacDesignTokens.Layout.sidebarMinimum,
        ideal: MacDesignTokens.Layout.sidebarIdeal,
        max: MacDesignTokens.Layout.sidebarMaximum
      )
    } detail: {
      MacChatPane(
        providers: providers,
        chats: chats,
        mcp: mcp,
        conversationID: selectedConversationID,
        summary: chats.summary(selectedConversationID),
        columnVisibility: $columnVisibility,
        composerFocusRequestID: composerFocusRequestID,
        attachments: pendingAttachments(for: selectedConversationID),
        chooseTarget: { showingTargetPicker = true },
        manageProviders: { utilitySheets.present(.providers) },
        configureTools: {
          if selectedConversationID != nil { showingChatTools = true }
        },
        renameConversation: {
          if let conversation = chats.conversation(selectedConversationID) ?? chats.summary(selectedConversationID) {
            renameTarget = conversation
          }
        },
        deleteConversation: {
          if let conversation = chats.conversation(selectedConversationID) ?? chats.summary(selectedConversationID) {
            deleteTarget = conversation
          }
        },
        appendAttachments: { additions in
          appendAttachments(additions, conversationID: selectedConversationID, chats: chats)
        },
        removeAttachment: { id in
          removePendingAttachment(id, conversationID: selectedConversationID)
        },
        send: { text, attachments in
          let sourceConversationID = selectedConversationID
          Task { @MainActor in
            if let id = await chats.send(
              conversationID: sourceConversationID,
              text: text,
              attachments: attachments
            ) {
              if sourceConversationID == nil {
                transferFreshAttachments(to: id)
              }
              selectedConversationID = id
              await chats.loadConversation(id)
              await mcp.reloadFromStorage()
              clearPersistedPendingAttachments(
                persistedAttachmentIDs(for: id, chats: chats),
                conversationID: id
              )
            }
          }
        }
      )
    }
    .background(MacDesignTokens.Colors.canvas)
    .onAppear {
      if selectedConversationID == nil, let first = chats.conversationSummaries.first?.id {
        selectedConversationID = first
        Task { await chats.loadConversation(first) }
      }
      chats.updateSearch(searchText)
    }
    .onChange(of: selectedConversationID) { _, newValue in
      Task { await chats.loadConversation(newValue) }
    }
    .onChange(of: chats.streamRevisions) { _, _ in
      guard let selectedConversationID else { return }
      clearPersistedPendingAttachments(
        persistedAttachmentIDs(for: selectedConversationID, chats: chats),
        conversationID: selectedConversationID
      )
    }
    .onChange(of: chats.conversationSummaries.map(\.id)) { _, ids in
      guard let selectedConversationID, !ids.contains(selectedConversationID) else { return }
      self.selectedConversationID = ids.first
    }
    .onChange(of: model.newChatRequestID) { _, _ in
      startNewChat(chats: chats)
    }
    .sheet(isPresented: $showingTargetPicker) {
      MacTargetPickerView(
        providers: providers,
        initialTarget: chats.target(for: selectedConversationID)
      ) { target in
        await chats.applyTarget(target, conversationID: selectedConversationID)
      }
    }
    .sheet(isPresented: $showingChatTools) {
      if let selectedConversationID {
        MacChatToolsView(
          mcp: mcp,
          conversationID: selectedConversationID,
          presets: model.workspace?.project(for: selectedConversationID)?.projectToolPresets ?? []
        )
      }
    }
    .sheet(item: $renameTarget) { conversation in
      MacRenameConversationSheet(conversation: conversation) { title in
        await chats.renameConversation(conversation.id, title: title)
      }
    }
    .confirmationDialog(
      deleteTarget.map { "Delete \"\($0.title.isEmpty ? "New Chat" : $0.title)\"?" } ?? "Delete conversation?",
      isPresented: Binding(
        get: { deleteTarget != nil },
        set: { if !$0 { deleteTarget = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("Delete Conversation", role: .destructive) {
        guard let target = deleteTarget else { return }
        deleteTarget = nil
        Task { @MainActor in
          let wasSelected = selectedConversationID == target.id
          if await chats.deleteConversation(target.id) {
            await mcp.reloadFromStorage()
            pendingAttachmentsByKey.removeValue(forKey: attachmentKey(target.id))
            if wasSelected {
              selectedConversationID = chats.conversationSummaries.first?.id
            }
          }
        }
      }
      Button("Cancel", role: .cancel) {
        deleteTarget = nil
      }
    } message: {
      Text("This removes the conversation and its chat-specific project/tool references. This cannot be undone.")
    }
    .alert(
      "Chat Error",
      isPresented: Binding(
        get: { chats.errorMessage != nil || mcp.errorMessage != nil },
        set: {
          if !$0 {
            chats.errorMessage = nil
            mcp.errorMessage = nil
          }
        }
      )
    ) {
      Button("OK") {
        chats.errorMessage = nil
        mcp.errorMessage = nil
      }
    } message: {
      Text(chats.errorMessage ?? mcp.errorMessage ?? "Unknown error")
    }
  }

  private func startNewChat(chats: MacChatSessionModel) {
    selectedConversationID = nil
    searchText = ""
    pendingAttachmentsByKey.removeValue(forKey: Self.newChatAttachmentKey)
    chats.updateSearch("")
    chats.resetNewChat()
    composerFocusRequestID &+= 1
  }

  private func attachmentKey(_ conversationID: ConversationID?) -> String {
    guard let conversationID else { return Self.newChatAttachmentKey }
    return "conversation::\(conversationID.rawValue)"
  }

  private func pendingAttachments(for conversationID: ConversationID?) -> [ChatAttachment] {
    pendingAttachmentsByKey[attachmentKey(conversationID)] ?? []
  }

  private func appendAttachments(
    _ additions: [ChatAttachment],
    conversationID: ConversationID?,
    chats: MacChatSessionModel
  ) {
    guard !additions.isEmpty else { return }
    let key = attachmentKey(conversationID)
    do {
      pendingAttachmentsByKey[key] = try MacAttachmentImporter.validateCombined(
        existing: pendingAttachmentsByKey[key] ?? [],
        additions: additions
      )
    } catch {
      chats.errorMessage = error.localizedDescription
    }
  }

  private func removePendingAttachment(_ id: String, conversationID: ConversationID?) {
    let key = attachmentKey(conversationID)
    guard var values = pendingAttachmentsByKey[key] else { return }
    values.removeAll { $0.id == id }
    if values.isEmpty {
      pendingAttachmentsByKey.removeValue(forKey: key)
    } else {
      pendingAttachmentsByKey[key] = values
    }
  }

  private func transferFreshAttachments(to conversationID: ConversationID) {
    guard let values = pendingAttachmentsByKey.removeValue(forKey: Self.newChatAttachmentKey),
      !values.isEmpty
    else { return }
    pendingAttachmentsByKey[attachmentKey(conversationID)] = values
  }

  private func persistedAttachmentIDs(
    for conversationID: ConversationID,
    chats: MacChatSessionModel
  ) -> Set<String> {
    Set(
      chats.messages(for: conversationID)
        .flatMap { $0.attachments ?? [] }
        .map(\.id)
    )
  }

  private func clearPersistedPendingAttachments(
    _ persistedIDs: Set<String>,
    conversationID: ConversationID
  ) {
    let key = attachmentKey(conversationID)
    guard let pending = pendingAttachmentsByKey[key], !pending.isEmpty else { return }
    let pendingIDs = Set(pending.map(\.id))
    guard pendingIDs.isSubset(of: persistedIDs) else { return }
    pendingAttachmentsByKey.removeValue(forKey: key)
  }
}

private struct MacSidebarView: View {
  @Bindable var chats: MacChatSessionModel
  @Binding var selection: ConversationID?
  @Binding var searchText: String
  let searchFocusRequestID: Int
  let newChat: () -> Void
  let rename: (ChatConversation) -> Void
  let delete: (ChatConversation) -> Void

  @AppStorage("byokchat.sidebar.pinnedConversationIDs") private var pinnedConversationIDs = ""
  @FocusState private var searchFocused: Bool

  private var isSearching: Bool {
    !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private var pinnedIDSet: Set<String> {
    Set(
      pinnedConversationIDs
        .split(separator: "\n")
        .map(String.init)
    )
  }

  private var pinnedConversations: [ChatConversation] {
    chats.conversationSummaries
      .filter { pinnedIDSet.contains($0.id.rawValue) }
      .sorted { $0.updatedAt > $1.updatedAt }
  }

  private var recentConversations: [ChatConversation] {
    chats.conversationSummaries
      .filter { !pinnedIDSet.contains($0.id.rawValue) }
      .sorted { $0.updatedAt > $1.updatedAt }
  }

  var body: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: MacDesignTokens.Spacing.compact) {
        HStack(spacing: MacDesignTokens.Spacing.small) {
          Image(systemName: "bubble.left.and.bubble.right.fill")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(MacDesignTokens.Colors.accent)
          Text("BYOKchat")
            .font(.headline)
        }

        Button(action: newChat) {
          Label("New Chat", systemImage: "square.and.pencil")
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, MacDesignTokens.Spacing.compact)
            .frame(height: 34)
            .background(
              MacDesignTokens.Colors.accentSoft,
              in: RoundedRectangle(cornerRadius: MacDesignTokens.Radius.small)
            )
        }
        .buttonStyle(.plain)

        searchField
      }
      .padding(.horizontal, MacDesignTokens.Spacing.compact)
      .padding(.top, MacDesignTokens.Spacing.standard)
      .padding(.bottom, MacDesignTokens.Spacing.compact)

      Divider()

      Group {
        if isSearching {
          searchResults
        } else {
          conversationList
        }
      }
      .frame(maxHeight: .infinity)

      Divider()
      MacSidebarUtilityGrid()
    }
    .background(MacDesignTokens.Colors.surface.opacity(0.52))
    .onAppear {
      prunePinnedConversations()
    }
    .onChange(of: searchFocusRequestID) { _, _ in
      searchFocused = true
    }
    .onChange(of: searchText) { _, value in
      chats.updateSearch(value)
    }
    .onChange(of: chats.conversationSummaries.map(\.id)) { _, _ in
      prunePinnedConversations()
    }
  }

  private var conversationList: some View {
    Group {
      if chats.conversationSummaries.isEmpty {
        sidebarEmptyState(icon: "bubble.left", text: "No conversations yet")
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 2) {
            if !pinnedConversations.isEmpty {
              sidebarSectionTitle("Pinned", topPadding: 2)
              ForEach(pinnedConversations) { conversation in
                conversationRow(conversation)
              }
            }

            if !recentConversations.isEmpty {
              sidebarSectionTitle(
                "Recent",
                topPadding: pinnedConversations.isEmpty ? 2 : 12
              )
              ForEach(recentConversations) { conversation in
                conversationRow(conversation)
              }
            }
          }
          .padding(.horizontal, MacDesignTokens.Spacing.small)
          .padding(.vertical, MacDesignTokens.Spacing.small)
        }
      }
    }
  }

  private func sidebarSectionTitle(_ title: String, topPadding: CGFloat) -> some View {
    Text(title)
      .font(.caption.weight(.semibold))
      .foregroundStyle(.secondary)
      .padding(.horizontal, MacDesignTokens.Spacing.small)
      .padding(.top, topPadding)
      .padding(.bottom, 3)
  }

  private func conversationRow(_ conversation: ChatConversation) -> some View {
    let pinned = pinnedIDSet.contains(conversation.id.rawValue)
    return MacConversationRow(
      conversation: conversation,
      selected: selection == conversation.id,
      pinned: pinned,
      action: { selection = conversation.id },
      togglePinned: { togglePinned(conversation.id) },
      rename: { rename(conversation) },
      delete: {
        removePinned(conversation.id)
        delete(conversation)
      }
    )
  }

  private var searchResults: some View {
    Group {
      if chats.isSearching && chats.searchItems.isEmpty {
        VStack {
          Spacer()
          ProgressView()
            .controlSize(.mini)
          Spacer()
        }
        .frame(maxWidth: .infinity)
      } else if chats.searchItems.isEmpty {
        sidebarEmptyState(icon: "magnifyingglass", text: "No matching conversations")
      } else {
        ScrollView {
          LazyVStack(spacing: 2) {
            ForEach(chats.searchItems) { item in
              MacSearchResultRow(
                item: item,
                selected: selection == item.conversationID
              ) {
                selection = item.conversationID
              }
            }
          }
          .padding(.horizontal, MacDesignTokens.Spacing.small)
          .padding(.vertical, MacDesignTokens.Spacing.small)
        }
      }
    }
  }

  private func sidebarEmptyState(icon: String, text: String) -> some View {
    VStack(spacing: MacDesignTokens.Spacing.small) {
      Spacer()
      Image(systemName: icon)
        .font(.title2)
        .foregroundStyle(.tertiary)
      Text(text)
        .font(.callout)
        .foregroundStyle(.secondary)
      Spacer()
    }
    .frame(maxWidth: .infinity)
    .padding(MacDesignTokens.Spacing.standard)
  }

  private var searchField: some View {
    HStack(spacing: MacDesignTokens.Spacing.small) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.secondary)

      TextField("Search conversations", text: $searchText)
        .textFieldStyle(.plain)
        .focused($searchFocused)

      if chats.isSearching {
        ProgressView()
          .controlSize(.mini)
      } else if !searchText.isEmpty {
        Button {
          searchText = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Clear search")
      } else {
        Text("⌘K")
          .font(.caption2.monospaced())
          .foregroundStyle(.tertiary)
      }
    }
    .padding(.horizontal, MacDesignTokens.Spacing.small)
    .frame(height: 32)
    .background(
      Color.primary.opacity(0.045),
      in: RoundedRectangle(cornerRadius: MacDesignTokens.Radius.small)
    )
    .overlay {
      RoundedRectangle(cornerRadius: MacDesignTokens.Radius.small)
        .stroke(searchFocused ? MacDesignTokens.Colors.accent.opacity(0.55) : .clear, lineWidth: 1)
    }
  }

  private func togglePinned(_ id: ConversationID) {
    var values = pinnedIDSet
    if values.contains(id.rawValue) {
      values.remove(id.rawValue)
    } else {
      values.insert(id.rawValue)
    }
    pinnedConversationIDs = values.sorted().joined(separator: "\n")
  }

  private func removePinned(_ id: ConversationID) {
    var values = pinnedIDSet
    guard values.remove(id.rawValue) != nil else { return }
    pinnedConversationIDs = values.sorted().joined(separator: "\n")
  }

  private func prunePinnedConversations() {
    let validIDs = Set(chats.conversationSummaries.map { $0.id.rawValue })
    let pruned = pinnedIDSet.intersection(validIDs)
    let serialized = pruned.sorted().joined(separator: "\n")
    if serialized != pinnedConversationIDs {
      pinnedConversationIDs = serialized
    }
  }
}

private struct MacConversationRow: View {
  let conversation: ChatConversation
  let selected: Bool
  let pinned: Bool
  let action: () -> Void
  let togglePinned: () -> Void
  let rename: () -> Void
  let delete: () -> Void

  var body: some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: MacDesignTokens.Spacing.xSmall) {
        HStack(alignment: .firstTextBaseline, spacing: MacDesignTokens.Spacing.small) {
          Text(conversation.title.isEmpty ? "New Chat" : conversation.title)
            .font(.system(size: 13, weight: selected ? .semibold : .medium))
            .lineLimit(1)
            .foregroundStyle(.primary)

          Spacer(minLength: MacDesignTokens.Spacing.small)

          Text(conversation.updatedAt.formatted(date: .omitted, time: .shortened))
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }

        if let preview = conversation.lastMessagePreview,
          !preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
          Text(preview)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        } else {
          Text("\(conversation.messageCount) messages")
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
      }
      .padding(.horizontal, MacDesignTokens.Spacing.small)
      .padding(.vertical, 7)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        selected ? MacDesignTokens.Colors.selection : .clear,
        in: RoundedRectangle(cornerRadius: MacDesignTokens.Radius.small)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .contextMenu {
      Button(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.slash" : "pin", action: togglePinned)
      Button("Rename", systemImage: "pencil", action: rename)
      Divider()
      Button("Delete", systemImage: "trash", role: .destructive, action: delete)
    }
    .accessibilityLabel(conversation.title.isEmpty ? "New Chat" : conversation.title)
    .accessibilityValue(pinned ? "Pinned" : "")
  }
}

private struct MacSearchResultRow: View {
  let item: MacChatSessionModel.SearchItem
  let selected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 6) {
          Text(item.title.isEmpty ? "New Chat" : item.title)
            .font(.system(size: 13, weight: selected ? .semibold : .medium))
            .lineLimit(1)
          Spacer(minLength: 6)
          Text(roleLabel)
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        Text(item.snippet)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
      .padding(.horizontal, MacDesignTokens.Spacing.small)
      .padding(.vertical, 7)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        selected ? MacDesignTokens.Colors.selection : .clear,
        in: RoundedRectangle(cornerRadius: MacDesignTokens.Radius.small)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private var roleLabel: String {
    switch item.role {
    case .title: "Title"
    case .user: "You"
    case .assistant: "Assistant"
    }
  }
}

private struct MacRenameConversationSheet: View {
  let conversation: ChatConversation
  let save: (String) async -> Bool

  @Environment(\.dismiss) private var dismiss
  @State private var title: String
  @State private var isSaving = false
  @FocusState private var titleFocused: Bool

  init(conversation: ChatConversation, save: @escaping (String) async -> Bool) {
    self.conversation = conversation
    self.save = save
    _title = State(initialValue: conversation.title)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Rename Conversation")
        .font(.headline)

      TextField("Conversation name", text: $title)
        .textFieldStyle(.roundedBorder)
        .focused($titleFocused)
        .onSubmit { commit() }

      HStack {
        Spacer()
        Button("Cancel") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Rename") { commit() }
          .keyboardShortcut(.defaultAction)
          .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
      }
    }
    .padding(20)
    .frame(width: 380)
    .onAppear {
      titleFocused = true
    }
  }

  private func commit() {
    let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, !isSaving else { return }
    isSaving = true
    Task { @MainActor in
      if await save(value) {
        dismiss()
      } else {
        isSaving = false
      }
    }
  }
}
