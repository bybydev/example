import Foundation
import Testing

@testable import BYOKchatProviderCore

@Test func inputOnlyWindowDoesNotSubtractOutputReserveFromInputCapacity() throws {
  let prompt = String(repeating: "x", count: 2_800)
  let conversation = ChatConversation(
    providerID: "gemini",
    accountID: "account",
    modelID: "model",
    messages: [
      ChatMessage(role: .user, content: prompt, status: .complete)
    ]
  )

  let inputOnly = try ChatContextBuilder.build(
    conversation: conversation,
    contextWindow: 1_000,
    contextWindowKind: .inputOnly,
    reservedOutputTokens: 400,
    policy: windowKindNoSafetyMarginPolicy()
  )
  #expect(inputOnly.messages.first?.content == prompt)

  #expect(throws: ProviderError.self) {
    _ = try ChatContextBuilder.build(
      conversation: conversation,
      contextWindow: 1_000,
      contextWindowKind: .combined,
      reservedOutputTokens: 400,
      policy: windowKindNoSafetyMarginPolicy()
    )
  }
}

@Test func legacyGeminiModelWithoutWindowKindStillUsesInputOnlyBudgetAtRuntime() async throws {
  let providerWorkspace = ProviderWorkspaceStore(
    persistence: InMemoryProviderWorkspacePersistence()
  )
  try await providerWorkspace.load()
  let account = ProviderAccount(
    id: "account",
    providerID: "gemini",
    label: "Gemini",
    defaultModelID: "model"
  )
  try await providerWorkspace.upsertAccount(account)
  try await providerWorkspace.addManualModel(
    ProviderModel(
      providerID: "gemini",
      id: "model",
      displayName: "Legacy discovered Gemini",
      contextWindow: 1_000,
      contextWindowKind: nil,
      maxOutputTokens: 400
    ),
    for: account.id
  )

  let conversations = ConversationStore(
    persistence: InMemoryConversationWorkspacePersistence()
  )
  try await conversations.load()
  let conversation = try await conversations.createConversation(
    providerID: account.providerID,
    accountID: account.id,
    modelID: "model"
  )

  let provider = WindowKindRecordingRuntime(providerID: "gemini")
  let chat = ChatRuntime(
    providerRuntime: provider,
    providerWorkspace: providerWorkspace,
    conversations: conversations,
    partialPersistenceInterval: .zero
  )
  let prompt = String(repeating: "x", count: 3_000)

  for try await _ in await chat.send(
    conversationID: conversation.id,
    userText: prompt
  ) {}

  #expect(await provider.requestCount() == 1)
  #expect((await provider.lastRequest())?.messages.last?.content == prompt)
}

@Test func providerModelWindowKindRemainsBackwardDecodable() throws {
  let current = ProviderModel(
    providerID: "gemini",
    id: "model",
    displayName: "Model",
    contextWindow: 1_000,
    contextWindowKind: .inputOnly,
    maxOutputTokens: 400
  )
  let encoded = try JSONEncoder.providerEncoder.encode(current)
  var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
  object.removeValue(forKey: "contextWindowKind")
  let legacyData = try JSONSerialization.data(withJSONObject: object)

  let decoded = try JSONDecoder.provider.decode(ProviderModel.self, from: legacyData)
  #expect(decoded.contextWindowKind == nil)
  #expect(decoded.effectiveContextWindowKind == .inputOnly)
}

@Test func unknownProviderWithoutWindowKindDefaultsToCombinedBudgeting() {
  let model = ProviderModel(
    providerID: "custom-provider",
    id: "model",
    displayName: "Custom",
    contextWindow: 8_192,
    contextWindowKind: nil,
    maxOutputTokens: 2_048
  )

  #expect(model.effectiveContextWindowKind == .combined)
  #expect(BuiltInProviders.anthropic.seedModels.allSatisfy { $0.effectiveContextWindowKind == .inputOnly })
  #expect(BuiltInProviders.gemini.seedModels.allSatisfy { $0.effectiveContextWindowKind == .inputOnly })
  #expect(BuiltInProviders.deepSeek.seedModels.allSatisfy { $0.effectiveContextWindowKind == .combined })
}

private func windowKindNoSafetyMarginPolicy() -> ChatContextPolicy {
  ChatContextPolicy(
    safetyMarginRatio: 0,
    minimumSafetyMarginTokens: 0,
    maximumSafetyMarginTokens: 0
  )
}

private actor WindowKindRecordingRuntime: ProviderStreamingRuntime {
  private let providerID: ProviderID
  private var requests: [ProviderRequest] = []

  init(providerID: ProviderID) {
    self.providerID = providerID
  }

  func stream(
    request: ProviderRequest,
    accountID: ProviderAccountID
  ) async throws -> AsyncThrowingStream<ProviderStreamEvent, Error> {
    requests.append(request)
    let providerID = self.providerID
    return AsyncThrowingStream { continuation in
      continuation.yield(
        .completed(
          ProviderResponse(
            text: "ok",
            providerID: providerID,
            accountID: accountID,
            modelID: request.model,
            finishReason: "stop"
          )
        )
      )
      continuation.finish()
    }
  }

  func requestCount() -> Int { requests.count }
  func lastRequest() -> ProviderRequest? { requests.last }
}
