import BYOKchatProviderCore
import Foundation
import Observation

@MainActor
@Observable
final class ChatManagementModel {
  struct LiveMessage: Equatable {
    var content = ""
    var reasoning = ""
    var usage: ProviderUsage?
  }

  private enum GenerationAction {
    case send(String, [ChatAttachment], ChatMessageID)
    case edit(ChatMessageID, String)
    case regenerate(confirmingUncertainCompletion: Bool)
  }

  /// Lightweight index-backed rows. They retain compact usage/attachment metadata
  /// but never full message content; full chat bodies live in hydratedConversations.
  private(set) var conversations: [ChatConversation] = []
  private(set) var liveMessages: [ChatMessageID: LiveMessage] = [:]
  private(set) var activeConversationIDs: Set<ConversationID> = []
  private(set) var activeToolCallsByConversation: [ConversationID: [ChatToolCall]] = [:]
  private(set) var searchResults: [ConversationSearchResult] = []
  private(set) var isSearching = false
  private(set) var isIndexingSearch = false
  private(set) var searchIndexingProgress: ConversationSearchIndexProgress?
  private(set) var searchIndexStatus: ConversationSearchIndexStatus?
  private(set) var streamRevisions: [ConversationID: Int] = [:]
  private(set) var quarantinedShardCount = 0
  var isBusy = false
  var errorMessage: String?
  var onFileReferencesChanged: (() -> Void)?
  var onNewChatDiscarded: (() async -> Void)?
  var onTurnOutcome: ((ConversationID, Bool, Bool) -> Void)?
  var backgroundKeeper: BackgroundActivityKeeper?

  private static let maxHydratedConversations = 12
  private static let draftSaveDebounce: Duration = .milliseconds(650)

  private let providerWorkspace: ProviderWorkspaceStore
  private let conversationStore: ConversationStore
  private let runtime: ChatRuntime
  private let preferences: AppPreferencesModel
  private let mcpWorkspace: MCPWorkspaceStore?
  private let projectWorkspace: ProjectWorkspaceStore?
  /// Resolves the global default account through the provider model's single
  /// rule. Wired from AppModel so chat creation and every UI surface agree.
  var resolveDefaultAccountID: () -> ProviderAccountID?
  private var hydratedConversations: [ConversationID: ChatConversation] = [:]
  @ObservationIgnored private var hydratedOrder: [ConversationID] = []
  private var loadingConversationTasks: [ConversationID: Task<Void, Never>] = [:]
  private var conversationLoadFailures: Set<ConversationID> = []
  private var generationTasks: [ConversationID: Task<Void, Never>] = [:]
  private var draftTasks: [ConversationID: Task<Void, Never>] = [:]
  private var draftRevisions: [ConversationID: UInt] = [:]
  private var searchTask: Task<Void, Never>?
  private var searchRevision: UInt = 0
  private var searchIndexSyncTask: Task<Void, Never>?
  private var streamTargets: [ChatMessageID: LiveMessage] = [:]
  private var streamPresentationTasks: [ChatMessageID: Task<Void, Never>] = [:]

  private var newChatTask: Task<ConversationID?, Never>?
  private var newChatTaskProjectID: ProjectID?
  private var newChatTaskID: UUID?
  private var activeNewChatID: ConversationID?
  private var activeNewChatProjectID: ProjectID?
  private var ownedNewChatIDs: Set<ConversationID> = []
  private var abandonedNewChatIDs: Set<ConversationID> = []
  private var discardingConversationIDs: Set<ConversationID> = []
  private var configurationOperations: [ConversationID: Int] = [:]
  private var failedConfigurationKeys: [ConversationID: Set<String>] = [:]
  private var configurationWaiters: [ConversationID: [CheckedContinuation<Void, Never>]] = [:]
  private var preparingConversationIDs: Set<ConversationID> = []
  private var draftsDuringPreparation: [ConversationID: String] = [:]

  /// List/search surfaces use committed index rows, never optimistic messages
  /// from the hydrated editor. Selecting an unsent chat does not make it history.
  var historyConversations: [ChatConversation] {
    conversations.filter { conversation in
      if conversation.isIOSNewChat == true {
        return conversation.messages.contains { $0.role == .user }
      }
      return conversation.messageCount > 0
    }
  }

  func canSend(_ id: ConversationID) -> Bool {
    hasConversation(id) && !abandonedNewChatIDs.contains(id) && !discardingConversationIDs.contains(id)
      && configurationOperations[id, default: 0] == 0
      && (failedConfigurationKeys[id]?.isEmpty ?? true)
      && generationTasks[id] == nil
  }

  func beginConfiguration(_ id: ConversationID, key: String) -> Bool {
    guard hasConversation(id), !abandonedNewChatIDs.contains(id),
      !discardingConversationIDs.contains(id), !preparingConversationIDs.contains(id)
    else { return false }
    configurationOperations[id, default: 0] += 1
    return true
  }

  func endConfiguration(_ id: ConversationID, key: String, succeeded: Bool) {
    configurationOperations[id, default: 0] -= 1
    if succeeded {
      failedConfigurationKeys[id]?.remove(key)
      if key == "mcp.replace" || key == "mcp.reset" {
        failedConfigurationKeys[id] = failedConfigurationKeys[id]?.filter { !$0.hasPrefix("mcp.") }
      }
    } else if key != "rename" {
      failedConfigurationKeys[id, default: []].insert(key)
    }
    if configurationOperations[id, default: 0] == 0 {
      for waiter in configurationWaiters.removeValue(forKey: id) ?? [] { waiter.resume() }
    }
    retryAbandonedNewChat(id)
  }

  func pendingConfigurationIssue(_ id: ConversationID) -> String? {
    guard !(failedConfigurationKeys[id]?.isEmpty ?? true) else { return nil }
    return "Chat settings could not be saved. Retry the failed setting before sending."
  }

  private func waitForConfiguration(_ id: ConversationID) async {
    guard configurationOperations[id, default: 0] > 0 else { return }
    await withCheckedContinuation { configurationWaiters[id, default: []].append($0) }
  }

