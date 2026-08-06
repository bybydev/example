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
    case send(String)
    case edit(ChatMessageID, String)
    case regenerate(confirmingUncertainCompletion: Bool)
  }

  private(set) var conversations: [ChatConversation] = []
  private(set) var liveMessages: [ChatMessageID: LiveMessage] = [:]
  private(set) var activeConversationIDs: Set<ConversationID> = []
  private(set) var searchResults: [ConversationSearchResult] = []
  private(set) var streamRevision = 0
  var isBusy = false
  var errorMessage: String?

  private let providerWorkspace: ProviderWorkspaceStore
  private let conversationStore: ConversationStore
  private let runtime: ChatRuntime
  private let preferences: AppPreferencesModel
  private var generationTasks: [ConversationID: Task<Void, Never>] = [:]
  private var draftTasks: [ConversationID: Task<Void, Never>] = [:]
  private var draftRevisions: [ConversationID: UInt] = [:]
  private var searchTask: Task<Void, Never>?
  private var searchRevision: UInt = 0

  init(
    providerWorkspace: ProviderWorkspaceStore,
    conversations: ConversationStore,
    runtime: ChatRuntime,
    preferences: AppPreferencesModel
  ) {
    self.providerWorkspace = providerWorkspace
    self.conversationStore = conversations
    self.runtime = runtime
    self.preferences = preferences
  }

  func load() async {
    do {
      try await conversationStore.load()
      try await reloadSnapshot()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func conversation(_ id: ConversationID) -> ChatConversation? {
    conversations.first { $0.id == id }
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

  var defaultSystemPrompt: String { preferences.defaultSystemPrompt }

  func saveDraft(_ text: String, conversationID: ConversationID) {
    if let index = conversations.firstIndex(where: { $0.id == conversationID }) {
      conversations[index].draftText = text.isEmpty ? nil : text
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
  func createConversation() async -> ConversationID? {
    do {
      let accounts = await providerWorkspace.allAccounts().filter(\.isEnabled)
      guard !accounts.isEmpty else {
        throw ProviderError.invalidRequest("Configure a provider account before creating a chat.")
      }
      let defaultID = await providerWorkspace.defaultAccountID()
      let account = accounts.first(where: { $0.id == defaultID }) ?? accounts[0]
      let models = await providerWorkspace.modelRecords(for: account.id)
      guard let modelID = account.defaultModelID ?? models.first?.model.id else {
        throw ProviderError.invalidModel
      }
      let conversation = try await conversationStore.createConversation(
        providerID: account.providerID,
        accountID: account.id,
        modelID: modelID,
        systemPrompt: preferences.defaultSystemPrompt,
        options: defaultOptions(providerID: account.providerID)
      )
      try await reloadSnapshot()
      return conversation.id
    } catch {
      errorMessage = error.localizedDescription
      return nil
    }
  }

  func deleteConversation(_ id: ConversationID) async {
    stop(id)
    draftTasks[id]?.cancel()
    draftTasks.removeValue(forKey: id)
    draftRevisions.removeValue(forKey: id)
    do {
      try await conversationStore.deleteConversation(id)
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

  func send(conversationID: ConversationID, text: String) {
    saveDraft("", conversationID: conversationID)
    startGeneration(conversationID: conversationID, action: .send(text))
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

  func stop(_ conversationID: ConversationID) {
    generationTasks[conversationID]?.cancel()
    Task { await runtime.cancel(conversationID: conversationID) }
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

  private func startGeneration(
    conversationID: ConversationID,
    action: GenerationAction
  ) {
    guard generationTasks[conversationID] == nil else { return }
    activeConversationIDs.insert(conversationID)
    generationTasks[conversationID] = Task { @MainActor [weak self] in
      guard let self else { return }
      defer {
        activeConversationIDs.remove(conversationID)
        generationTasks.removeValue(forKey: conversationID)
      }
      do {
        let stream: AsyncThrowingStream<ChatRuntimeEvent, Error>
        switch action {
        case .send(let text):
          stream = await runtime.send(conversationID: conversationID, userText: text)
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
          await handle(event)
        }
      } catch is CancellationError {
        try? await reloadSnapshot()
      } catch {
        errorMessage = error.localizedDescription
        try? await reloadSnapshot()
      }
    }
  }

  private func handle(_ event: ChatRuntimeEvent) async {
    switch event {
    case .turnStarted(let turn):
      liveMessages[turn.assistantMessage.id] = .init()
      try? await reloadSnapshot()
    case .textDelta(let messageID, let value):
      var live = liveMessages[messageID] ?? .init()
      live.content += value
      liveMessages[messageID] = live
      streamRevision += 1
    case .reasoningDelta(let messageID, let value):
      var live = liveMessages[messageID] ?? .init()
      live.reasoning += value
      liveMessages[messageID] = live
      streamRevision += 1
    case .usage(let messageID, let value):
      var live = liveMessages[messageID] ?? .init()
      live.usage = value
      liveMessages[messageID] = live
      streamRevision += 1
    case .completed(let message), .cancelled(let message), .failed(let message):
      liveMessages.removeValue(forKey: message.id)
      try? await reloadSnapshot()
    }
  }

  private func reloadSnapshot() async throws {
    conversations = await conversationStore.allConversations()
    let currentMessageIDs = Set(conversations.flatMap(\.messages).map(\.id))
    liveMessages = liveMessages.filter { currentMessageIDs.contains($0.key) }
  }

  private func defaultOptions(providerID: ProviderID) -> ProviderRequestOptions {
    guard providerID == BuiltInProviders.deepSeekID else { return .init() }
    return .init(reasoning: .init(enabled: true, effort: .high))
  }
}
