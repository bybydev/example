import Foundation
import Testing

@testable import BYOKchatProviderCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

private enum ReviewTestFailure: Error {
  case injected
}

private actor RetryLoadProviderPersistence: ProviderWorkspacePersistence {
  private var data: Data?
  private var failuresRemaining: Int

  init(data: Data?, failuresRemaining: Int = 1) {
    self.data = data
    self.failuresRemaining = failuresRemaining
  }

  func loadData() throws -> Data? {
    if failuresRemaining > 0 {
      failuresRemaining -= 1
      throw ReviewTestFailure.injected
    }
    return data
  }

  func saveData(_ data: Data) {
    self.data = data
  }
}

private actor FailingSaveProviderPersistence: ProviderWorkspacePersistence {
  private var data: Data?

  init(data: Data?) {
    self.data = data
  }

  func loadData() -> Data? { data }

  func saveData(_ data: Data) throws {
    throw ReviewTestFailure.injected
  }
}

private actor SelectiveCredentialVault: CredentialVault {
  private var values: [String: String] = [:]
  private let failedRemovalIDs: Set<ProviderAccountID>

  init(failedRemovalIDs: Set<ProviderAccountID> = []) {
    self.failedRemovalIDs = failedRemovalIDs
  }

  func secret(accountID: ProviderAccountID, field: String) -> String? {
    values[key(accountID, field)]
  }

  func setSecret(_ value: String?, accountID: ProviderAccountID, field: String) {
    let storageKey = key(accountID, field)
    if let value {
      values[storageKey] = value
    } else {
      values.removeValue(forKey: storageKey)
    }
  }

  func removeAll(accountID: ProviderAccountID) throws {
    if failedRemovalIDs.contains(accountID) {
      throw ReviewTestFailure.injected
    }
    let prefix = "\(accountID.rawValue):"
    values = values.filter { !$0.key.hasPrefix(prefix) }
  }

  private func key(_ accountID: ProviderAccountID, _ field: String) -> String {
    "\(accountID.rawValue):\(field)"
  }
}

private actor EOFStreamTransport: ProviderHTTPTransport {
  let chunks: [Data]

  init(chunks: [Data]) {
    self.chunks = chunks
  }

  func data(for request: URLRequest) throws -> ProviderHTTPResponse {
    ProviderHTTPResponse(statusCode: 200, headers: [:], data: Data())
  }

  func stream(for request: URLRequest) -> ProviderHTTPByteStream {
    let values = chunks
    return ProviderHTTPByteStream(
      statusCode: 200,
      headers: [:],
      chunks: AsyncThrowingStream { continuation in
        for chunk in values { continuation.yield(chunk) }
        continuation.finish()
      }
    )
  }
}

private actor CountingProviderRuntime: ProviderStreamingRuntime {
  private var count = 0

  func stream(
    request: ProviderRequest,
    accountID: ProviderAccountID
  ) -> AsyncThrowingStream<ProviderStreamEvent, Error> {
    count += 1
    return AsyncThrowingStream { continuation in
      continuation.yield(
        .completed(
          ProviderResponse(
            text: "Unexpected",
            providerID: "deepseek",
            accountID: accountID,
            modelID: request.model
          )
        )
      )
      continuation.finish()
    }
  }

  func requestCount() -> Int { count }
}

@Test func publicFCPrefixHostsCannotUseCleartextLocalHTTP() throws {
  #expect(!ProviderHTTP.isPrivateNetworkHost("fcexample.com"))
  #expect(!ProviderHTTP.isPrivateNetworkHost("fdexample.com"))
  #expect(ProviderHTTP.isPrivateNetworkHost("fd00::1"))
  #expect(ProviderHTTP.isPrivateNetworkHost("fe80::1"))
  #expect(ProviderHTTP.isPrivateNetworkHost("192.168.1.20"))
  #expect(ProviderHTTP.isPrivateNetworkHost("localhost"))

  let publicURL = try #require(URL(string: "http://fcexample.com/v1"))
  #expect(throws: ProviderError.self) {
    try ProviderHTTP.validateBaseURL(publicURL, allowsLocalHTTP: true)
  }
}