  /// One creation task across all entry points. Same-scope requests coalesce;
  /// a different scope waits for creation to settle before allocating its UUID.
  func newChat(projectID: ProjectID?) async -> ConversationID? {
    if let task = newChatTask {
      let scope = newChatTaskProjectID
      let token = newChatTaskID
      let id = await task.value
      finishNewChatCreation(id, projectID: scope, token: token)
      if scope == projectID { return id }
      return await newChat(projectID: projectID)
    }
    if let id = activeNewChatID, activeNewChatProjectID == projectID,
      hasConversation(id), !abandonedNewChatIDs.contains(id), !discardingConversationIDs.contains(id),
      !isGenerating(id), !historyConversations.contains(where: { $0.id == id })
    {
      return id
    }
    newChatTaskProjectID = projectID
    let token = UUID()
    newChatTaskID = token
    let task = Task { @MainActor in
      await self.createConversation(projectID: projectID, managedNewChat: true)
    }
    newChatTask = task
    let id = await task.value
    finishNewChatCreation(id, projectID: projectID, token: token)
    return id
  }

  private func finishNewChatCreation(_ id: ConversationID?, projectID: ProjectID?, token: UUID?) {
    guard newChatTaskID == token else { return }
    if let id {
      activeNewChatID = id
      activeNewChatProjectID = projectID
    }
    newChatTask = nil
    newChatTaskID = nil
  }

  /// Called only by explicit navigation/session changes, not view disappearance.
  func abandonNewChat(_ id: ConversationID?) {
    guard let id, ownedNewChatIDs.contains(id) else { return }
    if activeNewChatID == id { activeNewChatID = nil }
    if historyConversations.contains(where: { $0.id == id }) { return }
    abandonedNewChatIDs.insert(id)
    retryAbandonedNewChat(id)
  }

  func recoverUnsentNewChats() async {
    ownedNewChatIDs.formUnion(conversations.filter { $0.isIOSNewChat == true }.map(\.id))
    for conversation in conversations where conversation.isIOSNewChat == true
      && !conversation.messages.contains(where: { $0.role == .user })
    {
      abandonedNewChatIDs.insert(conversation.id)
      await discardAbandonedNewChat(conversation.id)
    }
  }

  func retryAbandonedNewChats() {
    for id in abandonedNewChatIDs { retryAbandonedNewChat(id) }
  }

  private func retryAbandonedNewChat(_ id: ConversationID) {
    guard abandonedNewChatIDs.contains(id) else { return }
    Task { @MainActor in await self.discardAbandonedNewChat(id) }
  }

  private func discardAbandonedNewChat(_ id: ConversationID) async {
    guard abandonedNewChatIDs.contains(id), ownedNewChatIDs.contains(id),
      activeNewChatID != id, generationTasks[id] == nil,
      configurationOperations[id, default: 0] == 0,
      discardingConversationIDs.insert(id).inserted
    else { return }
    defer { discardingConversationIDs.remove(id) }

    // Reserve the ID before awaiting. Send/configuration/draft writes now refuse
    // it; drain an already-running debounce before reading durable eligibility.
    if let task = draftTasks.removeValue(forKey: id) {
      task.cancel()
      await task.value
    }
    await loadingConversationTasks[id]?.value
    draftRevisions.removeValue(forKey: id)
    do {
      if let persisted = try await conversationStore.persistedConversation(id: id) {
        guard persisted.isIOSNewChat == true else {
          abandonedNewChatIDs.remove(id)
          return
        }
        if persisted.messages.contains(where: { $0.role == .user }) {
          abandonedNewChatIDs.remove(id)
          try await conversationStore.restorePersistedConversation(id: id)
          try await reloadSnapshot()
          return
        }
      }
      // The owning shard is deleted LAST. A crash/partial failure before then
      // retains the durable marker so startup can retry companion cleanup.
      try await mcpWorkspace?.removeChatConfiguration(conversationID: id)
      try await projectWorkspace?.removeConversation(id)
      try await conversationStore.deleteConversation(id)
      removeHydratedConversation(id)
      failedConfigurationKeys.removeValue(forKey: id)
      configurationOperations.removeValue(forKey: id)
      abandonedNewChatIDs.remove(id)
      ownedNewChatIDs.remove(id)
      try await reloadSnapshot()
      await onNewChatDiscarded?()
    } catch {
      // Keep ownership and the hidden cleanup-pending ID; foreground/startup
      // can retry without reusing it or deleting a sent conversation.
      errorMessage = "Could not discard an unsent chat: \(error.localizedDescription)"
    }
  }

  private static let streamPresentationInterval: Duration = .milliseconds(50)

  init(
    providerWorkspace: ProviderWorkspaceStore,
    conversations: ConversationStore,
    runtime: ChatRuntime,
    preferences: AppPreferencesModel,
    mcpWorkspace: MCPWorkspaceStore? = nil,
    projectWorkspace: ProjectWorkspaceStore? = nil,
    resolveDefaultAccountID: @escaping () -> ProviderAccountID? = { nil }
  ) {
    self.providerWorkspace = providerWorkspace
    self.conversationStore = conversations
    self.runtime = runtime
    self.preferences = preferences
    self.mcpWorkspace = mcpWorkspace
    self.projectWorkspace = projectWorkspace
    self.resolveDefaultAccountID = resolveDefaultAccountID
  }

  func load() async {
    do {
      try await conversationStore.load()
      try await reloadSnapshot()
    } catch {
      BYOKAppAnalytics.reportError("conversation_store_failed", component: "chat_storage")
      errorMessage = error.localizedDescription
    }
  }

  /// Returns a full hydrated chat only. If the chat exists only as an index row,
  /// kick off one shard read and return nil for this render pass. This lets the
  /// existing root navigation wait naturally without ever treating summaries
  /// as full message histories.
  func conversation(_ id: ConversationID) -> ChatConversation? {
    // Navigation can keep the outgoing view alive while an unsent chat is
    // being removed. Do not schedule another shard read for that retired ID.
    guard !abandonedNewChatIDs.contains(id), !discardingConversationIDs.contains(id) else {
      return nil
    }
    if let hydrated = hydratedConversations[id] {
      touchHydratedOrder(id)
      return hydrated
    }
    guard conversations.contains(where: { $0.id == id }), !conversationLoadFailures.contains(id) else {
      return nil
    }
    Task { @MainActor [weak self] in
      await self?.loadConversation(id)
    }
    return nil
  }

