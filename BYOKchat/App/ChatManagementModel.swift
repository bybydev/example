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

  private(set) var conversations: [ChatConversation] = []
  private(set) var liveMessages: [ChatMessageID: LiveMessage] = [:]
  private(set) var activeConversationIDs: Set<ConversationID> = []
  private(set) var streamRevision = 0
  var isBusy = false
  var errorMessage: String?

  private let providerWorkspace: ProviderWorkspaceStore
  private let conversationStore: ConversationStore
  private let runtime: ChatRuntime
  private var generationTasks: [ConversationID: Task<Void, Never>] = [:]

  init(
    providerWorkspace: ProviderWorkspaceStore,
    conversations: ConversationStore,
    runtime: ChatRuntime
  ) {
    self.providerWorkspace = providerWorkspace
    self.conversationStore = conversations
    self.runtime = runtime
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

  func send(conversationID: ConversationID, text: String) {
    guard generationTasks[conversationID] == nil else { return }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }

    activeConversationIDs.insert(conversationID)
    generationTasks[conversationID] = Task {
      defer {
        activeConversationIDs.remove(conversationID)
        generationTasks.removeValue(forKey: conversationID)
      }
      do {
        for try await event in await runtime.send(
          conversationID: conversationID,
          userText: trimmed
        ) {
          await handle(event, conversationID: conversationID)
        }
      } catch is CancellationError {
        try? await reloadSnapshot()
      } catch {
        errorMessage = error.localizedDescription
        try? await reloadSnapshot()
      }
    }
  }

  func stop(_ conversationID: ConversationID) {
    generationTasks[conversationID]?.cancel()
    Task { await runtime.cancel(conversationID: conversationID) }
  }

  func isGenerating(_ conversationID: ConversationID) -> Bool {
    activeConversationIDs.contains(conversationID)
  }

  private func handle(_ event: ChatRuntimeEvent, conversationID: ConversationID) async {
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
  }

  private func defaultOptions(providerID: ProviderID) -> ProviderRequestOptions {
    guard providerID == BuiltInProviders.deepSeekID else { return .init() }
    return .init(reasoning: .init(enabled: true, effort: .high))
  }
}
