import BYOKchatProviderCore
import Foundation
import Observation
import os

@MainActor
func performMacConversationDeletion(
  deleteConversation: () async throws -> Void,
  removeMCPConfiguration: () async throws -> Void,
  removeProjectReference: () async throws -> Void
) async throws -> [String] {
  try await deleteConversation()

  var warnings: [String] = []
  do {
    try await removeMCPConfiguration()
  } catch {
    warnings.append("Tool configuration cleanup failed: \(error.localizedDescription)")
  }

  do {
    try await removeProjectReference()
  } catch {
    warnings.append("Project reference cleanup failed: \(error.localizedDescription)")
  }

  return warnings
}

@MainActor
@Observable
final class MacChatSessionModel {
  struct LiveMessage: Equatable, Sendable {
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

  private enum GenerationAction: Sendable {
    case send(String, [ChatAttachment])
    case edit(ChatMessageID, String)
    case regenerate(confirmingUncertainCompletion: Bool)

    var draftToRestoreIfTurnNeverStarts: String? {
      if case .send(let text, _) = self { return text }
      return nil
    }
  }

  private static let streamPresentationInterval: Duration = .milliseconds(50)
  private static let searchDebounce: Duration = .milliseconds(160)

  private(set) var conversationSummaries: [ChatConversation]
  private(set) var hydratedConversations: [ConversationID: ChatConversation] = [:]
  private(set) var livePresentations: [ChatMessageID: MacLiveMessagePresentation] = [:]
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
  private let restrictions: MacProResourceRestrictions
  private let streamAccumulator = MacStreamAccumulator()

  @ObservationIgnored private var conversationLoadTasks: [ConversationID: Task<ChatConversation, Error>] = [:]

  private var generationTasks: [ConversationID: Task<Void, Never>] = [:]
  private var draftTasks: [ConversationID: Task<Void, Never>] = [:]
  private var draftRevisions: [ConversationID: Int] = [:]
  private var draftValues: [ConversationID: String] = [:]
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
    initialSummaries: [ChatConversation],
    restrictions: MacProResourceRestrictions = MacPurchaseStore.restrictions
  ) {
    store = services.conversationStore
    runtime = services.chatRuntime
    projectWorkspace = services.projectWorkspace
    mcpWorkspace = services.mcpWorkspace
    self.providers = providers
    self.preferences = preferences
    self.restrictions = restrictions
    conversationSummaries = Self.sorted(initialSummaries)
    newChatTarget = Self.accessiblePreferredTarget(
      providers: providers,
      restrictions: restrictions
    )
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
    guard let id else { return }
    do {
      _ = try await hydrateConversation(id)
    } catch is CancellationError {
      // Deletion cancels in-flight hydration.
    } catch {
      MacAppAnalytics.reportError("conversation_load_failed", component: "chat_storage")
      errorMessage = error.localizedDescription
    }
  }

  private func hydrateConversation(_ id: ConversationID) async throws -> ChatConversation {
    if let cached = hydratedConversations[id] { return cached }
    if let pending = conversationLoadTasks[id] { return try await pending.value }
    let task = Task { @MainActor [self] in
      let conversation = try await store.conversation(id: id)
      try Task.checkCancellation()
      // A concurrent generation/target change may already have published newer data.
      if let current = hydratedConversations[id] { return current }
      hydratedConversations[id] = conversation
      if draftValues[id] == nil {
        draftValues[id] = conversation.draftText ?? ""
      }
      try await reloadSummaries()
      return conversation
    }
    conversationLoadTasks[id] = task
    defer { conversationLoadTasks.removeValue(forKey: id) }
    return try await task.value
  }

  func prepareConversation(_ id: ConversationID) async throws -> MacPreparedConversation {
    try Task.checkCancellation()
    let log = OSLog(subsystem: "pro.byok.BYOKchat", category: "ChatSwitch")
    let signpostID = OSSignpostID(log: log)
    os_signpost(.begin, log: log, name: "Prepare Conversation", signpostID: signpostID)
    defer { os_signpost(.end, log: log, name: "Prepare Conversation", signpostID: signpostID) }
    let conversation = try await hydrateConversation(id)
    try Task.checkCancellation()
    var answers: [String: MacPreparedAnswer] = [:]
    // Prepare the recent viewport first. Older rows prepare on demand instead
    // of making a long history a prerequisite for displaying the conversation.
    for message in conversation.messages.suffix(8)
    where message.role == .assistant && !message.content.isEmpty {
      try Task.checkCancellation()
      answers[message.content] = try await MacAnswerContentParseCache.shared.answer(for: message.content)
    }
    try Task.checkCancellation()
    guard summary(id) != nil else { throw ProviderError.conversationNotFound(id) }
    return MacPreparedConversation(
      id: id,
      conversation: hydratedConversations[id] ?? conversation,
      answers: answers
    )
  }