  /// Composer-style provider · model · effort label, sanitized for analytics.
  private func analyticsDimension(
    conversationID: ConversationID?,
    providerID: ProviderID? = nil
  ) async -> String? {
    guard let conversationID,
      let conversation = hydratedConversations[conversationID] ?? summary(conversationID)
    else { return nil }
    let resolvedProviderID = providerID ?? conversation.providerID
    let kind = ProviderKind(providerID: resolvedProviderID)
    let providerName = kind.displayName.isEmpty ? resolvedProviderID.rawValue : kind.displayName
    let modelID = conversation.modelID
    let modelRecord = await providerWorkspace.modelRecords(
      for: conversation.accountID, includeHidden: true
    ).first { $0.model.id == modelID }
    let capabilities = ModelCapabilityResolver.resolve(
      kind: kind, modelID: modelID, model: modelRecord?.model
    )
    return ComposerTargetLabelFormatter.analyticsDimension(
      providerID: resolvedProviderID,
      providerName: providerName,
      modelName: modelRecord?.model.displayName ?? modelID.rawValue,
      modelID: modelID.rawValue,
      supportedParameters: modelRecord?.model.supportedParameters ?? [],
      reasoning: conversation.options.reasoning,
      capabilities: capabilities
    )
  }

  /// Index-backed metadata lookup; never schedules a conversation shard read.
  func summary(_ id: ConversationID) -> ChatConversation? {
    conversations.first { $0.id == id }
  }

  func hasConversation(_ id: ConversationID) -> Bool {
    conversations.contains { $0.id == id }
  }

  func loadConversation(_ id: ConversationID, displayScale: CGFloat = 3) async {
    // Recheck here too: conversation(_:) schedules an unstructured task, and
    // ChatView also calls this directly. Either can arrive after Back retires
    // the chat. Cleanup drains existing loads before deleting its shard.
    guard hasConversation(id), !abandonedNewChatIDs.contains(id),
      !discardingConversationIDs.contains(id)
    else { return }
    if let task = loadingConversationTasks[id] {
      await task.value
      return
    }
    if let existing = hydratedConversations[id] {
      await prewarmConversationContent(existing, displayScale: displayScale)
      return
    }
    let task = Task { @MainActor in
      do {
        let loaded = try await self.conversationStore.conversation(id: id)
        await self.prewarmConversationContent(loaded, displayScale: displayScale)
        self.setHydratedConversation(loaded)
        self.conversationLoadFailures.remove(id)
        let refreshedSummaries = await self.conversationStore.conversationSummaries()
        if self.conversations != refreshedSummaries {
          try await self.reloadSnapshot()
        }
      } catch {
        BYOKAppAnalytics.reportError("conversation_store_failed", component: "chat_storage")
        self.conversationLoadFailures.insert(id)
        self.errorMessage = error.localizedDescription
      }
    }
    loadingConversationTasks[id] = task
    await task.value
    loadingConversationTasks.removeValue(forKey: id)
  }

  /// Pre-parses the initially visible tail messages and warms the last few
  /// visible image thumbnails off the main actor so frame 1 hits caches
  /// directly instead of stalling the sidebar close transition.
  private func prewarmConversationContent(
    _ conversation: ChatConversation,
    displayScale: CGFloat
  ) async {
    let targetPixelSize = ChatAttachmentPresentation.bubble.imageWidth * max(displayScale, 1)
    let tailMessages = Array(
      conversation.messages.suffix(ChatMessageWindowPolicy.initialVisibleCount)
    )
    let recentImageAttachments = Array(
      tailMessages.reversed()
        .flatMap { ($0.attachments ?? []).reversed() }
        .filter(\.isImage)
        .prefix(6)
    )
    let store = conversationStore
    await Task.detached(priority: .userInitiated) {
      MarkdownParseCache.shared.prewarm(messages: tailMessages)
      await withTaskGroup(of: Void.self) { group in
        for attachment in recentImageAttachments {
          let key = AsyncAttachmentThumbnail.cacheKey(for: attachment.id)
          if AttachmentThumbnailLoader.cachedImage(
            cacheKey: key,
            maxPixelSize: targetPixelSize
          ) != nil {
            continue
          }
          group.addTask {
            if !attachment.data.isEmpty {
              _ = await AttachmentThumbnailLoader.decodeImage(
                from: attachment.data,
                cacheKey: key,
                maxPixelSize: targetPixelSize,
                alreadyDownsampled: false
              )
            } else if let bytes = await store.attachmentThumbnail(
              attachment.id,
              maxPixelSize: targetPixelSize
            ), !bytes.isEmpty {
              _ = await AttachmentThumbnailLoader.decodeImage(
                from: bytes,
                cacheKey: key,
                maxPixelSize: targetPixelSize,
                alreadyDownsampled: true
              )
            }
          }
        }
      }
    }.value
  }

  func failedToLoad(_ id: ConversationID) -> Bool {
    conversationLoadFailures.contains(id)
  }

  func displayMessage(_ message: ChatMessage) -> ChatMessage {
    guard let live = liveMessages[message.id] else { return message }
    var result = message
    result.content = live.content
    result.reasoning = live.reasoning
    result.usage = live.usage ?? message.usage
    result.status = .streaming
    return result
  }

  func draft(for conversationID: ConversationID) -> String {
    conversation(conversationID)?.draftText ?? ""
  }

  func streamRevision(for conversationID: ConversationID) -> Int {
    streamRevisions[conversationID] ?? 0
  }

  func activeToolCalls(for conversationID: ConversationID) -> [ChatToolCall] {
    activeToolCallsByConversation[conversationID] ?? []
  }

  var defaultSystemPrompt: String { preferences.defaultSystemPrompt }

