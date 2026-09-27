import BYOKchatProviderCore
import Foundation
import Observation
import os
import SwiftUI

struct MacShellView: View {
  let model: MacAppModel

  @Environment(MacUtilitySheetCoordinator.self) private var utilitySheets
  @State private var sidebarVisible = true
  @State private var navigation = MacChatNavigation()
  @State private var didSelectInitialChat = false
  @State private var targetPickerConversationID: ConversationID?
  @State private var toolsConversationID: ConversationID?
  @State private var searchText = ""
  @State private var composerFocusRequestID = 0
  @State private var showingTargetPicker = false
  @State private var showingChatTools = false
  @State private var renameTarget: ChatConversation?
  @State private var deleteTarget: ChatConversation?
  @State private var pendingAttachmentsByKey: [String: [ChatAttachment]] = [:]
  @State private var didRestorePendingAttachments = false

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
    let paneConversationID = navigation.displayedID

    return MacAppShell(
      sidebarVisible: $sidebarVisible,
      sidebarWidth: MacDesignTokens.Layout.sidebarIdeal
    ) {
      MacSidebarView(
        chats: chats,
        selection: $navigation.requestedID,
        searchText: $searchText,
        searchFocusRequestID: model.conversationSearchRequestID,
        newChat: { startNewChat(chats: chats) },
        rename: { renameTarget = $0 },
        delete: { deleteTarget = $0 }
      )
    } content: {
      MacChatPane(
        providers: providers,
        chats: chats,
        mcp: mcp,
        conversationID: paneConversationID,
        summary: chats.summary(paneConversationID),
        retainedConversations: navigation.retainedConversations,
        navigationTarget: navigation.messageTarget,
        isPreparingConversation: navigation.isPreparing,
        composerFocusRequestID: composerFocusRequestID,
        attachments: pendingAttachments(for: paneConversationID),
        sidebarVisible: sidebarVisible,
        toggleSidebar: { sidebarVisible.toggle() },
        chooseTarget: {
          targetPickerConversationID = paneConversationID
          showingTargetPicker = true
        },
        manageProviders: { utilitySheets.present(.providers) },
        configureTools: {
          if let paneConversationID {
            toolsConversationID = paneConversationID
            showingChatTools = true
          }
        },
        appendAttachments: { additions in
          appendAttachments(
            additions,
            conversationID: paneConversationID,
            chats: chats,
            providers: providers
          )
        },
        removeAttachment: { id in
          removePendingAttachment(id, conversationID: paneConversationID, chats: chats)
        },
        send: { text, attachments in
          let sourceConversationID = paneConversationID
          Task { @MainActor in
            if let target = chats.target(for: sourceConversationID) {
              do {
                try providers.validateAttachments(attachments, for: target)
              } catch {
                chats.errorMessage = error.localizedDescription
                return
              }
            }

            if let id = await chats.send(
              conversationID: sourceConversationID,
              text: text,
              attachments: attachments
            ) {
              if sourceConversationID == nil {
                await transferFreshAttachments(to: id, chats: chats)
              }
              if navigation.canFollowSend(from: sourceConversationID) {
                navigation.requestedID = id
              }
              await chats.loadConversation(id)
              await mcp.reloadFromStorage()
              await clearPersistedPendingAttachments(
                conversationID: id,
                chats: chats
              )
            }
          }
        }
      )
    }
    .background(MacDesignTokens.Colors.canvas)
    .onAppear {
      if !didSelectInitialChat {
        didSelectInitialChat = true
        navigation.requestedID = chats.conversationSummaries.first?.id
      }
      chats.updateSearch(searchText)
    }
    .task {
      await restorePendingAttachmentsIfNeeded()
    }
    .task(id: navigation.requestedID) {
      await navigation.prepareSelection { id in
        try await chats.prepareConversation(id)
      }
    }
    .onChange(of: persistedMessageCount(for: navigation.displayedID, chats: chats)) { _, _ in
      guard let displayedID = navigation.displayedID else { return }
      Task { @MainActor in
        await clearPersistedPendingAttachments(
          conversationID: displayedID,
          chats: chats
        )
      }
    }
    .onChange(of: chats.conversationSummaries.map(\.id)) { _, ids in
      navigation.removeDeletedConversations(validIDs: ids)
    }
    .onChange(of: model.newChatRequestID) { _, _ in
      startNewChat(chats: chats, forceReset: true)
    }
    .onChange(of: model.sidebarToggleRequestID) { _, _ in
      sidebarVisible.toggle()
    }
    .onReceive(NotificationCenter.default.publisher(for: .macOpenConversationFromLibrary)) { notification in
      guard let rawValue = notification.object as? String else { return }
      let conversationID = ConversationID(rawValue: rawValue)
      guard chats.summary(conversationID) != nil else { return }
      searchText = ""
      chats.updateSearch("")
      navigation.requestedID = conversationID
      sidebarVisible = true
    }
    .onReceive(NotificationCenter.default.publisher(for: .macScrollToConversationMessage)) { notification in
      guard let request = notification.object as? MacConversationNavigationRequest,
        request.conversationID == navigation.requestedID
      else { return }
      navigation.navigateToMessage(request)
    }
    .sheet(isPresented: $showingTargetPicker) {
      MacTargetPickerView(
        providers: providers,
        initialTarget: chats.target(for: targetPickerConversationID)
      ) { target in
        await chats.applyTarget(target, conversationID: targetPickerConversationID)
      }
    }
    .sheet(isPresented: $showingChatTools) {
      if let toolsConversationID {
        MacChatToolsView(
          mcp: mcp,
          conversationID: toolsConversationID,
          presets: model.workspace?.project(for: toolsConversationID)?.projectToolPresets ?? []
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
          if await chats.deleteConversation(target.id) {
            await mcp.reloadFromStorage()
            await clearPendingAttachments(
              conversationID: target.id,
              chats: chats
            )
            navigation.removeDeletedConversations(validIDs: chats.conversationSummaries.map(\.id))
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
        get: { navigation.errorMessage != nil || chats.errorMessage != nil || mcp.errorMessage != nil },
        set: {
          if !$0 {
            navigation.errorMessage = nil
            chats.errorMessage = nil
            mcp.errorMessage = nil
          }
        }
      )
    ) {
      Button("OK") {
        navigation.errorMessage = nil
        chats.errorMessage = nil
        mcp.errorMessage = nil
      }
    } message: {
      Text(navigation.errorMessage ?? chats.errorMessage ?? mcp.errorMessage ?? "Unknown error")
    }
  }

  private func startNewChat(chats: MacChatSessionModel, forceReset: Bool = false) {
    let freshKey = attachmentKey(nil)
    let hasFreshAttachments = !(pendingAttachmentsByKey[freshKey] ?? []).isEmpty
    let hasFreshDraft = !chats.draft(for: nil)
      .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let shouldResumeFreshWork =
      !forceReset && navigation.requestedID != nil && (hasFreshAttachments || hasFreshDraft)

    navigation.requestedID = nil
    searchText = ""
    chats.updateSearch("")

    if !shouldResumeFreshWork {
      pendingAttachmentsByKey.removeValue(forKey: freshKey)
      if let store = model.pendingAttachmentStore {
        Task { @MainActor in
          do {
            try await store.clear(freshKey)
          } catch {
            MacAppAnalytics.reportError("pending_attachment_store_failed", component: "attachments")
            chats.errorMessage = "New chat was reset, but pending attachment cleanup failed: \(error.localizedDescription)"
          }
        }
      }
      chats.resetNewChat()
    }

    composerFocusRequestID &+= 1
  }

  private func attachmentKey(_ conversationID: ConversationID?) -> String {
    MacPendingAttachmentStore.key(for: conversationID)
  }

  private func pendingAttachments(for conversationID: ConversationID?) -> [ChatAttachment] {
    pendingAttachmentsByKey[attachmentKey(conversationID)] ?? []
  }

  private func appendAttachments(
    _ additions: [ChatAttachment],
    conversationID: ConversationID?,
    chats: MacChatSessionModel,
    providers: MacProviderModel
  ) {
    guard !additions.isEmpty else { return }
    let key = attachmentKey(conversationID)

    Task { @MainActor in
      do {
        if let target = chats.target(for: conversationID) {
          try providers.validateAttachments(additions, for: target)
        }

        if let store = model.pendingAttachmentStore {
          pendingAttachmentsByKey[key] = try await store.append(additions, to: key)
        } else {
          pendingAttachmentsByKey[key] = try MacAttachmentImporter.validateCombined(
            existing: pendingAttachmentsByKey[key] ?? [],
            additions: additions
          )
        }
      } catch {
        MacAppAnalytics.reportError("pending_attachment_store_failed", component: "attachments")
        chats.errorMessage = error.localizedDescription
      }
    }
  }

  private func removePendingAttachment(
    _ id: String,
    conversationID: ConversationID?,
    chats: MacChatSessionModel
  ) {
    let key = attachmentKey(conversationID)
    Task { @MainActor in
      do {
        if let store = model.pendingAttachmentStore {
          let values = try await store.remove(id, from: key)
          if values.isEmpty {
            pendingAttachmentsByKey.removeValue(forKey: key)
          } else {
            pendingAttachmentsByKey[key] = values
          }
        } else {
          guard var values = pendingAttachmentsByKey[key] else { return }
          values.removeAll { $0.id == id }
          if values.isEmpty {
            pendingAttachmentsByKey.removeValue(forKey: key)
          } else {
            pendingAttachmentsByKey[key] = values
          }
        }
      } catch {
        MacAppAnalytics.reportError("pending_attachment_store_failed", component: "attachments")
        chats.errorMessage = "Attachment could not be removed: \(error.localizedDescription)"
      }
    }
  }

  private func transferFreshAttachments(
    to conversationID: ConversationID,
    chats: MacChatSessionModel
  ) async {
    let sourceKey = attachmentKey(nil)
    let destinationKey = attachmentKey(conversationID)

    do {
      if let store = model.pendingAttachmentStore {
        let values = try await store.transfer(from: sourceKey, to: destinationKey)
        pendingAttachmentsByKey.removeValue(forKey: sourceKey)
        if values.isEmpty {
          pendingAttachmentsByKey.removeValue(forKey: destinationKey)
        } else {
          pendingAttachmentsByKey[destinationKey] = values
        }
      } else if let values = pendingAttachmentsByKey.removeValue(forKey: sourceKey), !values.isEmpty {
        pendingAttachmentsByKey[destinationKey] = values
      }
    } catch {
      MacAppAnalytics.reportError("pending_attachment_store_failed", component: "attachments")
      chats.errorMessage = "The chat started, but pending attachments could not be transferred: \(error.localizedDescription)"
    }
  }

  private func persistedMessageCount(
    for conversationID: ConversationID?,
    chats: MacChatSessionModel
  ) -> Int {
    chats.summary(conversationID)?.messageCount ?? 0
  }

  private func clearPersistedPendingAttachments(
    conversationID: ConversationID,
    chats: MacChatSessionModel
  ) async {
    let key = attachmentKey(conversationID)
    guard let pending = pendingAttachmentsByKey[key], !pending.isEmpty else { return }

    let pendingIDs = Set(pending.map(\.id))
    let persistedIDs = Set(
      chats.messages(for: conversationID)
        .flatMap { $0.attachments ?? [] }
        .map(\.id)
    )
    guard pendingIDs.isSubset(of: persistedIDs) else { return }

    do {
      if let store = model.pendingAttachmentStore {
        try await store.clear(key)
      }
      pendingAttachmentsByKey.removeValue(forKey: key)
    } catch {
      MacAppAnalytics.reportError("pending_attachment_store_failed", component: "attachments")
      chats.errorMessage = "Attachments were sent, but pending-state cleanup failed: \(error.localizedDescription)"
    }
  }

  private func clearPendingAttachments(
    conversationID: ConversationID,
    chats: MacChatSessionModel
  ) async {
    let key = attachmentKey(conversationID)
    do {
      if let store = model.pendingAttachmentStore {
        try await store.clear(key)
      }
      pendingAttachmentsByKey.removeValue(forKey: key)
    } catch {
      MacAppAnalytics.reportError("pending_attachment_store_failed", component: "attachments")
      chats.errorMessage = "Conversation was deleted, but pending attachment cleanup failed: \(error.localizedDescription)"
    }
  }

  @MainActor
  private func restorePendingAttachmentsIfNeeded() async {
    guard !didRestorePendingAttachments else { return }
    didRestorePendingAttachments = true
    guard let store = model.pendingAttachmentStore else { return }
    pendingAttachmentsByKey = await store.snapshot()
  }
}

private struct MacAppShell<Sidebar: View, Content: View>: View {
  @Binding var sidebarVisible: Bool
  let sidebarWidth: CGFloat
  private let sidebar: Sidebar
  private let content: Content