@Test func finalSSEJSONEventAtEOFIsProcessed() async throws {
  let event =
    #"data: {"id":"eof","model":"openrouter/free","choices":[{"delta":{"content":"Final"},"finish_reason":"stop"}],"usage":{"prompt_tokens":2,"completion_tokens":1}}"#
  let transport = EOFStreamTransport(chunks: [Data(event.utf8)])
  let adapter = OpenAICompatibleAdapter(
    definition: BuiltInProviders.openRouter,
    transport: transport
  )
  let account = ResolvedProviderAccount(
    kind: ProviderKind(providerID: BuiltInProviders.openRouterID),
    id: "account",
    providerID: BuiltInProviders.openRouterID,
    label: "OpenRouter",
    apiKey: "secret"
  )

  var events: [ProviderStreamEvent] = []
  for try await value in adapter.stream(
    request: ProviderRequest(
      model: "openrouter/free",
      messages: [.init(role: .user, content: "Hello")]
    ),
    account: account
  ) {
    events.append(value)
  }

  #expect(events.contains(.textDelta("Final")))
  guard case .completed(let response) = events.last else {
    Issue.record("Missing completion event")
    return
  }
  #expect(response.text == "Final")
  #expect(response.finishReason == "stop")
  #expect(response.usage?.inputTokens == 2)
}

@Test func duplicateProviderAccountImportReturnsConflict() async throws {
  let workspace = ProviderWorkspaceStore(persistence: InMemoryProviderWorkspacePersistence())
  try await workspace.load()
  let duplicateID: ProviderAccountID = "duplicate"
  let data = try JSONEncoder.providerEncoder.encode(
    ProviderWorkspaceState(accounts: [
      ProviderAccount(kind: ProviderKind(providerID: "deepseek"), id: duplicateID, providerID: "deepseek", label: "First"),
      ProviderAccount(kind: ProviderKind(providerID: "deepseek"), id: duplicateID, providerID: "deepseek", label: "Second"),
    ])
  )

  await #expect(throws: ProviderError.self) {
    try await workspace.importConfiguration(data, strategy: .replaceExisting)
  }
  #expect(await workspace.allAccounts().isEmpty)
}

@Test func duplicateConversationMessageImportReturnsConflict() async throws {
  let store = ConversationStore(persistence: InMemoryConversationWorkspacePersistence())
  try await store.load()
  let duplicateMessageID: ChatMessageID = "duplicate-message"
  let first = ChatConversation(
    id: "first",
    providerID: "deepseek",
    accountID: "account",
    modelID: "model",
    messages: [
      ChatMessage(id: duplicateMessageID, role: .user, content: "First", status: .complete)
    ]
  )
  let second = ChatConversation(
    id: "second",
    providerID: "deepseek",
    accountID: "account",
    modelID: "model",
    messages: [
      ChatMessage(id: duplicateMessageID, role: .user, content: "Second", status: .complete)
    ]
  )
  let data = try JSONEncoder.providerEncoder.encode(
    ConversationWorkspaceState(conversations: [first, second])
  )

  await #expect(throws: ProviderError.self) {
    try await store.importWorkspace(data, strategy: .replaceExisting)
  }
  #expect(await store.allConversations().isEmpty)
}

@Test func providerWorkspaceLoadCanRetryAfterTransientFailure() async throws {
  let account = ProviderAccount(kind: ProviderKind(providerID: "deepseek"), id: "account", providerID: "deepseek", label: "DeepSeek")
  let data = try JSONEncoder.providerEncoder.encode(ProviderWorkspaceState(accounts: [account]))
  let persistence = RetryLoadProviderPersistence(data: data)
  let workspace = ProviderWorkspaceStore(persistence: persistence)

  await #expect(throws: ReviewTestFailure.self) {
    try await workspace.load()
  }
  try await workspace.load()

  #expect(await workspace.allAccounts().map(\.id) == [account.id])
}

