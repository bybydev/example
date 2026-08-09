import Foundation
import Testing

@testable import BYOKchatProviderCore

@Test func chatRuntimeRecordsSuccessfulProviderLifecycle() async throws {
  let location = temporaryRuntimeTelemetryLocation()
  defer { try? FileManager.default.removeItem(at: location.directory) }

  let recorder = TelemetryRecorder(
    databaseURL: location.database,
    configuration: runtimeTelemetryConfiguration(),
    deviceID: "runtime-device",
    sessionID: "runtime-session"
  )
  let environment = try await makeConversationEnvironment(telemetryRecorder: recorder)

  for try await _ in await environment.chat.send(
    conversationID: environment.conversation.id,
    userText: "Hello"
  ) {}

  let events = await waitForRuntimeTelemetry(
    recorder,
    requiredNames: [
      .chatTurnStarted,
      .contextBuilt,
      .providerRequestStarted,
      .providerFirstToken,
      .providerRequestCompleted,
      .chatTurnCompleted,
    ]
  )

  let names = Set(events.map(\.name))
  #expect(names.contains(.chatTurnStarted))
  #expect(names.contains(.contextBuilt))
  #expect(names.contains(.providerRequestStarted))
  #expect(names.contains(.providerFirstToken))
  #expect(names.contains(.providerRequestCompleted))
  #expect(names.contains(.chatTurnCompleted))

  let providerCompleted = try #require(
    events.first(where: { $0.name == .providerRequestCompleted })
  )
  #expect(providerCompleted.providerID == "deepseek")
  #expect(providerCompleted.modelID == "deepseek-v4-flash")
  #expect(providerCompleted.inputTokens == 12)
  #expect(providerCompleted.outputTokens == 4)
  #expect(providerCompleted.modelRequestCount == 1)
  #expect(providerCompleted.durationMilliseconds != nil)
  #expect(providerCompleted.timeToFirstTokenMilliseconds != nil)
  #expect(providerCompleted.metadata["requestIndex"] == "1")
  #expect(providerCompleted.metadata["retryCount"] == "0")
  #expect(providerCompleted.metadata["outputTokensPerSecond"] != nil)

  let context = try #require(events.first(where: { $0.name == .contextBuilt }))
  #expect(context.metadata["estimatedInputTokens"] != nil)
  #expect(context.metadata["includedMessageCount"] != nil)
  #expect(context.metadata["omittedMessageCount"] != nil)
  #expect(context.metadata["contextWindow"] == "256")
  #expect(context.metadata["contextWindowKind"] == ProviderContextWindowKind.combined.rawValue)

  let turnCompleted = try #require(events.first(where: { $0.name == .chatTurnCompleted }))
  #expect(turnCompleted.inputTokens == 12)
  #expect(turnCompleted.outputTokens == 4)
  #expect(turnCompleted.modelRequestCount == 1)
  #expect(turnCompleted.metadata["operation"] == "send")
}

@Test func chatRuntimeClassifiesProviderFailureWithoutPersistingErrorText() async throws {
  let location = temporaryRuntimeTelemetryLocation()
  defer { try? FileManager.default.removeItem(at: location.directory) }

  let recorder = TelemetryRecorder(
    databaseURL: location.database,
    configuration: runtimeTelemetryConfiguration(),
    deviceID: "runtime-device",
    sessionID: "runtime-session"
  )
  let environment = try await makeConversationEnvironment(
    runtimeMode: .partialFailure,
    telemetryRecorder: recorder
  )

  do {
    for try await _ in await environment.chat.send(
      conversationID: environment.conversation.id,
      userText: "Fail after streaming starts"
    ) {}
  } catch {}

  let events = await waitForRuntimeTelemetry(
    recorder,
    requiredNames: [.providerRequestFailed, .chatTurnFailed]
  )
  let providerFailure = try #require(
    events.first(where: { $0.name == .providerRequestFailed })
  )
  #expect(providerFailure.outcome == .failure)
  #expect(providerFailure.errorCode == "transport")
  #expect(providerFailure.metadata["classification"] == "transport")
  #expect(providerFailure.metadata["completionUnknown"] == "true")
  #expect(providerFailure.metadata.values.allSatisfy { !$0.contains("Connection lost") })

  let turnFailure = try #require(events.first(where: { $0.name == .chatTurnFailed }))
  #expect(turnFailure.errorCode == "transport")
  #expect(turnFailure.metadata["operation"] == "send")
  #expect(turnFailure.dataClass == .analytics)
}

