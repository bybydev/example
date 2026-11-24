import AppKit
import BYOKchatProviderCore
import Foundation
import MacAppFoundation
import Observation
import os
import SwiftUI
import UniformTypeIdentifiers

struct MacShellView: View {
  let model: MacAppModel

  @Environment(MacUtilitySheetCoordinator.self) private var utilitySheets
  @Environment(PurchaseManager.self) private var purchaseManager
  @Environment(MacProGateCenter.self) private var proGateCenter
  @Environment(\.controlActiveState) private var controlActiveState
  @Environment(\.macToastCenter) private var toastCenter
  @State private var sidebarVisible = true
  @State private var navigation = MacChatNavigation()
  @State private var didSelectInitialChat = false
  @State private var targetPickerConversationID: ConversationID?
  @State private var toolsConversationID: ConversationID?
  @State private var chatSettingsConversationID: ConversationID?
  @State private var searchText = ""
  @State private var pendingSearchFocus = false
  @State private var composerFocusRequestID = 0
  @State private var showingTargetPicker = false
  @State private var showingChatTools = false
  @State private var showingChatSettings = false
  @State private var renameTarget: ChatConversation?
  @State private var deleteTarget: ChatConversation?
  @State private var pendingAttachmentsByKey: [String: [ChatAttachment]] = [:]
  @State private var didRestorePendingAttachments = false
  @State private var activeUpsellFeature: MacProFeature?
  @State private var pendingUpsellFeature: MacProFeature?
  @State private var upsellFallbackTask: Task<Void, Never>?

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
        providers: providers,
        chats: chats,
        selection: $navigation.requestedID,
        searchText: $searchText,
        pendingSearchFocus: $pendingSearchFocus,
        newChat: { startNewChat(chats: chats) },
        selectSearchResult: { item in
          navigation.requestedID = item.conversationID
          if let messageID = item.messageID {
            navigation.navigateToMessage(
              MacConversationNavigationRequest(
                conversationID: item.conversationID,
                messageID: messageID
              )
            )
          }
        },
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
          toolsConversationID = paneConversationID
          showingChatTools = true
        },
        openChatSettings: {
          chatSettingsConversationID = paneConversationID
          showingChatSettings = true
        },
        openProjects: { utilitySheets.present(.projects) },
        openAnalytics: { utilitySheets.presentAnalytics(conversationID: paneConversationID) },
        renameConversation: {
          if let conversation = chats.conversation(paneConversationID) ?? chats.summary(paneConversationID) {
            renameTarget = conversation
          }
        },
        exportMarkdown: {
          exportConversationAsMarkdown(
            conversationID: paneConversationID,
            chats: chats,
            providers: providers
          )
        },
        deleteConversation: {
          if let conversation = chats.conversation(paneConversationID) ?? chats.summary(paneConversationID) {
            deleteTarget = conversation
          }
        },
        startNewChat: { startNewChat(chats: chats, forceReset: true) },
        focusComposer: { composerFocusRequestID &+= 1 },
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
      if MacProAccess.canUseChatSearch(hasPro: purchaseManager.hasPro) {
        chats.updateSearch(searchText)
      } else {
        chats.updateSearch("")
      }
    }
    .onDisappear {
      upsellFallbackTask?.cancel()
      upsellFallbackTask = nil
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
    .onChange(of: model.conversationSearchRequestID) { _, _ in
      sidebarVisible = true
      pendingSearchFocus = true
    }
    .onChange(of: model.sidebarToggleRequestID) { _, _ in
      sidebarVisible.toggle()
    }
    .onChange(of: model.exportMarkdownRequestID) { _, _ in
      exportConversationAsMarkdown(
        conversationID: navigation.displayedID,
        chats: chats,
        providers: providers
      )
    }
    .onChange(of: proGateCenter.upsellRequestID) { _, _ in
      handleProUpsellRequest()
    }
    .onChange(of: utilitySheets.destination) { _, destination in
      guard destination == nil, let pending = pendingUpsellFeature else { return }
      pendingUpsellFeature = nil
      Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(250))
        activeUpsellFeature = pending
      }
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
        initialTarget: chats.target(for: targetPickerConversationID),
        maxOutputTokens: chats.effectiveOptions(for: targetPickerConversationID).maxOutputTokens
      ) { target in
        await chats.applyTarget(target, conversationID: targetPickerConversationID)
      }
    }
    .sheet(isPresented: $showingChatSettings) {
      let project: ChatProject? = if let chatSettingsConversationID {
        model.workspace?.project(for: chatSettingsConversationID)
      } else {
        model.workspace?.project(chats.newChatProjectID)
      }
      MacChatSettingsView(
        chats: chats,
        providers: providers,
        conversationID: chatSettingsConversationID,
        project: project
      )
    }
    .sheet(isPresented: $showingChatTools) {
      let target = chats.target(for: toolsConversationID)
      let modelSupportsTools = target.map {
        providers.capabilities(accountID: $0.accountID, modelID: $0.modelID)[.tools] != .unsupported
      } ?? true
      let draftProjectID = toolsConversationID == nil ? chats.newChatProjectID : nil
      let project = toolsConversationID.flatMap { model.workspace?.project(for: $0) }
        ?? model.workspace?.project(draftProjectID)
      MacChatToolsView(
        mcp: mcp,
        conversationID: toolsConversationID,
        projectID: draftProjectID,
        draftConfiguration: toolsConversationID == nil
          ? Binding(
              get: { chats.newChatMCPConfiguration },
              set: { chats.setNewChatMCPConfiguration($0) }
            )
          : nil,
        presets: project?.projectToolPresets ?? [],
        isGenerating: chats.isGenerating(toolsConversationID),
        modelSupportsTools: modelSupportsTools,
        manageServers: {
          showingChatTools = false
          utilitySheets.present(.mcpServers)
        }
      )
    }
    .sheet(item: $renameTarget) { conversation in
      MacRenameConversationSheet(conversation: conversation) { title in
        await chats.renameConversation(conversation.id, title: title)
      }
    }
    .sheet(item: $activeUpsellFeature) { feature in
      MacProUpsellSheet(feature: feature)
    }
    .confirmationDialog(
      deleteDialogTitle,
      isPresented: deleteDialogPresented,
      titleVisibility: .visible
    ) {
      Button("Delete Conversation", role: .destructive) {
        confirmDeleteConversation(chats: chats, mcp: mcp)
      }
      Button("Cancel", role: .cancel) {
        deleteTarget = nil
      }
    } message: {
      Text("This removes the conversation and its chat-specific project/tool references. This cannot be undone.")
    }
    .alert(
      "Chat Error",
      isPresented: chatErrorPresented(chats: chats, mcp: mcp)
    ) {
      Button("OK") {
        clearChatErrors(chats: chats, mcp: mcp)
      }
    } message: {
      Text(chatErrorMessage(chats: chats, mcp: mcp))
    }
  }

  private var deleteDialogTitle: String {
    guard let target = deleteTarget else { return "Delete conversation?" }
    let title = target.title.isEmpty ? "New Chat" : target.title
    return "Delete \"\(title)\"?"
  }

  private var deleteDialogPresented: Binding<Bool> {
    Binding(
      get: { deleteTarget != nil },
      set: { if !$0 { deleteTarget = nil } }
    )
  }

  private func confirmDeleteConversation(chats: MacChatSessionModel, mcp: MacMCPModel) {
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

  private func chatErrorPresented(
    chats: MacChatSessionModel,
    mcp: MacMCPModel
  ) -> Binding<Bool> {
    Binding(
      get: { navigation.errorMessage != nil || chats.errorMessage != nil || mcp.errorMessage != nil },
      set: { if !$0 { clearChatErrors(chats: chats, mcp: mcp) } }
    )
  }

  private func clearChatErrors(chats: MacChatSessionModel, mcp: MacMCPModel) {
    navigation.errorMessage = nil
    chats.errorMessage = nil
    mcp.errorMessage = nil
  }

  private func chatErrorMessage(chats: MacChatSessionModel, mcp: MacMCPModel) -> String {
    navigation.errorMessage ?? chats.errorMessage ?? mcp.errorMessage ?? "Unknown error"
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

  private func exportConversationAsMarkdown(
    conversationID: ConversationID?,
    chats: MacChatSessionModel,
    providers: MacProviderModel
  ) {
    guard let conversationID else {
      toastCenter?.warning("Open a conversation with messages to export.")
      return
    }
    Task { @MainActor in
      await chats.loadConversation(conversationID)
      guard let conversation = chats.conversation(conversationID), !conversation.messages.isEmpty else {
        toastCenter?.warning("This conversation has no messages to export.")
        return
      }
      let accountLabel = providers.account(conversation.accountID)?.label
      let markdown = ConversationMarkdownFormatter.render(conversation, accountLabel: accountLabel)
      let filename = "\(MacConversationExportSupport.markdownFilename(for: conversation.title)).md"

      let panel = NSSavePanel()
      panel.allowedContentTypes = [.markdown]
      panel.canCreateDirectories = true
      panel.isExtensionHidden = false
      panel.nameFieldStringValue = filename
      panel.title = "Export Conversation as Markdown"

      let response: NSApplication.ModalResponse
      if let window = NSApp.keyWindow {
        response = await panel.beginSheetModal(for: window)
      } else {
        response = panel.runModal()
      }
      guard response == .OK, let destinationURL = panel.url else { return }

      do {
        try Data(markdown.utf8).write(to: destinationURL, options: .atomic)
        toastCenter?.success("Exported \"\(destinationURL.lastPathComponent)\"")
      } catch {
        toastCenter?.error("Export failed: \(error.localizedDescription)")
        chats.errorMessage = "Could not export Markdown: \(error.localizedDescription)"
      }
    }
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

  private func handleProUpsellRequest() {
    upsellFallbackTask?.cancel()
    if controlActiveState == .key, let feature = proGateCenter.claimPendingUpsell() {
      presentProUpsell(feature)
      return
    }

    // Allow a focused secondary window (such as Settings) one turn to claim the
    // upsell first; otherwise present it from the main workspace window.
    upsellFallbackTask = Task { @MainActor in
      await Task.yield()
      guard !Task.isCancelled, let feature = proGateCenter.claimPendingUpsell() else { return }
      presentProUpsell(feature)
    }
  }

  private func presentProUpsell(_ feature: MacProFeature) {
    if utilitySheets.destination != nil {
      pendingUpsellFeature = feature
      utilitySheets.dismiss()
    } else {
      activeUpsellFeature = feature
    }
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

struct MacChatListSection: Identifiable, Equatable, Sendable {
  let id: String
  let title: String
  let isPinned: Bool
  let conversations: [ChatConversation]
}

enum MacChatListGrouping {
  static func sections(
    from history: [ChatConversation],
    pinnedIDs: Set<String>,
    now: Date = .now,
    calendar: Calendar = .current,
    locale: Locale = .current
  ) -> [MacChatListSection] {
    let sortedByRecency: (ChatConversation, ChatConversation) -> Bool = { lhs, rhs in
      if lhs.updatedAt != rhs.updatedAt {
        return lhs.updatedAt > rhs.updatedAt
      }
      return lhs.id.rawValue > rhs.id.rawValue
    }

    let pinned = history
      .filter { pinnedIDs.contains($0.id.rawValue) }
      .sorted(by: sortedByRecency)
    let unpinned = history
      .filter { !pinnedIDs.contains($0.id.rawValue) }
      .sorted(by: sortedByRecency)

    var sections: [MacChatListSection] = []
    if !pinned.isEmpty {
      sections.append(
        MacChatListSection(
          id: "pinned",
          title: "Pinned",
          isPinned: true,
          conversations: pinned
        )
      )
    }

    let startOfToday = calendar.startOfDay(for: now)
    let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday
    let startOfLast7Days = calendar.date(byAdding: .day, value: -7, to: startOfToday) ?? startOfToday
    let startOfLast30Days = calendar.date(byAdding: .day, value: -30, to: startOfToday) ?? startOfToday

    var today: [ChatConversation] = []
    var yesterday: [ChatConversation] = []
    var last7Days: [ChatConversation] = []
    var last30Days: [ChatConversation] = []
    var monthOrder: [String] = []
    var monthTitles: [String: String] = [:]
    var monthBuckets: [String: [ChatConversation]] = [:]
    let monthFormat = Date.FormatStyle(
      locale: locale,
      calendar: calendar,
      timeZone: calendar.timeZone
    ).month(.wide).year()

    for conversation in unpinned {
      if conversation.updatedAt >= startOfToday {
        today.append(conversation)
      } else if conversation.updatedAt >= startOfYesterday {
        yesterday.append(conversation)
      } else if conversation.updatedAt >= startOfLast7Days {
        last7Days.append(conversation)
      } else if conversation.updatedAt >= startOfLast30Days {
        last30Days.append(conversation)
      } else {
        let components = calendar.dateComponents([.year, .month], from: conversation.updatedAt)
        let year = components.year ?? 0
        let month = components.month ?? 0
        let key = "month-\(year)-\(month)"
        if monthBuckets[key] == nil {
          monthOrder.append(key)
          let monthAnchor = calendar.date(from: DateComponents(year: year, month: month, day: 1))
            ?? conversation.updatedAt
          monthTitles[key] = monthAnchor.formatted(monthFormat)
        }
        monthBuckets[key, default: []].append(conversation)
      }
    }

    if !today.isEmpty {
      sections.append(
        MacChatListSection(id: "today", title: "Today", isPinned: false, conversations: today)
      )
    }
    if !yesterday.isEmpty {
      sections.append(
        MacChatListSection(
          id: "yesterday",
          title: "Yesterday",
          isPinned: false,
          conversations: yesterday
        )
      )
    }
    if !last7Days.isEmpty {
      sections.append(
        MacChatListSection(
          id: "last7days",
          title: "Previous 7 Days",
          isPinned: false,
          conversations: last7Days
        )
      )
    }
    if !last30Days.isEmpty {
      sections.append(
        MacChatListSection(
          id: "last30days",
          title: "Previous 30 Days",
          isPinned: false,
          conversations: last30Days
        )
      )
    }
    for key in monthOrder {
      guard let items = monthBuckets[key], !items.isEmpty else { continue }
      sections.append(
        MacChatListSection(
          id: key,
          title: monthTitles[key] ?? "Older",
          isPinned: false,
          conversations: items
        )
      )
    }

    return sections
  }
}

enum MacSidebarSearchSupport {
  static func subtitle(
    for item: MacChatSessionModel.SearchItem,
    summary: ChatConversation?
  ) -> String? {
    let trimmedTitle = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedSnippet = item.snippet.trimmingCharacters(in: .whitespacesAndNewlines)
    if item.role == .title || trimmedSnippet == trimmedTitle {
      let preview = summary?.lastMessagePreview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      return preview.isEmpty ? nil : preview
    }
    return trimmedSnippet.isEmpty ? nil : trimmedSnippet
  }

  static func titleMatches(
    for query: String,
    in conversations: [ChatConversation],
    limit: Int = 120
  ) -> [MacChatSessionModel.SearchItem] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }

    let cap = max(1, limit)
    var results: [MacChatSessionModel.SearchItem] = []
    results.reserveCapacity(min(cap, 32))

    for conversation in conversations {
      guard
        conversation.title.range(
          of: trimmed,
          options: [.caseInsensitive, .diacriticInsensitive]
        ) != nil
      else { continue }
      results.append(
        MacChatSessionModel.SearchItem(
          conversationID: conversation.id,
          messageID: nil,
          title: conversation.title,
          snippet: conversation.title,
          role: .title,
          updatedAt: conversation.updatedAt
        )
      )
      if results.count == cap { break }
    }

    return results
  }
}

private struct MacSidebarProjectIconView: View {
  let project: ChatProject
  var size: CGFloat = 17

  private var color: Color {
    MacProjectAccentOption(rawValue: project.accentID)?.color ?? .blue
  }

  var body: some View {
    Image(systemName: project.symbolName)
      .font(.system(size: size * 0.48, weight: .semibold))
      .foregroundStyle(color)
      .frame(width: size, height: size)
      .background(
        color.opacity(0.14),
        in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
      )
      .accessibilityHidden(true)
  }
}

private struct MacSidebarView: View {
  @Bindable var providers: MacProviderModel
  @Bindable var chats: MacChatSessionModel
  @Binding var selection: ConversationID?
  @Binding var searchText: String
  @Binding var pendingSearchFocus: Bool
  let newChat: () -> Void
  let selectSearchResult: (MacChatSessionModel.SearchItem) -> Void
  let rename: (ChatConversation) -> Void
  let delete: (ChatConversation) -> Void

  @Environment(MacWorkspaceModel.self) private var workspace
  @Environment(MacMCPModel.self) private var mcp
  @Environment(PurchaseManager.self) private var purchaseManager
  @AppStorage("byokchat.sidebar.pinnedConversationIDs") private var pinnedConversationIDs = ""
  @FocusState private var searchFocused: Bool

  private var isSearching: Bool {
    !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private var canUseFullTextSearch: Bool {
    MacProAccess.canUseChatSearch(hasPro: purchaseManager.hasPro)
  }

  private var isCheckingEntitlement: Bool {
    purchaseManager.entitlementState == .checking
  }

  private var displayedSearchItems: [MacChatSessionModel.SearchItem] {
    if canUseFullTextSearch {
      return chats.searchItems
    }
    return MacSidebarSearchSupport.titleMatches(
      for: searchText,
      in: chats.conversationSummaries
    )
  }

  private var pinnedIDSet: Set<String> {
    Set(
      pinnedConversationIDs
        .split(separator: "\n")
        .map(String.init)
    )
  }

  private var conversationSections: [MacChatListSection] {
    MacChatListGrouping.sections(
      from: chats.conversationSummaries,
      pinnedIDs: pinnedIDSet
    )
  }

  private var accountsByID: [ProviderAccountID: ProviderAccount] {
    Dictionary(
      providers.accounts.map { ($0.id, $0) },
      uniquingKeysWith: { first, _ in first }
    )
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
      if pendingSearchFocus {
        pendingSearchFocus = false
        searchFocused = true
      }
    }
    .onChange(of: pendingSearchFocus) { _, shouldFocus in
      guard shouldFocus else { return }
      pendingSearchFocus = false
      searchFocused = true
    }
    .onChange(of: searchText) { _, value in
      if canUseFullTextSearch {
        chats.updateSearch(value)
      } else if !chats.searchItems.isEmpty || chats.isSearching {
        chats.updateSearch("")
      }
    }
    .onChange(of: purchaseManager.hasPro) { _, hasPro in
      if MacProAccess.canUseChatSearch(hasPro: hasPro) {
        if isSearching {
          chats.updateSearch(searchText)
        }
      } else {
        chats.updateSearch("")
      }
    }
    .onChange(of: chats.conversationSummaries.map(\.id)) { _, _ in
      prunePinnedConversations()
    }
  }

  private var conversationList: some View {
    let sections = conversationSections
    let accounts = accountsByID
    return Group {
      if chats.conversationSummaries.isEmpty {
        sidebarEmptyState(icon: "bubble.left", text: "No conversations yet")
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
              sidebarSectionTitle(section.title, topPadding: index == 0 ? 2 : 12)
              ForEach(section.conversations) { conversation in
                conversationRow(conversation, account: accounts[conversation.accountID])
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

  private func conversationRow(
    _ conversation: ChatConversation,
    account: ProviderAccount?
  ) -> some View {
    let pinned = pinnedIDSet.contains(conversation.id.rawValue)
    let currentProject = workspace.project(for: conversation.id)
    let hasDraft = !chats.draft(for: conversation.id)
      .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    return MacConversationRow(
      conversation: conversation,
      account: account,
      selected: selection == conversation.id,
      pinned: pinned,
      isGenerating: chats.isGenerating(conversation.id),
      hasDraft: hasDraft,
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

  private var indexingProgressLabel: String {
    if let progress = chats.searchIndexingProgress, progress.total > 0 {
      return "Indexing messages (\(progress.processed)/\(progress.total))…"
    }
    return "Indexing messages…"
  }

  private var searchResults: some View {
    let items = displayedSearchItems
    return VStack(spacing: 0) {
      if canUseFullTextSearch && chats.isIndexingSearch {
        HStack(spacing: 7) {
          ProgressView()
            .controlSize(.mini)
          Text(indexingProgressLabel)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
          Spacer(minLength: 0)
        }
        .padding(.horizontal, MacDesignTokens.Spacing.compact)
        .padding(.vertical, 6)
        Divider()
      } else if !canUseFullTextSearch {
        proSearchUpsellCallout
        Divider()
      }

      if canUseFullTextSearch && chats.isSearching && items.isEmpty {
        VStack {
          Spacer()
          ProgressView()
            .controlSize(.mini)
          Spacer()
        }
        .frame(maxWidth: .infinity)
      } else if items.isEmpty {
        sidebarEmptyState(
          icon: "magnifyingglass",
          text: canUseFullTextSearch ? "No matching conversations" : "No matching chat titles"
        )
      } else {
        ScrollView {
          LazyVStack(spacing: 2) {
            ForEach(items) { item in
              MacSearchResultRow(
                item: item,
                subtitle: MacSidebarSearchSupport.subtitle(
                  for: item,
                  summary: chats.summary(item.conversationID)
                ),
                project: workspace.project(for: item.conversationID),
                selected: selection == item.conversationID
              ) {
                selectSearchResult(item)
              }
            }
          }
          .padding(.horizontal, MacDesignTokens.Spacing.small)
          .padding(.vertical, MacDesignTokens.Spacing.small)
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var proSearchUpsellCallout: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .top, spacing: 8) {
        Image(systemName: "crown.fill")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(MacDesignTokens.Colors.accent)
          .padding(.top, 1)
          .accessibilityHidden(true)

        VStack(alignment: .leading, spacing: 2) {
          Text("Full-Text Chat Search is a BYOK Pro feature")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(MacDesignTokens.Colors.textPrimary)
            .fixedSize(horizontal: false, vertical: true)

          Text("Showing matching chat titles. Upgrade to search every message and attachment.")
            .font(.system(size: 11))
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      Button {
        MacProAccess.requestUpgrade(.chatSearch)
      } label: {
        Text("Upgrade to Pro")
          .font(.system(size: 11.5, weight: .semibold))
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.small)
      .disabled(isCheckingEntitlement)
    }
    .padding(10)
    .background(
      MacDesignTokens.Colors.surface,
      in: RoundedRectangle(cornerRadius: MacDesignTokens.Radius.medium, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: MacDesignTokens.Radius.medium, style: .continuous)
        .stroke(MacDesignTokens.Colors.separator.opacity(0.82), lineWidth: 1)
    }
    .padding(.horizontal, MacDesignTokens.Spacing.small)
    .padding(.vertical, MacDesignTokens.Spacing.small)
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

      TextField(
        canUseFullTextSearch ? "Search chats and messages" : "Search chat titles",
        text: $searchText
      )
        .textFieldStyle(.plain)
        .focused($searchFocused)

      if canUseFullTextSearch && chats.isSearching {
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
  let account: ProviderAccount?
  let selected: Bool
  let pinned: Bool
  let isGenerating: Bool
  let hasDraft: Bool
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
        HStack(alignment: .center, spacing: 6) {
          if let currentProject {
            MacSidebarProjectIconView(project: currentProject, size: 17)
          }

          Text(conversation.title.isEmpty ? "New Chat" : conversation.title)
            .font(.system(size: 13, weight: selected ? .semibold : .medium))
            .lineLimit(1)
            .foregroundStyle(.primary)

          Spacer(minLength: 4)

          if isGenerating {
            ProgressView()
              .controlSize(.mini)
              .accessibilityLabel("Generating")
          }

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

        HStack(spacing: 4) {
          Text(account?.label ?? conversation.providerID.rawValue)
          Text("·")
          Text(conversation.modelID.rawValue)
          if hasDraft {
            Text("· Draft")
              .foregroundStyle(MacDesignTokens.Colors.accent)
          }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .lineLimit(1)
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
  let subtitle: String?
  let project: ChatProject?
  let selected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 4) {
        HStack(alignment: .center, spacing: 6) {
          if let project {
            MacSidebarProjectIconView(project: project, size: 17)
          }
          Text(item.title.isEmpty ? "New Chat" : item.title)
            .font(.system(size: 13, weight: selected ? .semibold : .medium))
            .lineLimit(1)
          Spacer(minLength: 6)
          Text(roleLabel)
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        if let subtitle {
          Text(subtitle)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
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