  func saveDraft(_ text: String, conversationID: ConversationID) {
    guard hasConversation(conversationID), !abandonedNewChatIDs.contains(conversationID),
      !discardingConversationIDs.contains(conversationID)
    else { return }
    if preparingConversationIDs.contains(conversationID) {
      draftsDuringPreparation[conversationID] = text
      return
    }
    let value = text.isEmpty ? nil : text
    if var loaded = hydratedConversations[conversationID] {
      loaded.draftText = value
      hydratedConversations[conversationID] = loaded
    }
    if let index = conversations.firstIndex(where: { $0.id == conversationID }) {
      conversations[index].draftText = value
    }

    draftTasks[conversationID]?.cancel()
    let revision = (draftRevisions[conversationID] ?? 0) &+ 1
    draftRevisions[conversationID] = revision
    draftTasks[conversationID] = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        try await Task.sleep(for: Self.draftSaveDebounce)
        try Task.checkCancellation()
        guard draftRevisions[conversationID] == revision else { return }
        try await conversationStore.setDraft(text, conversationID: conversationID)
        try Task.checkCancellation()
      } catch is CancellationError {
      } catch {
        errorMessage = error.localizedDescription
      }
      if draftRevisions[conversationID] == revision {
        draftTasks.removeValue(forKey: conversationID)
      }
    }
  }

  func setFullTextSearchEnabled(_ enabled: Bool) {
    searchIndexSyncTask?.cancel()
    let store = conversationStore
    searchIndexSyncTask = Task(priority: .utility) { @MainActor [weak self] in
      guard let self else { return }
      await store.setFullTextSearchEnabled(enabled)
      if enabled {
        self.isIndexingSearch = true
        await store.reconcileSearchIndex { [weak self] progress in
          Task { @MainActor in
            self?.searchIndexingProgress = progress
          }
        }
        self.isIndexingSearch = false
        self.searchIndexingProgress = nil
      } else {
        self.isIndexingSearch = false
        self.searchIndexingProgress = nil
      }
      if !Task.isCancelled {
        self.searchIndexStatus = await store.searchIndexStatus()
      }
    }
  }

  @discardableResult
  func refreshSearchIndexStatus() async -> ConversationSearchIndexStatus {
    let status = await conversationStore.searchIndexStatus()
    searchIndexStatus = status
    return status
  }

  func reconcileSearchIndex() async {
    isIndexingSearch = true
    defer {
      isIndexingSearch = false
      searchIndexingProgress = nil
    }
    await conversationStore.reconcileSearchIndex { [weak self] progress in
      Task { @MainActor in
        self?.searchIndexingProgress = progress
      }
    }
    searchIndexStatus = await conversationStore.searchIndexStatus()
  }

  func rebuildSearchIndex() async throws {
    isIndexingSearch = true
    defer {
      isIndexingSearch = false
      searchIndexingProgress = nil
    }
    try await conversationStore.rebuildSearchIndex { [weak self] progress in
      Task { @MainActor in
        self?.searchIndexingProgress = progress
      }
    }
    searchIndexStatus = await conversationStore.searchIndexStatus()
  }

  func clearSearchIndex() async throws {
    try await conversationStore.clearSearchIndex()
    searchIndexStatus = await conversationStore.searchIndexStatus()
  }

  func debugSearchFullText(
    _ query: String,
    limit: Int = 50
  ) async -> ConversationSearchQueryResult {
    let result = await conversationStore.searchFullTextWithMetrics(query, limit: limit)
    searchIndexStatus = await conversationStore.searchIndexStatus()
    return result
  }

  func search(_ query: String, hasPro: Bool = false) {
    searchTask?.cancel()
    searchRevision &+= 1
    let revision = searchRevision
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      searchResults = []
      isSearching = false
      searchTask = nil
      return
    }

    let allowFullText = BYOKProAccess.canUseFullTextSearch(hasPro: hasPro)
    isSearching = true
    searchTask = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        try await Task.sleep(for: .milliseconds(180))
        try Task.checkCancellation()
        let results: [ConversationSearchResult]
        if allowFullText {
          results = await conversationStore.searchFullText(trimmed)
        } else {
          results = await conversationStore.searchTitles(trimmed)
        }
        try Task.checkCancellation()
        guard searchRevision == revision else { return }
        let visibleIDs = Set(historyConversations.map(\.id))
        searchResults = results.filter { visibleIDs.contains($0.conversationID) }
        isSearching = false
        searchTask = nil
      } catch {
        if searchRevision == revision {
          isSearching = false
          searchTask = nil
        }
      }
    }
  }

  @discardableResult
  func createConversation(
    projectID: ProjectID? = nil,
    managedNewChat: Bool = false
  ) async -> ConversationID? {
    var createdID: ConversationID?
    do {
      let accounts = await providerWorkspace.allAccounts().filter(\.isEnabled)
      guard !accounts.isEmpty else {
        throw ProviderError.invalidRequest("Configure a provider account before creating a chat.")
      }

      let project: ChatProject?
      if let projectID {
        guard let projectWorkspace else {
          throw ProviderError.invalidRequest("Project storage is unavailable.")
        }
        project = try await projectWorkspace.project(id: projectID)
      } else {
        project = nil
      }

      let account: ProviderAccount
      if let accountID = project?.accountID {
        guard let configured = accounts.first(where: { $0.id == accountID }) else {
          throw ProviderError.invalidRequest(
            "This project's provider account is unavailable. Edit the project defaults first."
          )
        }
        account = configured
      } else {
        // One default rule shared with the provider UI: the provider model's
        // resolved default (stored-if-usable → ready → enabled → first),
        // which already falls back in memory without rewriting the store.
        guard let defaultID = resolveDefaultAccountID() else {
          throw ProviderError.invalidRequest("Configure a provider account before creating a chat.")
        }
        account = accounts.first(where: { $0.id == defaultID }) ?? accounts[0]
      }

      let models = await providerWorkspace.modelRecords(for: account.id)
      let modelID: ModelID
      if let configuredModelID = project?.modelID {
        guard models.contains(where: { $0.model.id == configuredModelID && $0.isAvailable }) else {
          throw ProviderError.invalidRequest(
            "This project's default model is unavailable. Edit the project defaults first."
          )
        }
        modelID = configuredModelID
      } else if let fallback = models.first(where: {
        $0.model.id == account.defaultModelID && $0.isAvailable
      })?.model.id ?? models.first(where: \.isAvailable)?.model.id {
        modelID = fallback
      } else {
        throw ProviderError.invalidModel
      }

      let projectInstructions = project?.instructions.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      let systemPrompt = projectInstructions.isEmpty
        ? AppPreferencesModel.normalizedSystemPrompt(preferences.defaultSystemPrompt)
        : projectInstructions

      let id = ConversationID()
      createdID = id
      if managedNewChat { ownedNewChatIDs.insert(id) }
      let conversation = try await conversationStore.createConversation(
        providerID: account.providerID,
        accountID: account.id,
        modelID: modelID,
        systemPrompt: systemPrompt,
        options: .init(),
        id: id,
        isIOSNewChat: managedNewChat ? true : nil
      )
      setHydratedConversation(conversation)

      if let projectID, let projectWorkspace {
        do {
          try await projectWorkspace.assignConversation(conversation.id, to: projectID)
        } catch {
          if !managedNewChat {
            try? await conversationStore.deleteConversation(conversation.id)
            removeHydratedConversation(conversation.id)
          }
          throw error
        }
      }

      try await reloadSnapshot()
      return conversation.id
    } catch {
      BYOKAppAnalytics.reportError("conversation_store_failed", component: "chat_storage")
      errorMessage = error.localizedDescription
      if managedNewChat, let createdID {
        abandonedNewChatIDs.insert(createdID)
        await discardAbandonedNewChat(createdID)
      }
      return nil
    }
  }

  func deleteConversation(_ id: ConversationID) async {
    guard discardingConversationIDs.insert(id).inserted else { return }
    defer { discardingConversationIDs.remove(id) }
    await stop(id)
    await waitForConfiguration(id)
    await loadingConversationTasks[id]?.value
    if let task = draftTasks.removeValue(forKey: id) {
      task.cancel()
      await task.value
    }
    draftRevisions.removeValue(forKey: id)
    streamRevisions.removeValue(forKey: id)
    activeToolCallsByConversation.removeValue(forKey: id)
    removeHydratedConversation(id)
    conversationLoadFailures.remove(id)
    do {
      try await mcpWorkspace?.removeChatConfiguration(conversationID: id)
      try await projectWorkspace?.removeConversation(id)
      try await conversationStore.deleteConversation(id)
      ownedNewChatIDs.remove(id)
      abandonedNewChatIDs.remove(id)
      failedConfigurationKeys.removeValue(forKey: id)
      if activeNewChatID == id { activeNewChatID = nil }
      try await reloadSnapshot()
    } catch {
      BYOKAppAnalytics.reportError("conversation_store_failed", component: "chat_storage")
      errorMessage = error.localizedDescription
    }
  }

  func renameConversation(_ id: ConversationID, title: String) async {
    guard beginConfiguration(id, key: "rename") else { return }
    var succeeded = false
    defer { endConfiguration(id, key: "rename", succeeded: succeeded) }
    do {
      try await conversationStore.renameConversation(id, title: title)
      try await reloadSnapshot()
      succeeded = true
    } catch {
      BYOKAppAnalytics.reportError("conversation_store_failed", component: "chat_storage")
      errorMessage = error.localizedDescription
    }
  }

  func updateTarget(
    conversationID: ConversationID,
    account: ProviderAccount,
    modelID: ModelID,
    systemPrompt: String,
    options: ProviderRequestOptions
  ) async -> Bool {
    guard beginConfiguration(conversationID, key: "target") else { return false }
    var succeeded = false
    defer { endConfiguration(conversationID, key: "target", succeeded: succeeded) }
    do {
      let model = await providerWorkspace.modelRecords(for: account.id, includeHidden: true)
        .first { $0.model.id == modelID }?.model
      var options = options
      options.reasoning = ModelCapabilityResolver.resolve(kind: account.kind, modelID: modelID, model: model)
        .reasoning.normalize(options.reasoning)
      try await conversationStore.updateTarget(
        conversationID,
        providerID: account.providerID,
        accountID: account.id,
        modelID: modelID,
        systemPrompt: systemPrompt,
        options: options
      )
      try await reloadSnapshot()
      succeeded = true
      return true
    } catch {
      BYOKAppAnalytics.reportError("conversation_store_failed", component: "chat_storage")
      errorMessage = error.localizedDescription
      return false
    }
  }

  func resetSystemPrompt(_ conversationID: ConversationID) async {
    guard let conversation = conversation(conversationID) else { return }
    guard
      let account = await providerWorkspace.allAccounts().first(where: {
        $0.id == conversation.accountID
      })
    else { return }
    _ = await updateTarget(
      conversationID: conversationID,
      account: account,
      modelID: conversation.modelID,
      systemPrompt: AppPreferencesModel.normalizedSystemPrompt(preferences.defaultSystemPrompt),
      options: conversation.options
    )
  }

  /// Propagates a changed default system prompt into staged, unsent iOS new
  /// chats that have no overriding project instructions and still carry the
  /// previous default. Conversations with messages are never modified.
  func syncDefaultSystemPrompt(from previousDefault: String, to updatedDefault: String) async {
    let previous = AppPreferencesModel.normalizedSystemPrompt(previousDefault)
    let updated = AppPreferencesModel.normalizedSystemPrompt(updatedDefault)
    guard previous != updated else { return }

    let candidateIDs = conversations.compactMap { summary -> ConversationID? in
      guard summary.isIOSNewChat == true,
        summary.messageCount == 0,
        !activeConversationIDs.contains(summary.id),
        !abandonedNewChatIDs.contains(summary.id)
      else { return nil }
      return summary.id
    }
    guard !candidateIDs.isEmpty else { return }

    var didUpdateAny = false
    for id in candidateIDs {
      if let project = await projectWorkspace?.project(for: id),
        !project.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        continue
      }
      let full: ChatConversation
      if let cached = hydratedConversations[id] {
        full = cached
      } else if let loaded = try? await conversationStore.conversation(id: id) {
        full = loaded
      } else {
        continue
      }
      guard full.isIOSNewChat == true,
        full.messages.isEmpty,
        AppPreferencesModel.normalizedSystemPrompt(full.systemPrompt) == previous
      else { continue }

      guard beginConfiguration(id, key: "defaultSystemPrompt") else { continue }
      var succeeded = false
      defer { endConfiguration(id, key: "defaultSystemPrompt", succeeded: succeeded) }
      do {
        try await conversationStore.updateTarget(
          id,
          providerID: full.providerID,
          accountID: full.accountID,
          modelID: full.modelID,
          systemPrompt: updated,
          options: full.options
        )
        succeeded = true
        didUpdateAny = true
      } catch {
        continue
      }
    }

    if didUpdateAny {
      try? await reloadSnapshot()
    }
  }

  func referencedAttachmentIDs() async -> Set<String> {
    await conversationStore.referencedAttachmentIDs()
  }

  func attachmentThumbnail(_ id: String, maxPixelSize: CGFloat) async -> Data? {
    await conversationStore.attachmentThumbnail(id, maxPixelSize: maxPixelSize)
  }

  func attachmentData(_ id: String) async -> Data? {
    await conversationStore.attachmentData(id)
  }

  @discardableResult
  func send(
    conversationID: ConversationID,
    text: String,
    attachments: [ChatAttachment] = [],
    onMessagePersisted: (@MainActor (Bool) -> Void)? = nil
  ) -> Bool {
    guard canSend(conversationID) else { return false }
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    else { return false }
    preparingConversationIDs.insert(conversationID)
    let userMessageID = ChatMessageID()

    if var conversation = hydratedConversations[conversationID],
      conversation.isIOSNewChat != true || historyConversations.contains(where: { $0.id == conversationID })
    {
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty || !attachments.isEmpty {
        let now = Date.now
        let optimistic = ChatMessage(
          id: userMessageID,
          role: .user,
          content: trimmed,
          attachments: attachments.isEmpty ? nil : attachments,
          createdAt: now,
          updatedAt: now,
          status: .complete,
          providerID: conversation.providerID,
          accountID: conversation.accountID,
          modelID: conversation.modelID
        )
        conversation.messages.append(optimistic)
        conversation.updatedAt = now
        hydratedConversations[conversationID] = conversation
      }
    }

    startGeneration(
      conversationID: conversationID,
      action: .send(text, attachments, userMessageID),
      onMessagePersisted: onMessagePersisted
    )
    return true
  }

  func editAndResend(
    conversationID: ConversationID,
    messageID: ChatMessageID,
    text: String
  ) {
    startGeneration(conversationID: conversationID, action: .edit(messageID, text))
  }

  func regenerate(
    conversationID: ConversationID,
    confirmingUncertainCompletion: Bool = false
  ) {
    startGeneration(
      conversationID: conversationID,
      action: .regenerate(
        confirmingUncertainCompletion: confirmingUncertainCompletion
      )
    )
  }

  func stop(_ conversationID: ConversationID) async {
    guard let consumerTask = generationTasks[conversationID] else { return }

    await runtime.cancel(conversationID: conversationID)
    consumerTask.cancel()
    await consumerTask.value
    try? await reloadSnapshot()
    clearLiveMessages(for: conversationID)
    activeToolCallsByConversation.removeValue(forKey: conversationID)
  }

  func persistActiveMessages() async {
    await runtime.flushActiveGenerations()
    try? await reloadSnapshot()
  }

  var hasActiveGenerations: Bool {
    !activeConversationIDs.isEmpty
  }

  func isGenerating(_ conversationID: ConversationID) -> Bool {
    activeConversationIDs.contains(conversationID)
  }

  func latestAssistantRequiresRegenerationConfirmation(_ conversationID: ConversationID) -> Bool {
    guard
      let conversation = conversation(conversationID),
      let userIndex = conversation.messages.lastIndex(where: { $0.role == .user })
    else { return false }
    return conversation.messages[(userIndex + 1)..<conversation.messages.endIndex]
      .contains { $0.requiresRegenerationConfirmation }
  }

  func handleBackgroundExpiration() async {
    for id in activeConversationIDs {
      await stop(id)
    }
    backgroundKeeper?.end()
  }

  private func startGeneration(
    conversationID: ConversationID,
    action: GenerationAction,
    onMessagePersisted: (@MainActor (Bool) -> Void)? = nil
  ) {
    guard canSend(conversationID) else { return }
    if activeConversationIDs.isEmpty {
      backgroundKeeper?.begin()
    }
    activeConversationIDs.insert(conversationID)
    activeToolCallsByConversation.removeValue(forKey: conversationID)
    generationTasks[conversationID] = Task { @MainActor [weak self] in
      guard let self else { return }
      var didReceiveInlineFailure = false
      var reportedPersistence = false
      var didRecordAnalyticsOutcome = false
      let isRegenerate: Bool = {
        if case .regenerate = action { return true }
        return false
      }()
      let previousUserCount = conversations.first(where: { $0.id == conversationID })?
        .messages.filter { $0.role == .user }.count ?? 0
      defer {
        clearLiveMessages(for: conversationID)
        activeConversationIDs.remove(conversationID)
        if activeConversationIDs.isEmpty {
          backgroundKeeper?.end()
        }
        activeToolCallsByConversation.removeValue(forKey: conversationID)
        generationTasks.removeValue(forKey: conversationID)
        retryAbandonedNewChat(conversationID)
      }
      do {
        let stream: AsyncThrowingStream<ChatRuntimeEvent, Error>
        switch action {
        case .send(let text, let attachments, let userMessageID):
          if let draftTask = draftTasks.removeValue(forKey: conversationID) {
            draftTask.cancel()
            await draftTask.value
          }
          try Task.checkCancellation()
          stream = await runtime.send(
            conversationID: conversationID,
            userText: text,
            attachments: attachments,
            userMessageID: userMessageID
          )
        case .edit(let messageID, let text):
          stream = await runtime.editAndResend(
            conversationID: conversationID,
            messageID: messageID,
            newText: text
          )
        case .regenerate(let confirmingUncertainCompletion):
          stream = await runtime.regenerate(
            conversationID: conversationID,
            confirmingUncertainCompletion: confirmingUncertainCompletion
          )
        }
        for try await event in stream {
          if case .turnStarted = event, !reportedPersistence {
            reportedPersistence = true
            finishSendPreparation(conversationID, committed: true, action: action)
            onMessagePersisted?(true)
            switch action {
            case .send(_, let attachments, _):
              if !attachments.isEmpty {
                let dimension: BYOKAppAnalytics.Dimension = attachments.allSatisfy({ $0.isImage })
                  ? .image : (attachments.contains(where: { $0.isImage }) ? .mixed : .file)
                BYOKAppAnalytics.track(.attachmentSent, dimension: dimension)
              }
            case .edit:
              BYOKAppAnalytics.track(.messageEdited)
            case .regenerate:
              BYOKAppAnalytics.track(.responseRegenerated)
            }
          }
          // Some terminal runtime events are followed by a thrown error.
          // Count the outcome here once, with catch blocks only as a fallback.
          switch event {
          case .completed(let message):
            if !didRecordAnalyticsOutcome {
              didRecordAnalyticsOutcome = true
              onTurnOutcome?(conversationID, true, isRegenerate)
              BYOKAppAnalytics.track(
                .chatTurnCompleted,
                detail: await analyticsDimension(
                  conversationID: conversationID, providerID: message.providerID
                )
              )
            }
          case .cancelled(let message):
            if !didRecordAnalyticsOutcome {
              didRecordAnalyticsOutcome = true
              BYOKAppAnalytics.track(
                .chatTurnCancelled,
                detail: await analyticsDimension(
                  conversationID: conversationID, providerID: message.providerID
                )
              )
            }
          case .failed(let message):
            if !didRecordAnalyticsOutcome {
              didRecordAnalyticsOutcome = true
              onTurnOutcome?(conversationID, false, isRegenerate)
              BYOKAppAnalytics.reportError("chat_generation_failed", component: "chat")
              BYOKAppAnalytics.track(
                .chatTurnFailed,
                detail: await analyticsDimension(
                  conversationID: conversationID, providerID: message.providerID
                )
              )
            }
          default:
            break
          }
          if case .failed = event {
            didReceiveInlineFailure = true
          }
          await handle(event, conversationID: conversationID)
        }
      } catch is CancellationError {
        if !didRecordAnalyticsOutcome, reportedPersistence {
          didRecordAnalyticsOutcome = true
          BYOKAppAnalytics.track(
            .chatTurnCancelled,
            detail: await analyticsDimension(conversationID: conversationID)
          )
        }
        try? await reloadSnapshot()
      } catch {
        if !didRecordAnalyticsOutcome {
          didRecordAnalyticsOutcome = true
          onTurnOutcome?(conversationID, false, isRegenerate)
          BYOKAppAnalytics.reportError("chat_generation_failed", component: "chat")
          if !reportedPersistence {
            BYOKAppAnalytics.reportError(
              "conversation_prepare_failed", component: "chat_storage"
            )
          }
          BYOKAppAnalytics.track(
            reportedPersistence ? .chatTurnFailed : .chatPreparationFailed,
            detail: await analyticsDimension(conversationID: conversationID)
          )
        }
        if !didReceiveInlineFailure {
          errorMessage = error.localizedDescription
        }
        try? await reloadSnapshot()
      }
      // A cancelled AsyncThrowingStream may end without throwing or draining
      // its terminal event; still record one outcome for an accepted turn.
      if reportedPersistence, !didRecordAnalyticsOutcome {
        if !Task.isCancelled {
          BYOKAppAnalytics.reportError("chat_generation_failed", component: "chat")
        }
        BYOKAppAnalytics.track(
          Task.isCancelled ? .chatTurnCancelled : .chatTurnFailed,
          detail: await analyticsDimension(conversationID: conversationID)
        )
      }
      if !reportedPersistence {
        // The shard may have committed even if the index write failed. Read it
        // before deciding whether to retain the composer or expose history.
        var committed = false
        do {
          let persisted = try await conversationStore.persistedConversation(id: conversationID)
          let userCount = persisted?.messages.filter { $0.role == .user }.count ?? 0
          committed = userCount > previousUserCount
          try await conversationStore.restorePersistedConversation(id: conversationID)
          try await reloadSnapshot()
          finishSendPreparation(conversationID, committed: committed, action: action)
          onMessagePersisted?(committed)
        } catch {
          errorMessage = error.localizedDescription
          finishSendPreparation(conversationID, committed: committed, action: action)
          onMessagePersisted?(committed)
        }
      }
    }
  }

  private func finishSendPreparation(_ id: ConversationID, committed: Bool, action: GenerationAction) {
    guard preparingConversationIDs.remove(id) != nil else { return }
    let latestDraft = draftsDuringPreparation.removeValue(forKey: id)
    if let latestDraft {
      saveDraft(latestDraft, conversationID: id)
    } else if !committed, case .send(let text, _, _) = action {
      saveDraft(text, conversationID: id)
    }
  }

  private func handle(_ event: ChatRuntimeEvent, conversationID: ConversationID) async {
    switch event {
    case .turnStarted(let turn):
      let live = LiveMessage()
      streamTargets[turn.assistantMessage.id] = live
      liveMessages[turn.assistantMessage.id] = live
      activeToolCallsByConversation.removeValue(forKey: conversationID)
      try? await reloadSnapshot()
      advanceStreamRevision(for: conversationID)
    case .textDelta(let messageID, let value):
      updateStreamTarget(messageID, conversationID: conversationID) { live in
        live.content += value
      }
    case .reasoningDelta(let messageID, let value):
      updateStreamTarget(messageID, conversationID: conversationID) { live in
        live.reasoning += value
      }
    case .usage(let messageID, let value):
      updateStreamTarget(messageID, conversationID: conversationID) { live in
        live.usage = value
      }
    case .toolCallsStarted(_, let calls):
      activeToolCallsByConversation[conversationID] = calls
      advanceStreamRevision(for: conversationID)
    case .toolRound(let messageID, _):
      await flushStreamPresentation(messageID, conversationID: conversationID)
      activeToolCallsByConversation.removeValue(forKey: conversationID)
      let live = LiveMessage()
      streamTargets[messageID] = live
      liveMessages[messageID] = live
      try? await reloadSnapshot()
      advanceStreamRevision(for: conversationID)
    case .completed(let message), .cancelled(let message), .failed(let message):
      await flushStreamPresentation(message.id, conversationID: conversationID)
      activeToolCallsByConversation.removeValue(forKey: conversationID)
      try? await reloadSnapshot()
      streamTargets.removeValue(forKey: message.id)
      liveMessages.removeValue(forKey: message.id)
      advanceStreamRevision(for: conversationID)
    }
  }

  private func reloadSnapshot() async throws {
    conversations = await conversationStore.conversationSummaries()
    ownedNewChatIDs.formUnion(conversations.filter { $0.isIOSNewChat == true }.map(\.id))
    let visibleIDs = Set(historyConversations.map(\.id))
    searchResults.removeAll { !visibleIDs.contains($0.conversationID) }
    let validIDs = Set(conversations.map(\.id))
    for id in Array(hydratedConversations.keys) where !validIDs.contains(id) {
      removeHydratedConversation(id)
    }
    for id in Array(hydratedConversations.keys) {
      if let refreshed = await conversationStore.cachedConversation(id: id) {
        hydratedConversations[id] = refreshed
      }
    }
    evictHydratedConversationsIfNeeded()
    quarantinedShardCount = await conversationStore.quarantinedShardCount
    if let flushError = await conversationStore.flushError {
      await conversationStore.clearFlushError()
      if errorMessage == nil {
        errorMessage = "Could not save recent chat changes: \(flushError.localizedDescription)"
      }
    }

    let currentMessageIDs = Set(hydratedConversations.values.flatMap(\.messages).map(\.id))
    let stalePresentationIDs = Set(streamPresentationTasks.keys).subtracting(currentMessageIDs)
    for messageID in stalePresentationIDs {
      streamPresentationTasks.removeValue(forKey: messageID)?.cancel()
    }
    liveMessages = liveMessages.filter { currentMessageIDs.contains($0.key) }
    streamTargets = streamTargets.filter { currentMessageIDs.contains($0.key) }
    onFileReferencesChanged?()
  }

  /// Releases idle hydrated conversations, parsed Markdown trees, and decoded
  /// thumbnails under iOS memory pressure without disrupting visible/active chats.
  func trimMemoryCaches(keeping pinnedIDs: Set<ConversationID> = []) async {
    let protected = protectedHydratedIDs(including: pinnedIDs)
    for id in Array(hydratedConversations.keys) where !protected.contains(id) {
      removeHydratedConversation(id)
    }
    await conversationStore.evictCachedConversations(keeping: protected)
    MarkdownParseCache.shared.removeAll()
    AttachmentThumbnailLoader.clearMemoryCache()
  }

  private func setHydratedConversation(_ conversation: ChatConversation) {
    hydratedConversations[conversation.id] = conversation
    touchHydratedOrder(conversation.id)
    evictHydratedConversationsIfNeeded()
  }

  private func removeHydratedConversation(_ id: ConversationID) {
    hydratedConversations.removeValue(forKey: id)
    hydratedOrder.removeAll { $0 == id }
  }

  private func touchHydratedOrder(_ id: ConversationID) {
    if hydratedOrder.last == id { return }
    hydratedOrder.removeAll { $0 == id }
    hydratedOrder.append(id)
  }

  private func protectedHydratedIDs(including extra: Set<ConversationID> = []) -> Set<ConversationID> {
    var protected = extra
    protected.formUnion(activeConversationIDs)
    protected.formUnion(preparingConversationIDs)
    protected.formUnion(loadingConversationTasks.keys)
    protected.formUnion(draftTasks.keys)
    for (id, count) in configurationOperations where count > 0 {
      protected.insert(id)
    }
    if let activeNewChatID {
      protected.insert(activeNewChatID)
    }
    return protected
  }

  private func evictHydratedConversationsIfNeeded() {
    guard hydratedOrder.count > Self.maxHydratedConversations else { return }
    let protected = protectedHydratedIDs()
    while hydratedOrder.count > Self.maxHydratedConversations {
      guard let index = hydratedOrder.firstIndex(where: { !protected.contains($0) }) else {
        break
      }
      let evictedID = hydratedOrder.remove(at: index)
      hydratedConversations.removeValue(forKey: evictedID)
    }
  }

  private func clearLiveMessages(for conversationID: ConversationID) {
    guard let conversation = hydratedConversations[conversationID] else { return }
    let messageIDs = Set(conversation.messages.map(\.id))
    let previousCount = liveMessages.count
    for messageID in messageIDs {
      streamPresentationTasks.removeValue(forKey: messageID)?.cancel()
      streamTargets.removeValue(forKey: messageID)
    }
    liveMessages = liveMessages.filter { !messageIDs.contains($0.key) }
    if liveMessages.count != previousCount {
      advanceStreamRevision(for: conversationID)
    }
  }

  private func advanceStreamRevision(for conversationID: ConversationID) {
    streamRevisions[conversationID, default: 0] &+= 1
  }

  private func updateStreamTarget(
    _ messageID: ChatMessageID,
    conversationID: ConversationID,
    update: (inout LiveMessage) -> Void
  ) {
    var target = streamTargets[messageID] ?? liveMessages[messageID] ?? .init()
    update(&target)
    streamTargets[messageID] = target
    scheduleStreamPresentation(messageID, conversationID: conversationID)
  }

  private func scheduleStreamPresentation(
    _ messageID: ChatMessageID,
    conversationID: ConversationID
  ) {
    guard streamPresentationTasks[messageID] == nil else { return }

    streamPresentationTasks[messageID] = Task { @MainActor [weak self] in
      guard let self else { return }
      defer { self.streamPresentationTasks.removeValue(forKey: messageID) }
      do {
        try await Task.sleep(for: Self.streamPresentationInterval)
      } catch {
        return
      }
      presentStreamTarget(messageID, conversationID: conversationID)
    }
  }

  private func presentStreamTarget(
    _ messageID: ChatMessageID,
    conversationID: ConversationID
  ) {
    guard let target = streamTargets[messageID], liveMessages[messageID] != target else { return }
    liveMessages[messageID] = target
    advanceStreamRevision(for: conversationID)
  }

  private func flushStreamPresentation(
    _ messageID: ChatMessageID,
    conversationID: ConversationID
  ) async {
    if let task = streamPresentationTasks.removeValue(forKey: messageID) {
      task.cancel()
      await task.value
    }
    presentStreamTarget(messageID, conversationID: conversationID)
  }

}
