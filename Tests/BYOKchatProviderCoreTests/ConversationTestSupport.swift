import Foundation
import Testing

@testable import BYOKchatProviderCore

actor MockStreamingRuntime: ProviderStreamingRuntime {
  enum Mode: Sendable {
    case success
    case partialFailure
    case suspended
  }

  let mode: Mode
  private(set) var requests: [ProviderRequest] = []

  init(mode: Mode) { self.mode = mode }

  func stream(
    request: ProviderRequest,
    accountID: ProviderAccountID
  ) async throws -> AsyncThrowingStream<ProviderStreamEvent, Error> {
    requests.append(request)
    return AsyncThrowingStream { continuation in
      let task = Task {
        switch mode {
        case .success:
          continuation.yield(.reasoningDelta("Think "))
          continuation.yield(.textDelta("Hello"))
          let usage = ProviderUsage(inputTokens: 12, outputTokens: 4)
          continuation.yield(.usage(usage))
          continuation.yield(
            .completed(
              ProviderResponse(
                text: "Hello",
                reasoning: "Think ",
                providerID: "deepseek",
                accountID: accountID,
                modelID: request.model,
                finishReason: "stop",
                usage: usage
              )
            )
          )
          continuation.finish()
        case .partialFailure:
          continuation.yield(.textDelta("Partial"))
          continuation.finish(
            throwing: ProviderError.transport(
              message: "Connection lost.",
              completionUnknown: true
            )
          )
        case .suspended:
          do {
            try await Task.sleep(for: .seconds(30))
            continuation.finish()
          } catch {
            continuation.finish(throwing: CancellationError())
          }
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  func requestCount() -> Int { requests.count }
}

func makeConversationEnvironment(
  runtimeMode: MockStreamingRuntime.Mode = .success,
  partialPersistenceInterval: Duration = .zero,
  telemetryRecorder: TelemetryRecorder? = nil
) async throws -> (
  conversations: ConversationStore,
  providerWorkspace: ProviderWorkspaceStore,
  runtime: MockStreamingRuntime,
  chat: ChatRuntime,
  conversation: ChatConversation
) {
  let providerPersistence = InMemoryProviderWorkspacePersistence()
  let providerWorkspace = ProviderWorkspaceStore(persistence: providerPersistence)
  try await providerWorkspace.load()
  let account = ProviderAccount(
    id: "account",
    providerID: "deepseek",
    label: "DeepSeek",
    defaultModelID: "deepseek-v4-flash"
  )
  try await providerWorkspace.upsertAccount(account)
  try await providerWorkspace.addManualModel(
    ProviderModel(
      providerID: "deepseek",
      id: "deepseek-v4-flash",
      displayName: "DeepSeek V4 Flash",
      contextWindow: 256,
      maxOutputTokens: 64
    ),
    for: account.id
  )

  let conversationPersistence = InMemoryConversationWorkspacePersistence()
  let conversations = ConversationStore(persistence: conversationPersistence)
  try await conversations.load()
  let conversation = try await conversations.createConversation(
    providerID: account.providerID,
    accountID: account.id,
    modelID: "deepseek-v4-flash",
    systemPrompt: "Be concise."
  )
  let runtime = MockStreamingRuntime(mode: runtimeMode)
  let chat = ChatRuntime(
    providerRuntime: runtime,
    providerWorkspace: providerWorkspace,
    conversations: conversations,
    telemetryRecorder: telemetryRecorder,
    partialPersistenceInterval: partialPersistenceInterval
  )
  return (conversations, providerWorkspace, runtime, chat, conversation)
}
