import Foundation
import Testing

@testable import BYOKchatProviderCore

@Test func telemetryLogFilterMatchesStructuredDimensionsAndSearch() {
  let provider: ProviderID = "deepseek"
  let model: ModelID = "deepseek-chat"
  let conversation: ConversationID = "conversation-a"
  let event = TelemetryEvent(
    dataClass: .analytics,
    category: .provider,
    name: .providerRequestFailed,
    severity: .warning,
    outcome: .failure,
    conversationID: conversation,
    providerID: provider,
    modelID: model,
    errorCode: "rate_limited",
    metadata: ["classification": "rate_limit"]
  )

  #expect(
    TelemetryLogFilter(
      dataClass: .analytics,
      category: .provider,
      severity: .warning,
      providerID: provider,
      modelID: model,
      conversationID: conversation,
      searchText: "rate limit"
    ).matches(event)
  )
  #expect(!TelemetryLogFilter(category: .mcp).matches(event))
  #expect(!TelemetryLogFilter(searchText: "anthropic").matches(event))
}

@Test func telemetryDiagnosticsExportSanitizesRawEvents() throws {
  let event = TelemetryEvent(
    dataClass: .diagnostic,
    category: .provider,
    name: "provider.debug",
    providerID: "openrouter",
    errorCode: "transport",
    metadata: [
      "classification": "transport",
      "Authorization": "Bearer private-key",
      "requestBody": "private prompt",
      "safeValue": "kept",
    ]
  )

  let data = try TelemetryDiagnostics.exportJSON(
    events: [event],
    generatedAt: Date(timeIntervalSince1970: 1_700_000_000)
  )
  let text = try #require(String(data: data, encoding: .utf8))

  #expect(text.contains("provider.debug"))
  #expect(text.contains("safeValue"))
  #expect(text.contains("kept"))
  #expect(!text.lowercased().contains("authorization"))
  #expect(!text.contains("private-key"))
  #expect(!text.contains("private prompt"))
}

@Test func telemetryDiagnosticsTextUsesSanitizedMetadata() {
  let event = TelemetryEvent(
    dataClass: .analytics,
    category: .tool,
    name: .toolCallFailed,
    severity: .warning,
    outcome: .failure,
    conversationID: "conversation-b",
    durationMilliseconds: 125.5,
    errorCode: "tool_result_error",
    metadata: [
      "toolName": "lookup_weather",
      "toolArguments": "private city prompt",
    ]
  )

  let text = TelemetryDiagnostics.text(for: event)
  #expect(text.contains("tool.call.failed"))
  #expect(text.contains("lookup_weather"))
  #expect(!text.contains("private city prompt"))
}