@Test func failedWorkspaceDeleteKeepsCredentialAndAccount() async throws {
  let account = ProviderAccount(kind: ProviderKind(providerID: "deepseek"), id: "account", providerID: "deepseek", label: "DeepSeek")
  let data = try JSONEncoder.providerEncoder.encode(ProviderWorkspaceState(accounts: [account]))
  let workspace = ProviderWorkspaceStore(
    persistence: FailingSaveProviderPersistence(data: data)
  )
  try await workspace.load()
  let vault = SelectiveCredentialVault()
  await vault.setSecret(
    "secret",
    accountID: account.id,
    field: ProviderAccountManager.apiKeyField
  )
  let manager = ProviderAccountManager(
    registry: try ProviderRegistry.builtIn(),
    workspace: workspace,
    vault: vault
  )

  await #expect(throws: ReviewTestFailure.self) {
    _ = try await manager.deleteAccount(account.id)
  }

  let storedAccount = try await workspace.account(id: account.id)
  let storedSecret = await vault.secret(
    accountID: account.id,
    field: ProviderAccountManager.apiKeyField
  )
  #expect(storedAccount.id == account.id)
  #expect(storedAccount.label == account.label)
  #expect(storedSecret == "secret")
}

@Test func credentialCleanupAttemptsEveryAccountAndReportsFailures() async throws {
  let first: ProviderAccountID = "first"
  let second: ProviderAccountID = "second"
  let vault = SelectiveCredentialVault(failedRemovalIDs: [second])
  await vault.setSecret("one", accountID: first, field: ProviderAccountManager.apiKeyField)
  await vault.setSecret("two", accountID: second, field: ProviderAccountManager.apiKeyField)
  let workspace = ProviderWorkspaceStore(persistence: InMemoryProviderWorkspacePersistence())
  try await workspace.load()
  let manager = ProviderAccountManager(
    registry: try ProviderRegistry.builtIn(),
    workspace: workspace,
    vault: vault
  )

  let failures = await manager.removeCredentialsBestEffort(accountIDs: [first, second])
  let firstSecret = await vault.secret(
    accountID: first,
    field: ProviderAccountManager.apiKeyField
  )
  let secondSecret = await vault.secret(
    accountID: second,
    field: ProviderAccountManager.apiKeyField
  )

  #expect(failures == [second])
  #expect(firstSecret == nil)
  #expect(secondSecret == "two")
}

@Test func providerReplacementRejectsOrphanedConversations() async throws {
  let providerWorkspace = ProviderWorkspaceStore(
    persistence: InMemoryProviderWorkspacePersistence()
  )
  try await providerWorkspace.load()
  let oldAccount = ProviderAccount(kind: ProviderKind(providerID: "deepseek"), id: "old", providerID: "deepseek", label: "Old")
  try await providerWorkspace.upsertAccount(oldAccount)

  let conversationStore = ConversationStore(
    persistence: InMemoryConversationWorkspacePersistence()
  )
  try await conversationStore.load()
  _ = try await conversationStore.createConversation(
    providerID: oldAccount.providerID,
    accountID: oldAccount.id,
    modelID: "model"
  )

  let vault = SelectiveCredentialVault()
  let manager = ProviderAccountManager(
    registry: try ProviderRegistry.builtIn(),
    workspace: providerWorkspace,
    vault: vault
  )
  let service = DataPortabilityService(
    providers: providerWorkspace,
    conversations: conversationStore,
    accounts: manager
  )
  let replacement = ProviderWorkspaceState(accounts: [
    ProviderAccount(kind: ProviderKind(providerID: "deepseek"), id: "new", providerID: "deepseek", label: "New")
  ])
  let data = try JSONEncoder.providerEncoder.encode(replacement)

  await #expect(throws: ProviderError.self) {
    _ = try await service.importProviderConfiguration(data, strategy: .replaceExisting)
  }

  let storedAccount = try await providerWorkspace.account(id: oldAccount.id)
  #expect(storedAccount.id == oldAccount.id)
  #expect(storedAccount.label == oldAccount.label)
}

