import BYOKchatProviderCore
import Foundation
import Testing

@testable import BYOKmac

@Suite("macOS diagnostics support")
struct MacDiagnosticsTests {
  @Test("canClearAllTelemetry is disabled only when both events and daily rollups are zero")
  func canClearAllTelemetryChecksEventsAndRollups() {
    #expect(!MacDiagnosticsSupport.canClearAllTelemetry(.empty))

    let rollupsOnly = TelemetryStoreStatistics(
      eventCount: 0,
      diagnosticEventCount: 0,
      analyticsEventCount: 0,
      databaseBytes: 4_096,
      oldestEventAt: nil,
      newestEventAt: nil,
      schemaVersion: 2,
      rollupRowCount: 5
    )
    #expect(MacDiagnosticsSupport.canClearAllTelemetry(rollupsOnly))

    let eventsOnly = TelemetryStoreStatistics(
      eventCount: 3,
      diagnosticEventCount: 1,
      analyticsEventCount: 2,
      databaseBytes: 8_192,
      oldestEventAt: .now,
      newestEventAt: .now,
      schemaVersion: 2,
      rollupRowCount: 0
    )
    #expect(MacDiagnosticsSupport.canClearAllTelemetry(eventsOnly))

    let both = TelemetryStoreStatistics(
      eventCount: 12,
      diagnosticEventCount: 4,
      analyticsEventCount: 8,
      databaseBytes: 16_384,
      oldestEventAt: .now,
      newestEventAt: .now,
      schemaVersion: 2,
      rollupRowCount: 14
    )
    #expect(MacDiagnosticsSupport.canClearAllTelemetry(both))
  }

  @Test("categoryDisplayTitle renders MCP uppercase and capitalizes all other categories")
  func categoryDisplayTitleFormatsAllCategories() {
    #expect(MacDiagnosticsSupport.categoryDisplayTitle(.mcp) == "MCP")
    #expect(MacDiagnosticsSupport.categoryDisplayTitle(.app) == "App")
    #expect(MacDiagnosticsSupport.categoryDisplayTitle(.chat) == "Chat")
    #expect(MacDiagnosticsSupport.categoryDisplayTitle(.context) == "Context")
    #expect(MacDiagnosticsSupport.categoryDisplayTitle(.provider) == "Provider")
    #expect(MacDiagnosticsSupport.categoryDisplayTitle(.tool) == "Tool")
    #expect(MacDiagnosticsSupport.categoryDisplayTitle(.purchase) == "Purchase")
    #expect(MacDiagnosticsSupport.categoryDisplayTitle(.sync) == "Sync")
    #expect(MacDiagnosticsSupport.categoryDisplayTitle(.storage) == "Storage")

    for category in TelemetryCategory.allCases {
      let title = MacDiagnosticsSupport.categoryDisplayTitle(category)
      #expect(title != "Mcp")
      #expect(!title.isEmpty)
    }
  }

  @Test("eventShareText includes event name, uppercase MCP category, model requests, tool calls, and sanitizes metadata")
  func eventShareTextIncludesMCPAndRequestToolCounts() {
    let event = TelemetryEvent(
      id: "evt-mcp-1",
      timestamp: Date(timeIntervalSince1970: 1_764_000_000),
      dataClass: .diagnostic,
      category: .mcp,
      name: .mcpRequestCompleted,
      severity: .info,
      outcome: .success,
      providerID: "anthropic",
      modelID: "claude-sonnet-4-5",
      durationMilliseconds: 245.5,
      modelRequestCount: 3,
      toolCallCount: 4,
      httpStatus: 200,
      metadata: [
        "transport": "streamable_http",
        "apiKey": "sk-secret-should-not-appear",
      ]
    )

    let shareText = MacDiagnosticsSupport.eventShareText(for: event)
    #expect(shareText.contains("mcp.request.completed"))
    #expect(shareText.contains("MCP"))
    #expect(!shareText.contains("Mcp"))
    #expect(shareText.contains("Model requests: 3"))
    #expect(shareText.contains("Tool calls: 4"))
    #expect(shareText.contains("transport: streamable_http"))
    #expect(!shareText.contains("sk-secret-should-not-appear"))
  }

  @Test("eventShareText omits model requests and tool calls when absent")
  func eventShareTextOmitsMissingCounts() {
    let event = TelemetryEvent(
      id: "evt-app-1",
      timestamp: Date(timeIntervalSince1970: 1_764_000_000),
      dataClass: .analytics,
      category: .app,
      name: .appLaunched,
      severity: .info
    )

    let shareText = MacDiagnosticsSupport.eventShareText(for: event)
    #expect(shareText.contains("app.launched"))
    #expect(shareText.contains("Category: App"))
    #expect(!shareText.contains("Model requests:"))
    #expect(!shareText.contains("Tool calls:"))
  }
}
