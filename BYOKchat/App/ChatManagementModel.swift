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
    case send(String, [ChatAttachment])
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
  private(set) var streamRevisions: [ConversationID: Int] = [:]
  var isBusy = false
  var errorMessage: String?
  var onFileReferencesChanged: (() -> Void)?
  var backgroundKeeper: BackgroundActivityKeeper?

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
  private var loadingConversationIDs: Set<ConversationID> = []
  private var conversationLoadFailures: Set<ConversationID> = []
  private var generationTasks: [ConversationID: Task<Void, Never>] = [:]
  private var draftTasks: [ConversationID: Task<Void, Never>] = [:]
  private var draftRevisions: [ConversationID: UInt] = [:]
  private var searchTask: Task<Void, Never>?
  private var searchRevision: UInt = 0
  private var streamTargets: [ChatMessageID: LiveMessage] = [:]
  private var streamPresentationTasks: [ChatMessageID: Task<Void, Never>] = [:]

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
      errorMessage = error.localizedDescription
    }
  }

  /// Returns a full hydrated chat only. If the chat exists only as an index row,
  /// kick off one shard read and return nil for this render pass. This lets the
  /// existing root navigation wait naturally without ever treating summaries
  /// as full message histories.
  func conversation(_ id: ConversationID) -> ChatConversation? {
    if let hydrated = hydratedConversations[id] { return hydrated }
    guard conversations.contains(where: { $0.id == id }), !conversationLoadFailures.contains(id) else {
      return nil
    }
    Task { @MainActor [weak self] in
      await self?.loadConversation(id)
    }
    return nil
  }

  func hasConversation(_ id: ConversationID) -> Bool {
    conversations.contains { $0.id == id }
  }

  func loadConversation(_ id: ConversationID) async {
    guard hydratedConversations[id] == nil, loadingConversationIDs.insert(id).inserted else { return }
    defer { loadingConversationIDs.remove(id) }
    do {
      hydratedConversations[id] = try await conversationStore.conversation(id: id)
      conversationLoadFailures.remove(id)
      try await reloadSnapshot()
    } catch {
      conversationLoadFailures.insert(id)
      errorMessage = error.localizedDescription
    }
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
        try await Task.sleep(for: .milliseconds(250))
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

  func search(_ query: String) {
    searchTask?.cancel()
    searchRevision &+= 1
    let revision = searchRevision
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      searchResults = []
      searchTask = nil
      return
    }

    searchTask = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        try await Task.sleep(for: .milliseconds(180))
        try Task.checkCancellation()
        let results = await conversationStore.search(trimmed)
        try Task.checkCancellation()
        guard searchRevision == revision else { return }
        searchResults = results
        searchTask = nil
      } catch {
      }
    }
  }

  @discardableResult
  func createConversation(projectID: ProjectID? = nil) async -> ConversationID? {
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
      } else if let fallback = account.defaultModelID ?? models.first(where: \.isAvailable)?.model.id {
        modelID = fallback
      } else {
        throw ProviderError.invalidModel
      }

      let projectInstructions = project?.instructions.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      let systemPrompt = projectInstructions.isEmpty
        ? preferences.defaultSystemPrompt
        : projectInstructions

      let conversation = try await conversationStore.createConversation(
        providerID: account.providerID,
        accountID: account.id,
        modelID: modelID,
        systemPrompt: systemPrompt,
        options: .init()
      )
      hydratedConversations[conversation.id] = conversation

      if let projectID, let projectWorkspace {
        do {
          try await projectWorkspace.assignConversation(conversation.id, to: projectID)
        } catch {
          try? await conversationStore.deleteConversation(conversation.id)
          hydratedConversations.removeValue(forKey: conversation.id)
          throw error
        }
      }

      try await reloadSnapshot()
      return conversation.id
    } catch {
      errorMessage = error.localizedDescription
      return nil
    }
  }

  func deleteConversation(_ id: ConversationID) async {
    await stop(id)
    draftTasks[id]?.cancel()
    draftTasks.removeValue(forKey: id)
    draftRevisions.removeValue(forKey: id)
    streamRevisions.removeValue(forKey: id)
    activeToolCallsByConversation.removeValue(forKey: id)
    hydratedConversations.removeValue(forKey: id)
    conversationLoadFailures.remove(id)
    do {
      try await conversationStore.deleteConversation(id)
      try await mcpWorkspace?.removeChatConfiguration(conversationID: id)
      try await projectWorkspace?.removeConversation(id)
      try await reloadSnapshot()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func renameConversation(_ id: ConversationID, title: String) async {
    do {
      try await conversationStore.renameConversation(id, title: title)
      try await reloadSnapshot()
    } catch {
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
      return true
    } catch {
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
      systemPrompt: preferences.defaultSystemPrompt,
      options: conversation.options
    )
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

  func send(
    conversationID: ConversationID,
    text: String,
    attachments: [ChatAttachment] = []
  ) {
    guard generationTasks[conversationID] == nil else { return }

    saveDraft("", conversationID: conversationID)

    if var conversation = hydratedConversations[conversationID] {
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty || !attachments.isEmpty {
        let now = Date.now
        let optimistic = ChatMessage(
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
      action: .send(text, attachments)
    )
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
    action: GenerationAction
  ) {
    guard generationTasks[conversationID] == nil else { return }
    if activeConversationIDs.isEmpty {
      backgroundKeeper?.begin()
    }
    activeConversationIDs.insert(conversationID)
    activeToolCallsByConversation.removeValue(forKey: conversationID)
    generationTasks[conversationID] = Task { @MainActor [weak self] in
      guard let self else { return }
      var didReceiveInlineFailure = false
      defer {
        clearLiveMessages(for: conversationID)
        activeConversationIDs.remove(conversationID)
        if activeConversationIDs.isEmpty {
          backgroundKeeper?.end()
        }
        activeToolCallsByConversation.removeValue(forKey: conversationID)
        generationTasks.removeValue(forKey: conversationID)
      }
      do {
        let stream: AsyncThrowingStream<ChatRuntimeEvent, Error>
        switch action {
        case .send(let text, let attachments):
          stream = await runtime.send(
            conversationID: conversationID,
            userText: text,
            attachments: attachments
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
          if case .failed = event {
            didReceiveInlineFailure = true
          }
          await handle(event, conversationID: conversationID)
        }
      } catch is CancellationError {
        try? await reloadSnapshot()
      } catch {
        if !didReceiveInlineFailure {
          errorMessage = error.localizedDescription
        }
        try? await reloadSnapshot()
      }
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
    let validIDs = Set(conversations.map(\.id))
    for id in Array(hydratedConversations.keys) where !validIDs.contains(id) {
      hydratedConversations.removeValue(forKey: id)
    }
    for id in Array(hydratedConversations.keys) {
      if let refreshed = await conversationStore.cachedConversation(id: id) {
        hydratedConversations[id] = refreshed
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
