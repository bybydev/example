import BYOKchatProviderCore
import Foundation
import Observation

@MainActor
@Observable
final class MacChatSessionModel {
  struct LiveMessage: Equatable {
    var content = ""
    var reasoning = ""
    var usage: ProviderUsage?
  }

  struct SearchItem: Identifiable {
    let conversationID: ConversationID
    let title: String
    let snippet: String
    let role: ConversationSearchMatchRole
    let updatedAt: Date

    var id: ConversationID { conversationID }
  }

  private enum GenerationAction {
    case send(String, [ChatAttachment])
    case edit(ChatMessageID, String)
    case regenerate(confirmingUncertainCompletion: Bool)

    var draftToRestoreIfTurnNeverStarts: String? {
      if case .send(let text, _) = self { return text }
      return nil
    }
  }

  private static let streamPresentationInterval: Duration = .milliseconds(33)
  private static let searchDebounce: Duration = .milliseconds(160)

  private(set) var conversationSummaries: [ChatConversation]
  private(set) var hydratedConversations: [ConversationID: ChatConversation] = [:]
  private(set) var liveMessages: [ChatMessageID: LiveMessage] = [:]
  private(set) var activeConversationIDs: Set<ConversationID> = []
  private(set) var activeToolCallsByConversation: [ConversationID: [ChatToolCall]] = [:]
  private(set) var streamRevisions: [ConversationID: Int] = [:]
  private(set) var searchItems: [SearchItem] = []
  private(set) var isSearching = false
  private(set) var newChatTarget: MacChatTarget?
  private(set) var newChatProjectID: ProjectID?
  var errorMessage: String?
  var onSummariesChanged: (([ChatConversation]) -> Void)?

  private let store: ConversationStore
  private let runtime: ChatRuntime
  private let providers: MacProviderModel
  private let preferences: MacPreferencesModel
  private let projectWorkspace: ProjectWorkspaceStore
  private let mcpWorkspace: MCPWorkspaceStore

  private var generationTasks: [ConversationID: Task<Void, Never>] = [:]
  private var draftTasks: [ConversationID: Task<Void, Never>] = [:]
  private var draftValues: [ConversationID: String] = [:]
  private var streamTargets: [ChatMessageID: LiveMessage] = [:]
  private var streamPresentationTasks: [ChatMessageID: Task<Void, Never>] = [:]
  private var searchTask: Task<Void, Never>?
  private var searchQuery = ""
  private var newChatDraft = ""
  private var hasQueuedNewChat = false
  private var queuedNewChatProjectID: ProjectID?
  private var queuedNewChatDraft: String?
  private var queuedNewChatTarget: MacChatTarget?

  init(
    services: BYOKCoreServices,
    providers: MacProviderModel,
    preferences: MacPreferencesModel,
    initialSummaries: [ChatConversation]
  ) {
    store = services.conversationStore
    runtime = services.chatRuntime
    projectWorkspace = services.projectWorkspace
    mcpWorkspace = services.mcpWorkspace
    self.providers = providers
    self.preferences = preferences
    conversationSummaries = Self.sorted(initialSummaries)
    newChatTarget = providers.preferredTarget()
  }

  var sendsOnReturn: Bool { preferences.sendOnReturn }

  func summary(_ id: ConversationID?) -> ChatConversation? {
    guard let id else { return nil }
    return conversationSummaries.first { $0.id == id }
  }

  func conversation(_ id: ConversationID?) -> ChatConversation? {
    guard let id else { return nil }
    return hydratedConversations[id]
  }

  func loadConversation(_ id: ConversationID?) async {
    guard let id, hydratedConversations[id] == nil else { return }
    do {
      let conversation = try await store.conversation(id: id)
      hydratedConversations[id] = conversation
      if draftValues[id] == nil {
        draftValues[id] = conversation.draftText ?? ""
      }
      try await reloadSummaries()
    } catch {
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

  func messages(for conversationID: ConversationID?) -> [ChatMessage] {
    guard let conversation = conversation(conversationID) else { return [] }
    return conversation.messages.map(displayMessage)
  }

  func streamRevision(for conversationID: ConversationID?) -> Int {
    guard let conversationID else { return 0 }
    return streamRevisions[conversationID, default: 0]
  }

  func activeToolCalls(for conversationID: ConversationID?) -> [ChatToolCall] {
    guard let conversationID else { return [] }
    return activeToolCallsByConversation[conversationID] ?? []
  }

  func draft(for conversationID: ConversationID?) -> String {
    guard let conversationID else { return newChatDraft }
    if let value = draftValues[conversationID] { return value }
    if let value = hydratedConversations[conversationID]?.draftText { return value }
    return summary(conversationID)?.draftText ?? ""
  }

  func setDraft(_ value: String, conversationID: ConversationID?) {
    guard let conversationID else {
      newChatDraft = value
      return
    }

    draftValues[conversationID] = value
    if var conversation = hydratedConversations[conversationID] {
      conversation.draftText = value.isEmpty ? nil : value
      hydratedConversations[conversationID] = conversation
    }

    draftTasks[conversationID]?.cancel()
    draftTasks[conversationID] = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        try await Task.sleep(for: .milliseconds(250))
        try Task.checkCancellation()
        try await store.setDraft(value, conversationID: conversationID)
      } catch is CancellationError {
      } catch {
        errorMessage = error.localizedDescription
      }
      draftTasks.removeValue(forKey: conversationID)
    }
  }