@Test func providerReplacementCommitsBeforeCredentialCleanup() async throws {
  let providerWorkspace = ProviderWorkspaceStore(
    persistence: InMemoryProviderWorkspacePersistence()
  )
  try await providerWorkspace.load()
  let oldAccount = ProviderAccount(kind: ProviderKind(providerID: "deepseek"), id: "old", providerID: "deepseek", label: "Old")
  try await providerWorkspace.upsertAccount(oldAccount)

  let conversationStore = ConversationStore(
    persistence: InMemoryConversationWorkspacePersistence()
  )
  try await conversationStore.load()
  let vault = SelectiveCredentialVault(failedRemovalIDs: [oldAccount.id])
  await vault.setSecret(
    "secret",
    accountID: oldAccount.id,
    field: ProviderAccountManager.apiKeyField
  )
  let manager = ProviderAccountManager(
    registry: try ProviderRegistry.builtIn(),
    workspace: providerWorkspace,
    vault: vault
  )
  let service = DataPortabilityService(
    providers: providerWorkspace,
    conversations: conversationStore,
    accounts: manager
  )
  let newAccount = ProviderAccount(kind: ProviderKind(providerID: "deepseek"), id: "new", providerID: "deepseek", label: "New")
  let data = try JSONEncoder.providerEncoder.encode(
    ProviderWorkspaceState(accounts: [newAccount])
  )

  let failures = try await service.importProviderConfiguration(
    data,
    strategy: .replaceExisting
  )
  let accountIDs = await providerWorkspace.allAccounts().map(\.id)
  let remainingSecret = await vault.secret(
    accountID: oldAccount.id,
    field: ProviderAccountManager.apiKeyField
  )

  #expect(failures == [oldAccount.id])
  #expect(accountIDs == [newAccount.id])
  #expect(remainingSecret == "secret")
}

@Test func contextBuilderRejectsOversizedSystemAndLatestMessage() throws {
  let oversizedSystem = ChatConversation(
    providerID: "deepseek",
    accountID: "account",
    modelID: "model",
    systemPrompt: String(repeating: "system ", count: 100)
  )
  #expect(throws: ProviderError.self) {
    _ = try ChatContextBuilder.build(
      conversation: oversizedSystem,
      contextWindow: 300,
      reservedOutputTokens: 256
    )
  }

  let oversizedMessage = ChatConversation(
    providerID: "deepseek",
    accountID: "account",
    modelID: "model",
    messages: [
      ChatMessage(
        role: .user,
        content: String(repeating: "latest ", count: 100),
        status: .complete
      )
    ]
  )
  #expect(throws: ProviderError.self) {
    _ = try ChatContextBuilder.build(
      conversation: oversizedMessage,
      contextWindow: 300,
      reservedOutputTokens: 256
    )
  }
}

@Test func oversizedContextNeverDispatchesProviderRequest() async throws {
  let providerWorkspace = ProviderWorkspaceStore(
    persistence: InMemoryProviderWorkspacePersistence()
  )
  try await providerWorkspace.load()
  let account = ProviderAccount(
    kind: ProviderKind(providerID: "deepseek"),
    id: "account",
    providerID: "deepseek",
    label: "DeepSeek",
    defaultModelID: "small"
  )
  try await providerWorkspace.upsertAccount(account)
  try await providerWorkspace.addManualModel(
    ProviderModel(
      providerID: "deepseek",
      id: "small",
      displayName: "Small",
      contextWindow: 300,
      maxOutputTokens: 256
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
    modelID: "small"
  )
  let provider = CountingProviderRuntime()
  let chat = ChatRuntime(
    providerRuntime: provider,
    providerWorkspace: providerWorkspace,
    conversations: conversations
  )

  await #expect(throws: ProviderError.self) {
    for try await _ in await chat.send(
      conversationID: conversation.id,
      userText: String(repeating: "oversized ", count: 100)
    ) {}
  }

  #expect(await provider.requestCount() == 0)
  let saved = try await conversations.conversation(id: conversation.id)
  #expect(saved.messages.last?.status == .failed)
}