  func displayMessage(_ message: ChatMessage) -> ChatMessage {
    guard let presentation = livePresentations[message.id] else { return message }
    return presentation.resolve(message)
  }

  func messages(for conversationID: ConversationID?) -> [ChatMessage] {
    guard let conversation = conversation(conversationID) else { return [] }
    return conversation.messages
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

    // Draft editing is composer-local state. Do not rewrite the hydrated
    // conversation value on every keystroke: that invalidates transcript
    // readers even though no message content changed.
    draftValues[conversationID] = value

    draftTasks[conversationID]?.cancel()
    let revision = (draftRevisions[conversationID] ?? 0) &+ 1
    draftRevisions[conversationID] = revision
    draftTasks[conversationID] = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        try await Task.sleep(for: .milliseconds(250))
        try Task.checkCancellation()
        guard draftRevisions[conversationID] == revision else { return }
        try await store.setDraft(value, conversationID: conversationID)
        try Task.checkCancellation()
      } catch is CancellationError {
      } catch {
        if draftRevisions[conversationID] == revision {
          MacAppAnalytics.reportError("draft_save_failed", component: "chat_storage")
          errorMessage = error.localizedDescription
        }
      }
      if draftRevisions[conversationID] == revision {
        draftTasks.removeValue(forKey: conversationID)
      }
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
        MacAppAnalytics.reportError("conversation_search_failed", component: "chat_storage")
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
      MacAppAnalytics.reportError("conversation_rename_failed", component: "chat_storage")
      errorMessage = error.localizedDescription
      return false
    }
  }

  func deleteConversation(_ id: ConversationID) async -> Bool {
    await stop(id)
    errorMessage = nil

    let draftBeforeDelete = draft(for: id)
    cancelDraftPersistence(for: id)

    do {
      var warnings = try await performMacConversationDeletion(
        deleteConversation: { try await store.deleteConversation(id) },
        removeMCPConfiguration: {
          try await mcpWorkspace.removeChatConfiguration(conversationID: id)
        },
        removeProjectReference: { try await projectWorkspace.removeConversation(id) }
      )

      clearPresentationState(for: id)

      do {
        try await reloadSummaries()
      } catch {
        warnings.append("Conversation list refresh failed: \(error.localizedDescription)")
      }

      if !warnings.isEmpty {
        errorMessage = "Conversation deleted, but some related cleanup needs attention. "
          + warnings.joined(separator: " ")
      }
      return true
    } catch {
      setDraft(draftBeforeDelete, conversationID: id)
      try? await reloadSummaries()
      MacAppAnalytics.reportError("conversation_delete_failed", component: "chat_storage")
      errorMessage = error.localizedDescription
      return false
    }
  }

  func target(for conversationID: ConversationID?) -> MacChatTarget? {
    guard let conversationID else {
      return newChatTarget ?? accessiblePreferredTarget()
    }

    let conversation = hydratedConversations[conversationID] ?? summary(conversationID)
    guard let conversation else { return accessiblePreferredTarget() }
    let reasoning = providers.capabilities(accountID: conversation.accountID, modelID: conversation.modelID)
      .reasoning.normalize(conversation.options.reasoning)
    return MacChatTarget(
      accountID: conversation.accountID,
      modelID: conversation.modelID,
      reasoning: reasoning
    )
  }

  func applyTarget(_ target: MacChatTarget, conversationID: ConversationID?) async -> Bool {
    var target = target
    target.reasoning = providers.capabilities(accountID: target.accountID, modelID: target.modelID)
      .reasoning.normalize(target.reasoning)
    guard !isProviderRestricted(target.accountID) else {
      blockRestoredResource("provider connection", feature: .providerAccounts)
      return false
    }
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
      options.reasoning = target.reasoning

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
      if let queuedNewChatTarget, !isProviderRestricted(queuedNewChatTarget.accountID) {
        newChatTarget = queuedNewChatTarget
      } else {
        newChatTarget = accessiblePreferredTarget()
      }
      hasQueuedNewChat = false
      queuedNewChatProjectID = nil
      queuedNewChatDraft = nil
      queuedNewChatTarget = nil
    } else {
      newChatProjectID = nil
      newChatDraft = ""
      newChatTarget = accessiblePreferredTarget()
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
    if let conversationID, generationTasks[conversationID] != nil {
      errorMessage = "Wait for the current response to finish, or stop it before sending again."
      return nil
    }

    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty || !attachments.isEmpty else { return conversationID }

    var effectiveID = conversationID
    if let conversationID {
      await loadConversation(conversationID)
      guard hydratedConversations[conversationID] != nil else { return nil }
      guard await validateGenerationAccess(conversationID: conversationID) else { return nil }
    } else {
      guard let target = validatedNewChatTarget(),
        let account = providers.account(target.accountID), providers.isReady(account)
      else {
        errorMessage = MacProAccess.isCheckingEntitlement
          ? "Checking your BYOK Pro status before choosing an available connection. Try again in a moment."
          : "Set up a provider connection before starting a chat."
        newChatDraft = trimmed
        return nil
      }

      if let projectID = newChatProjectID {
        guard await validateNewChatProjectAccess(projectID) else {
          newChatDraft = trimmed
          return nil
        }
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
          do {
            try await projectWorkspace.assignConversation(conversation.id, to: projectID)
          } catch let assignmentError {
            try? await projectWorkspace.removeConversation(conversation.id)
            do {
              try await store.deleteConversation(conversation.id)
            } catch let rollbackError {
              try? await reloadSummaries()
              errorMessage = "Couldn't add the new chat to its project (\(assignmentError.localizedDescription)), and cleanup of the empty chat also failed: \(rollbackError.localizedDescription)"
              newChatDraft = trimmed
              return nil
            }
            throw assignmentError
          }
        }

        hydratedConversations[conversation.id] = conversation
        draftValues[conversation.id] = trimmed
        newChatDraft = ""
        newChatProjectID = nil
        effectiveID = conversation.id
        try await reloadSummaries()
      } catch {
        MacAppAnalytics.reportError("conversation_create_failed", component: "chat_storage")
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
    guard await validateGenerationAccess(conversationID: conversationID) else { return false }
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
    guard await validateGenerationAccess(conversationID: conversationID) else { return false }
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

    let runtime = self.runtime
    let accumulator = streamAccumulator
    generationTasks[conversationID] = Task.detached(priority: .userInitiated) { [weak self] in
      guard let self else { return }
      var didStartTurn = false

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

          switch event {
          case .textDelta(let messageID, let value):
            if await accumulator.appendText(value, to: messageID) {
              await self.scheduleStreamPresentation(messageID, conversationID: conversationID)
            }
          case .reasoningDelta(let messageID, let value):
            if await accumulator.appendReasoning(value, to: messageID) {
              await self.scheduleStreamPresentation(messageID, conversationID: conversationID)
            }
          case .usage(let messageID, let value):
            if await accumulator.setUsage(value, for: messageID) {
              await self.scheduleStreamPresentation(messageID, conversationID: conversationID)
            }
          default:
            await self.handle(event, conversationID: conversationID)
          }
        }
      } catch is CancellationError {
        await self.handleGenerationCancellation(
          conversationID: conversationID,
          action: action,
          didStartTurn: didStartTurn
        )
      } catch {
        await self.handleGenerationFailure(
          error,
          conversationID: conversationID,
          action: action,
          didStartTurn: didStartTurn
        )
      }

      await self.finishGeneration(conversationID)
    }
  }

  private func handleGenerationCancellation(
    conversationID: ConversationID,
    action: GenerationAction,
    didStartTurn: Bool
  ) async {
    activeToolCallsByConversation.removeValue(forKey: conversationID)
    if !didStartTurn, let draft = action.draftToRestoreIfTurnNeverStarts {
      setDraft(draft, conversationID: conversationID)
    }
    try? await reloadConversation(conversationID)
    try? await reloadSummaries()
    advanceStreamRevision(for: conversationID)
  }

  private func handleGenerationFailure(
    _ error: Error,
    conversationID: ConversationID,
    action: GenerationAction,
    didStartTurn: Bool
  ) async {
    activeToolCallsByConversation.removeValue(forKey: conversationID)
    if !didStartTurn, let draft = action.draftToRestoreIfTurnNeverStarts {
      setDraft(draft, conversationID: conversationID)
    }
    MacAppAnalytics.reportError("chat_generation_failed", component: "chat_runtime")
    errorMessage = error.localizedDescription
    try? await reloadConversation(conversationID)
    try? await reloadSummaries()
    advanceStreamRevision(for: conversationID)
  }

  private func finishGeneration(_ conversationID: ConversationID) {
    activeConversationIDs.remove(conversationID)
    generationTasks.removeValue(forKey: conversationID)
  }

  private func handle(_ event: ChatRuntimeEvent, conversationID: ConversationID) async {
    switch event {
    case .turnStarted(let turn):
      try? await reloadConversation(conversationID)
      await streamAccumulator.reset(turn.assistantMessage.id)
      livePresentations[turn.assistantMessage.id] = MacLiveMessagePresentation(
        messageID: turn.assistantMessage.id
      )
      try? await reloadSummaries()
      advanceStreamRevision(for: conversationID)

    case .textDelta, .reasoningDelta, .usage:
      // Raw deltas are consumed by the detached stream task and accumulator.
      break

    case .toolCallsStarted(_, let calls):
      activeToolCallsByConversation[conversationID] = calls
      advanceStreamRevision(for: conversationID)

    case .toolRound(let messageID, _):
      activeToolCallsByConversation.removeValue(forKey: conversationID)
      await flushStreamPresentation(messageID, conversationID: conversationID)
      livePresentations.removeValue(forKey: messageID)?.cancelPendingRenders()
      try? await reloadConversation(conversationID)
      try? await reloadSummaries()
      await streamAccumulator.reset(messageID)
      livePresentations[messageID] = MacLiveMessagePresentation(messageID: messageID)
      advanceStreamRevision(for: conversationID)

    case .completed(let message), .cancelled(let message), .failed(let message):
      activeToolCallsByConversation.removeValue(forKey: conversationID)
      await flushStreamPresentation(message.id, conversationID: conversationID)
      await streamAccumulator.remove(message.id)
      livePresentations.removeValue(forKey: message.id)?.cancelPendingRenders()
      if message.status == .failed {
        MacAppAnalytics.reportError("chat_generation_failed", component: "chat_runtime")
        errorMessage = message.errorDescription ?? "The response failed."
      }
      try? await reloadConversation(conversationID)
      try? await reloadSummaries()
      advanceStreamRevision(for: conversationID)
    }
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
      await presentStreamTarget(messageID, conversationID: conversationID)
    }
  }

  private func presentStreamTarget(
    _ messageID: ChatMessageID,
    conversationID: ConversationID
  ) async {
    guard let target = await streamAccumulator.takeSnapshot(for: messageID) else { return }
    let presentation: MacLiveMessagePresentation
    if let existing = livePresentations[messageID] {
      presentation = existing
    } else {
      let created = MacLiveMessagePresentation(messageID: messageID)
      livePresentations[messageID] = created
      presentation = created
    }
    guard presentation.apply(
      content: target.content,
      reasoning: target.reasoning,
      usage: target.usage
    ) else { return }
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
    await presentStreamTarget(messageID, conversationID: conversationID)
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
      !isProviderRestricted(current.accountID),
      let account = providers.account(current.accountID),
      providers.isReady(account),
      providers.models(for: current.accountID).contains(where: {
        $0.model.id == current.modelID && $0.isAvailable
      })
    {
      return current
    }
    let replacement = accessiblePreferredTarget()
    newChatTarget = replacement
    return replacement
  }

  private func accessiblePreferredTarget() -> MacChatTarget? {
    Self.accessiblePreferredTarget(providers: providers, restrictions: restrictions)
  }

  private static func accessiblePreferredTarget(
    providers: MacProviderModel,
    restrictions: MacProResourceRestrictions
  ) -> MacChatTarget? {
    let entitlement = MacProAccess.entitlementAccess
    let currentIDs = providers.accounts.map(\.id)
    let candidates = providers.accounts.filter { account in
      providers.isReady(account)
        && !restrictions.isProviderRestricted(
          account.id,
          currentIDs: currentIDs,
          entitlement: entitlement
        )
    }
    let account = providers.resolvedDefaultAccount.flatMap { resolved in
      candidates.first { $0.id == resolved.id }
    } ?? candidates.first

    guard let account, let modelID = providers.usableModelID(for: account.id) else { return nil }
    return MacChatTarget(
      accountID: account.id,
      modelID: modelID,
      reasoning: nil
    )
  }

  private func isProviderRestricted(_ id: ProviderAccountID) -> Bool {
    restrictions.isProviderRestricted(
      id,
      currentIDs: providers.accounts.map(\.id),
      entitlement: MacProAccess.entitlementAccess
    )
  }

  private func validateNewChatProjectAccess(_ projectID: ProjectID) async -> Bool {
    let projectSnapshot = await projectWorkspace.snapshot()
    let projectIDs = projectSnapshot.projects.map(\.id)
    if restrictions.isProjectRestricted(
      projectID,
      currentIDs: projectIDs,
      entitlement: MacProAccess.entitlementAccess
    ) {
      blockRestoredResource("project", feature: .projects)
      return false
    }

    guard let project = try? await projectWorkspace.project(id: projectID) else { return true }
    return await validateMCPAccess(configuration: project.mcpConfiguration)
  }

  private func validateGenerationAccess(conversationID: ConversationID) async -> Bool {
    let conversation: ChatConversation
    if let hydrated = hydratedConversations[conversationID] {
      conversation = hydrated
    } else if let loaded = try? await store.conversation(id: conversationID) {
      conversation = loaded
    } else {
      return false
    }

    if isProviderRestricted(conversation.accountID) {
      blockRestoredResource("provider connection", feature: .providerAccounts)
      return false
    }

    if let projectID = await projectWorkspace.projectID(for: conversationID) {
      let projectSnapshot = await projectWorkspace.snapshot()
      if restrictions.isProjectRestricted(
        projectID,
        currentIDs: projectSnapshot.projects.map(\.id),
        entitlement: MacProAccess.entitlementAccess
      ) {
        blockRestoredResource("project", feature: .projects)
        return false
      }
    }

    let configuration: MCPChatToolConfiguration?
    if let explicit = await mcpWorkspace.explicitChatConfiguration(for: conversationID) {
      configuration = explicit
    } else {
      configuration = await projectWorkspace.mcpConfiguration(for: conversationID)
    }
    return await validateMCPAccess(configuration: configuration)
  }

  private func validateMCPAccess(configuration: MCPChatToolConfiguration?) async -> Bool {
    guard let configuration else { return true }
    let snapshot = await mcpWorkspace.snapshot()
    let currentServerIDs = snapshot.servers.map(\.id)
    for serverID in configuration.enabledServerIDs {
      if restrictions.isMCPServerRestricted(
        serverID,
        currentIDs: currentServerIDs,
        entitlement: MacProAccess.entitlementAccess
      ) {
        blockRestoredResource("MCP server", feature: .mcpServers)
        return false
      }
    }
    return true
  }

  private func blockRestoredResource(_ resource: String, feature: MacProFeature) {
    errorMessage = MacProAccess.restoredResourceBlockedMessage(resource)
    MacProAccess.requestUpgrade(feature)
  }

  private func cancelDraftPersistence(for conversationID: ConversationID) {
    draftRevisions[conversationID, default: 0] &+= 1
    draftTasks.removeValue(forKey: conversationID)?.cancel()
  }

  private func clearPresentationState(for id: ConversationID) {
    conversationLoadTasks.removeValue(forKey: id)?.cancel()
    if let conversation = hydratedConversations[id] {
      let messageIDs = Set(conversation.messages.map(\.id))
      for messageID in messageIDs {
        streamPresentationTasks.removeValue(forKey: messageID)?.cancel()
        livePresentations.removeValue(forKey: messageID)?.cancelPendingRenders()
      }
      Task { [streamAccumulator] in
        await streamAccumulator.remove(messageIDs)
      }
    }

    hydratedConversations.removeValue(forKey: id)
    draftTasks.removeValue(forKey: id)?.cancel()
    draftRevisions.removeValue(forKey: id)
    draftValues.removeValue(forKey: id)
    activeToolCallsByConversation.removeValue(forKey: id)
    streamRevisions.removeValue(forKey: id)
  }

  private func reloadConversation(_ id: ConversationID) async throws {
    var conversation = try await store.conversation(id: id)
    if draftTasks[id] != nil, let pendingDraft = draftValues[id] {
      conversation.draftText = pendingDraft.isEmpty ? nil : pendingDraft
    } else {
      draftValues[id] = conversation.draftText ?? ""
    }
    hydratedConversations[id] = conversation
  }

  private func reloadSummaries() async throws {
    let summaries = Self.sorted(await store.conversationSummaries())
    guard summaries != conversationSummaries else { return }
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

struct MacPreparedConversation: Identifiable, Sendable {
  let id: ConversationID?
  let conversation: ChatConversation?
  let answers: [String: MacPreparedAnswer]

  static var newChat: Self { Self(id: nil, conversation: nil, answers: [:]) }
}