  init(
    sidebarVisible: Binding<Bool>,
    sidebarWidth: CGFloat,
    @ViewBuilder sidebar: () -> Sidebar,
    @ViewBuilder content: () -> Content
  ) {
    _sidebarVisible = sidebarVisible
    self.sidebarWidth = sidebarWidth
    self.sidebar = sidebar()
    self.content = content()
  }

  var body: some View {
    HStack(spacing: 0) {
      if sidebarVisible {
        sidebar
          .frame(width: sidebarWidth)
          .transition(.move(edge: .leading).combined(with: .opacity))
      }

      content
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .animation(.easeInOut(duration: 0.18), value: sidebarVisible)
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

  @Environment(MacWorkspaceModel.self) private var workspace
  @Environment(MacMCPModel.self) private var mcp
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
      HStack(spacing: 0) {
        Color.clear
          .frame(width: MacDesignTokens.Layout.titlebarTrafficLightReserve)
          .allowsHitTesting(false)

        Color.clear
          .contentShape(Rectangle())
          .gesture(WindowDragGesture())
          .allowsWindowActivationEvents(true)
      }
      .frame(height: MacDesignTokens.Layout.titlebarHeight)

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
    let currentProject = workspace.project(for: conversation.id)
    return MacConversationRow(
      conversation: conversation,
      selected: selection == conversation.id,
      pinned: pinned,
      currentProject: currentProject,
      projects: workspace.projects,
      action: { selection = conversation.id },
      assignProject: { projectID in
        Task { @MainActor in
          if await workspace.assignConversation(conversation.id, to: projectID) {
            await mcp.reloadFromStorage()
          }
        }
      },
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
  let currentProject: ChatProject?
  let projects: [ChatProject]
  let action: () -> Void
  let assignProject: (ProjectID?) -> Void
  let togglePinned: () -> Void
  let rename: () -> Void
  let delete: () -> Void

  private var otherProjects: [ChatProject] {
    projects.filter { $0.id != currentProject?.id }
  }

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
      projectActions
      if currentProject != nil || !projects.isEmpty {
        Divider()
      }
      Button(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.slash" : "pin", action: togglePinned)
      Button("Rename", systemImage: "pencil", action: rename)
      Divider()
      Button("Delete", systemImage: "trash", role: .destructive, action: delete)
    }
    .accessibilityLabel(conversation.title.isEmpty ? "New Chat" : conversation.title)
    .accessibilityValue(pinned ? "Pinned" : "")
  }

  @ViewBuilder
  private var projectActions: some View {
    if let currentProject {
      Button("Remove from \(currentProject.name)", systemImage: "folder.badge.minus") {
        assignProject(nil)
      }
      if !otherProjects.isEmpty {
        Menu("Move to Project…", systemImage: "folder.badge.plus") {
          ForEach(otherProjects) { project in
            Button(project.name) { assignProject(project.id) }
          }
        }
      }
    } else if !projects.isEmpty {
      Menu("Add to Project…", systemImage: "folder.badge.plus") {
        ForEach(projects) { project in
          Button(project.name) { assignProject(project.id) }
        }
      }
    }
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

struct MacTranscriptNavigationTarget: Equatable, Sendable {
  let token = UUID()
  let request: MacConversationNavigationRequest
}

/// Owns navigation independently of the currently displayed transcript. A late
/// load can warm the data cache, but only the current selection may replace UI.
@MainActor
@Observable
final class MacChatNavigation {
  var requestedID: ConversationID? {
    didSet {
      guard requestedID != oldValue else { return }
      selectionRevision &+= 1
      messageTarget = nil
    }
  }
  private(set) var displayedID: ConversationID?
  private(set) var retainedConversations: [MacPreparedConversation] = [.newChat]
  private(set) var isPreparing = false
  private(set) var messageTarget: MacTranscriptNavigationTarget?
  var errorMessage: String?
  @ObservationIgnored private var selectionRevision = 0
  private let limit = 3

  func prepareSelection(
    using prepare: @MainActor (ConversationID) async throws -> MacPreparedConversation
  ) async {
    guard !Task.isCancelled else { return }
    let requested = requestedID
    let revision = selectionRevision
    let log = OSLog(subsystem: "pro.byok.BYOKchat", category: "ChatSwitch")
    let signpostID = OSSignpostID(log: log)
    os_signpost(.begin, log: log, name: "Chat Selection", signpostID: signpostID)
    defer { os_signpost(.end, log: log, name: "Chat Selection", signpostID: signpostID) }
    isPreparing = true
    defer {
      if revision == selectionRevision { isPreparing = false }
    }

    do {
      let prepared: MacPreparedConversation
      if let retained = retainedConversations.first(where: { $0.id == requested }) {
        prepared = retained
      } else if let requested {
        prepared = try await prepare(requested)
      } else {
        prepared = .newChat
      }
      guard !Task.isCancelled, revision == selectionRevision, requestedID == requested else { return }
      retainedConversations.removeAll { $0.id == requested }
      retainedConversations.append(prepared)
      while retainedConversations.count > limit { retainedConversations.removeFirst() }
      displayedID = requested
      os_signpost(.event, log: log, name: "Display Prepared Chat")
    } catch {
      guard !Task.isCancelled, revision == selectionRevision else { return }
      isPreparing = false
      MacAppAnalytics.reportError("conversation_prepare_failed", component: "chat_storage")
      errorMessage = error.localizedDescription
      requestedID = displayedID
    }
  }

  func canFollowSend(from source: ConversationID?) -> Bool {
    displayedID == source && requestedID == source
  }

  func navigateToMessage(_ request: MacConversationNavigationRequest) {
    guard requestedID == request.conversationID else { return }
    messageTarget = MacTranscriptNavigationTarget(request: request)
  }

  func removeDeletedConversations(validIDs: [ConversationID]) {
    let valid = Set(validIDs)
    let retained = retainedConversations.filter { item in
      item.id.map { valid.contains($0) } ?? true
    }
    if retained.count != retainedConversations.count { retainedConversations = retained }
    if let displayedID, !valid.contains(displayedID) {
      self.displayedID = nil
      if !retainedConversations.contains(where: { $0.id == nil }) {
        retainedConversations.append(.newChat)
      }
    }
    if let requestedID, !valid.contains(requestedID) {
      self.requestedID = validIDs.first
    }
  }
}