@Test func chatRuntimeRecordsProviderAndTurnCancellation() async throws {
  let location = temporaryRuntimeTelemetryLocation()
  defer { try? FileManager.default.removeItem(at: location.directory) }

  let recorder = TelemetryRecorder(
    databaseURL: location.database,
    configuration: runtimeTelemetryConfiguration(),
    deviceID: "runtime-device",
    sessionID: "runtime-session"
  )
  let environment = try await makeConversationEnvironment(
    runtimeMode: .suspended,
    telemetryRecorder: recorder
  )

  let stream = await environment.chat.send(
    conversationID: environment.conversation.id,
    userText: "Wait"
  )
  let consumer = Task {
    do {
      for try await _ in stream {}
    } catch {}
  }

  for _ in 0..<100 {
    if await environment.runtime.requestCount() > 0 { break }
    try? await Task.sleep(for: .milliseconds(5))
  }

  await environment.chat.cancel(conversationID: environment.conversation.id)
  _ = await consumer.result

  let events = await waitForRuntimeTelemetry(
    recorder,
    requiredNames: [.providerRequestCancelled, .chatTurnCancelled]
  )
  let providerCancellation = try #require(
    events.first(where: { $0.name == .providerRequestCancelled })
  )
  #expect(providerCancellation.outcome == .cancelled)
  #expect(providerCancellation.errorCode == "cancelled")

  let turnCancellation = try #require(
    events.first(where: { $0.name == .chatTurnCancelled })
  )
  #expect(turnCancellation.outcome == .cancelled)
  #expect(turnCancellation.metadata["operation"] == "send")
}

@Test func telemetryStorageFailureNeverBreaksChatRuntime() async throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("BYOKchatRuntimeTelemetryBlocked-\(UUID().uuidString)", isDirectory: true)
  defer { try? FileManager.default.removeItem(at: root) }
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

  let blockingFile = root.appendingPathComponent("not-a-directory")
  try Data("blocked".utf8).write(to: blockingFile)
  let recorder = TelemetryRecorder(
    databaseURL: blockingFile.appendingPathComponent("telemetry.sqlite"),
    configuration: runtimeTelemetryConfiguration(),
    deviceID: "runtime-device",
    sessionID: "runtime-session"
  )
  let environment = try await makeConversationEnvironment(telemetryRecorder: recorder)

  for try await _ in await environment.chat.send(
    conversationID: environment.conversation.id,
    userText: "Telemetry must not matter"
  ) {}

  let conversation = try await environment.conversations.conversation(id: environment.conversation.id)
  #expect(conversation.messages.last?.status == .complete)
  #expect(conversation.messages.last?.content == "Hello")

  for _ in 0..<100 {
    if !(await recorder.health().isAvailable) { break }
    try? await Task.sleep(for: .milliseconds(10))
  }
  #expect(!(await recorder.health().isAvailable))
}

@Test func providerFailureDescriptorKeepsOnlyStableClassification() {
  let provider = ChatRuntimeTelemetry.failureDescriptor(
    for: ProviderError.provider(status: 503, message: "private provider response")
  )
  #expect(provider.errorCode == "provider_http")
  #expect(provider.classification == "http")
  #expect(provider.httpStatus == 503)
  #expect(provider.metadata.isEmpty)

  let rateLimit = ChatRuntimeTelemetry.failureDescriptor(
    for: ProviderError.rateLimited(retryAfter: "60")
  )
  #expect(rateLimit.errorCode == "rate_limited")
  #expect(rateLimit.httpStatus == 429)
  #expect(rateLimit.metadata["retryAfterProvided"] == "true")
}

private func waitForRuntimeTelemetry(
  _ recorder: TelemetryRecorder,
  requiredNames: Set<TelemetryEventName>
) async -> [TelemetryEvent] {
  for _ in 0..<100 {
    let events = await recorder.recentEvents(limit: 100)
    let names = Set(events.map(\.name))
    if requiredNames.isSubset(of: names) {
      return events
    }
    try? await Task.sleep(for: .milliseconds(10))
  }
  return await recorder.recentEvents(limit: 100)
}

private func runtimeTelemetryConfiguration() -> TelemetryStoreConfiguration {
  TelemetryStoreConfiguration(
    maximumAge: 30 * 24 * 60 * 60,
    maximumEventCount: 10_000,
    maximumDatabaseBytes: 10 * 1024 * 1024,
    maintenanceInsertInterval: 1_000,
    pruneBatchSize: 100
  )
}

private func temporaryRuntimeTelemetryLocation() -> (directory: URL, database: URL) {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("BYOKchatRuntimeTelemetryTests-\(UUID().uuidString)", isDirectory: true)
  return (
    directory,
    directory.appendingPathComponent("telemetry.sqlite", isDirectory: false)
  )
}