  func updateSearch(_ value: String) {
    searchQuery = value
    searchTask?.cancel()

    let query = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else {
      searchItems = []
      isSearching = false
      return
    }

    isSearching = true
    searchTask = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        try await Task.sleep(for: Self.searchDebounce)
        try Task.checkCancellation()
        let results = await store.search(query, limit: 120)
        try Task.checkCancellation()
        applySearchResults(results)
        isSearching = false
      } catch is CancellationError {
      } catch {
        isSearching = false
        errorMessage = error.localizedDescription
      }
    }
  }

  func renameConversation(_ id: ConversationID, title: String) async -> Bool {
    do {
      try await store.renameConversation(id, title: title)
      if hydratedConversations[id] != nil {
        try await reloadConversation(id)
      }
      try await reloadSummaries()
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  func deleteConversation(_ id: ConversationID) async -> Bool {
    await stop(id)
    draftTasks[id]?.cancel()
    draftTasks.removeValue(forKey: id)

    if let conversation = hydratedConversations[id] {
      let messageIDs = Set(conversation.messages.map(\.id))
      for messageID in messageIDs {
        streamPresentationTasks.removeValue(forKey: messageID)?.cancel()
        streamTargets.removeValue(forKey: messageID)
        liveMessages.removeValue(forKey: messageID)
      }
    }

    hydratedConversations.removeValue(forKey: id)
    draftValues.removeValue(forKey: id)
    activeToolCallsByConversation.removeValue(forKey: id)
    streamRevisions.removeValue(forKey: id)

    do {
      try await store.deleteConversation(id)
      try await mcpWorkspace.removeChatConfiguration(conversationID: id)
      try await projectWorkspace.removeConversation(id)
      try await reloadSummaries()
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  func target(for conversationID: ConversationID?) -> MacChatTarget? {
    guard let conversationID else {
      return newChatTarget ?? providers.preferredTarget()
    }

    let conversation = hydratedConversations[conversationID] ?? summary(conversationID)
    guard let conversation else { return providers.preferredTarget() }
    let reasoning: ReasoningOptions?
    if hydratedConversations[conversationID] != nil {
      reasoning = conversation.options.reasoning
    } else if providers.supportsReasoning(accountID: conversation.accountID, modelID: conversation.modelID) {
      reasoning = providers.reasoningDefault(for: conversation.accountID)
    } else {
      reasoning = nil
    }
    return MacChatTarget(
      accountID: conversation.accountID,
      modelID: conversation.modelID,
      reasoning: reasoning
    )
  }

  func applyTarget(_ target: MacChatTarget, conversationID: ConversationID?) async -> Bool {
    guard let account = providers.account(target.accountID), providers.isReady(account) else {
      errorMessage = "Choose a ready provider connection."
      return false
    }
    guard providers.models(for: target.accountID).contains(where: {
      $0.model.id == target.modelID && $0.isAvailable
    }) else {
      errorMessage = "Choose an available model."
      return false
    }

    guard let conversationID else {
      newChatTarget = target
      return true
    }

    await loadConversation(conversationID)
    guard var conversation = hydratedConversations[conversationID] else { return false }

    do {
      var options = conversation.options
      if account.kind != .openRouter {
        options.openRouterRouting = nil
      }
      options.reasoning = providers.supportsReasoning(
        accountID: target.accountID,
        modelID: target.modelID
      ) ? target.reasoning : nil

      try await store.updateTarget(
        conversationID,
        providerID: account.providerID,
        accountID: account.id,
        modelID: target.modelID,
        systemPrompt: conversation.systemPrompt,
        options: options
      )

      conversation.providerID = account.providerID
      conversation.accountID = account.id
      conversation.modelID = target.modelID
      conversation.options = options
      conversation.updatedAt = .now
      hydratedConversations[conversationID] = conversation
      try await reloadSummaries()
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  func queueNewChat(
    projectID: ProjectID?,
    initialDraft: String?,
    target: MacChatTarget? = nil
  ) {
    hasQueuedNewChat = true
    queuedNewChatProjectID = projectID
    queuedNewChatDraft = initialDraft
    queuedNewChatTarget = target
  }

  func resetNewChat() {
    if hasQueuedNewChat {
      newChatProjectID = queuedNewChatProjectID
      newChatDraft = queuedNewChatDraft ?? ""
      newChatTarget = queuedNewChatTarget ?? providers.preferredTarget()
      hasQueuedNewChat = false
      queuedNewChatProjectID = nil
      queuedNewChatDraft = nil
      queuedNewChatTarget = nil
    } else {
      newChatProjectID = nil
      newChatDraft = ""
      newChatTarget = providers.preferredTarget()
    }
  }

  func refreshNewChatTargetAfterProviderChanges() {
    _ = validatedNewChatTarget()
  }

  func attachmentThumbnail(_ id: String, maxPixelSize: CGFloat) async -> Data? {
    await store.attachmentThumbnail(id, maxPixelSize: maxPixelSize)
  }

  func attachmentData(_ id: String) async -> Data? {
    await store.attachmentData(id)
  }

  @discardableResult
  func send(
    conversationID: ConversationID?,
    text: String,
    attachments: [ChatAttachment] = []
  ) async -> ConversationID? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty || !attachments.isEmpty else { return conversationID }

    var effectiveID = conversationID
    if let conversationID {
      await loadConversation(conversationID)
      guard hydratedConversations[conversationID] != nil else { return nil }
    } else {
      guard let target = validatedNewChatTarget(),
        let account = providers.account(target.accountID),
        providers.isReady(account)
      else {
        errorMessage = "Set up a provider connection before starting a chat."
        newChatDraft = trimmed
        return nil
      }

      do {
        let project: ChatProject?
        if let projectID = newChatProjectID {
          project = try? await projectWorkspace.project(id: projectID)
        } else {
          project = nil
        }
        let projectInstructions = project?.instructions.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let defaultPrompt = preferences.defaultSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let systemPrompt = projectInstructions.isEmpty ? defaultPrompt : projectInstructions

        let conversation = try await store.createConversation(
          providerID: account.providerID,
          accountID: account.id,
          modelID: target.modelID,
          systemPrompt: systemPrompt,
          options: ProviderRequestOptions(reasoning: target.reasoning)
        )
        if let projectID = newChatProjectID {
          try await projectWorkspace.assignConversation(conversation.id, to: projectID)
        }
        hydratedConversations[conversation.id] = conversation
        draftValues[conversation.id] = trimmed
        newChatDraft = ""
        newChatProjectID = nil
        effectiveID = conversation.id
        try await reloadSummaries()
      } catch {
        errorMessage = error.localizedDescription
        newChatDraft = trimmed
        return nil
      }
    }

    guard let effectiveID else { return nil }
    setDraft("", conversationID: effectiveID)
    startGeneration(conversationID: effectiveID, action: .send(trimmed, attachments))
    return effectiveID
  }

  func editAndResend(
    conversationID: ConversationID,
    messageID: ChatMessageID,
    text: String
  ) async -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, generationTasks[conversationID] == nil else { return false }
    await loadConversation(conversationID)
    guard let conversation = hydratedConversations[conversationID],
      conversation.messages.contains(where: { $0.id == messageID && $0.role == .user })
    else { return false }
    startGeneration(conversationID: conversationID, action: .edit(messageID, trimmed))
    return true
  }

  func regenerate(
    conversationID: ConversationID,
    confirmingUncertainCompletion: Bool = false
  ) async -> Bool {
    guard generationTasks[conversationID] == nil else { return false }
    await loadConversation(conversationID)
    guard hydratedConversations[conversationID] != nil else { return false }
    startGeneration(
      conversationID: conversationID,
      action: .regenerate(confirmingUncertainCompletion: confirmingUncertainCompletion)
    )
    return true
  }

  func isLatestAssistant(_ messageID: ChatMessageID, conversationID: ConversationID) -> Bool {
    guard let conversation = hydratedConversations[conversationID] else { return false }
    return conversation.messages.last(where: { $0.role == .assistant })?.id == messageID
  }

  func latestAssistantRequiresRegenerationConfirmation(_ conversationID: ConversationID) -> Bool {
    guard
      let conversation = hydratedConversations[conversationID],
      let userIndex = conversation.messages.lastIndex(where: { $0.role == .user })
    else { return false }
    return conversation.messages[(userIndex + 1)..<conversation.messages.endIndex]
      .contains { $0.requiresRegenerationConfirmation }
  }

  func stop(_ conversationID: ConversationID?) async {
    guard let conversationID, let consumerTask = generationTasks[conversationID] else { return }
    await runtime.cancel(conversationID: conversationID)
    consumerTask.cancel()
    await consumerTask.value
    activeToolCallsByConversation.removeValue(forKey: conversationID)
    try? await reloadConversation(conversationID)
    try? await reloadSummaries()
    advanceStreamRevision(for: conversationID)
  }

  func isGenerating(_ conversationID: ConversationID?) -> Bool {
    guard let conversationID else { return false }
    return activeConversationIDs.contains(conversationID)
  }

  private func startGeneration(conversationID: ConversationID, action: GenerationAction) {
    guard generationTasks[conversationID] == nil else { return }
    activeConversationIDs.insert(conversationID)
    activeToolCallsByConversation.removeValue(forKey: conversationID)

    generationTasks[conversationID] = Task { @MainActor [weak self] in
      guard let self else { return }
      var didStartTurn = false
      defer {
        activeConversationIDs.remove(conversationID)
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
          if case .turnStarted = event { didStartTurn = true }
          await handle(event, conversationID: conversationID)
        }
      } catch is CancellationError {
        activeToolCallsByConversation.removeValue(forKey: conversationID)
        if !didStartTurn, let draft = action.draftToRestoreIfTurnNeverStarts {
          setDraft(draft, conversationID: conversationID)
        }
        try? await reloadConversation(conversationID)
        try? await reloadSummaries()
        advanceStreamRevision(for: conversationID)
      } catch {
        activeToolCallsByConversation.removeValue(forKey: conversationID)
        if !didStartTurn, let draft = action.draftToRestoreIfTurnNeverStarts {
          setDraft(draft, conversationID: conversationID)
        }
        errorMessage = error.localizedDescription
        try? await reloadConversation(conversationID)
        try? await reloadSummaries()
        advanceStreamRevision(for: conversationID)
      }
    }
  }

  private func handle(_ event: ChatRuntimeEvent, conversationID: ConversationID) async {
    switch event {
    case .turnStarted(let turn):
      try? await reloadConversation(conversationID)
      let live = LiveMessage()
      streamTargets[turn.assistantMessage.id] = live
      liveMessages[turn.assistantMessage.id] = live
      try? await reloadSummaries()
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
      activeToolCallsByConversation.removeValue(forKey: conversationID)
      await flushStreamPresentation(messageID, conversationID: conversationID)
      try? await reloadConversation(conversationID)
      try? await reloadSummaries()
      let live = LiveMessage()
      streamTargets[messageID] = live
      liveMessages[messageID] = live
      advanceStreamRevision(for: conversationID)

    case .completed(let message), .cancelled(let message), .failed(let message):
      activeToolCallsByConversation.removeValue(forKey: conversationID)
      await flushStreamPresentation(message.id, conversationID: conversationID)
      streamTargets.removeValue(forKey: message.id)
      liveMessages.removeValue(forKey: message.id)
      if message.status == .failed {
        errorMessage = message.errorDescription ?? "The response failed."
      }
      try? await reloadConversation(conversationID)
      try? await reloadSummaries()
      advanceStreamRevision(for: conversationID)
    }
  }

  private func updateStreamTarget(
    _ messageID: ChatMessageID,
    conversationID: ConversationID,
    update: (inout LiveMessage) -> Void
  ) {
    var target = streamTargets[messageID] ?? liveMessages[messageID] ?? LiveMessage()
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
      defer { streamPresentationTasks.removeValue(forKey: messageID) }
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

  private func advanceStreamRevision(for conversationID: ConversationID) {
    streamRevisions[conversationID, default: 0] &+= 1
  }

  private func applySearchResults(_ results: [ConversationSearchResult]) {
    var seen: Set<ConversationID> = []
    searchItems = results.compactMap { result in
      guard seen.insert(result.conversationID).inserted else { return nil }
      return SearchItem(
        conversationID: result.conversationID,
        title: result.title,
        snippet: result.snippet,
        role: result.role,
        updatedAt: result.updatedAt
      )
    }
  }

  private func validatedNewChatTarget() -> MacChatTarget? {
    if let current = newChatTarget,
      let account = providers.account(current.accountID),
      providers.isReady(account),
      providers.models(for: current.accountID).contains(where: {
        $0.model.id == current.modelID && $0.isAvailable
      })
    {
      return current
    }
    let replacement = providers.preferredTarget()
    newChatTarget = replacement
    return replacement
  }

  private func reloadConversation(_ id: ConversationID) async throws {
    hydratedConversations[id] = try await store.conversation(id: id)
    draftValues[id] = hydratedConversations[id]?.draftText ?? ""
  }

  private func reloadSummaries() async throws {
    let summaries = Self.sorted(await store.conversationSummaries())
    conversationSummaries = summaries
    onSummariesChanged?(summaries)
    if !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      updateSearch(searchQuery)
    }
  }

  private static func sorted(_ values: [ChatConversation]) -> [ChatConversation] {
    values.sorted { lhs, rhs in
      if lhs.updatedAt == rhs.updatedAt { return lhs.id.rawValue > rhs.id.rawValue }
      return lhs.updatedAt > rhs.updatedAt
    }
  }
}
