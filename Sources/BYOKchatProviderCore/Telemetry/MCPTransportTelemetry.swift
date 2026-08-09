import Foundation

struct MCPTransportTelemetryContext: Sendable, Equatable {
  var method: String
  var protocolEra: MCPProtocolEra
  var protocolVersion: String?
  var toolName: String?
  var hasSession: Bool

  init(
    method: String,
    protocolEra: MCPProtocolEra,
    protocolVersion: String?,
    toolName: String?,
    hasSession: Bool
  ) {
    self.method = method
    self.protocolEra = protocolEra
    self.protocolVersion = protocolVersion
    self.toolName = toolName
    self.hasSession = hasSession
  }
}

struct MCPTransportTelemetry: Sendable {
  let recorder: TelemetryRecorder?

  init(recorder: TelemetryRecorder?) {
    self.recorder = recorder ?? TelemetryRecorder.shared
  }

  func started(_ context: MCPTransportTelemetryContext) {
    emit(
      TelemetryEvent(
        dataClass: .analytics,
        category: .mcp,
        name: .mcpRequestStarted,
        metadata: metadata(context)
      )
    )
  }

  func completed(
    _ context: MCPTransportTelemetryContext,
    statusCode: Int,
    durationMilliseconds: Double,
    responseMode: String
  ) {
    var metadata = metadata(context)
    metadata["responseMode"] = responseMode
    let succeeded = (200..<300).contains(statusCode)
    let legacyProbeFallback =
      context.method == "server/discover" && [400, 404, 405].contains(statusCode)
    if legacyProbeFallback {
      metadata["classification"] = "protocol_fallback"
      metadata["expectedFallback"] = "true"
    } else if !succeeded {
      metadata["classification"] = "http"
    }

    emit(
      TelemetryEvent(
        dataClass: .analytics,
        category: .mcp,
        name: succeeded ? .mcpRequestCompleted : .mcpRequestFailed,
        severity: succeeded ? .info : .warning,
        outcome: succeeded ? .success : .failure,
        durationMilliseconds: durationMilliseconds,
        httpStatus: statusCode,
        errorCode: succeeded ? nil : (legacyProbeFallback ? "legacy_probe_fallback" : "http_status"),
        metadata: metadata
      )
    )
  }

  func failed(
    _ context: MCPTransportTelemetryContext,
    error: Error,
    durationMilliseconds: Double
  ) {
    if error is CancellationError {
      cancelled(context, durationMilliseconds: durationMilliseconds)
      return
    }

    let failure = failureDescriptor(error)
    var metadata = metadata(context)
    metadata["classification"] = failure.classification
    for (key, value) in failure.metadata { metadata[key] = value }

    emit(
      TelemetryEvent(
        dataClass: .analytics,
        category: .mcp,
        name: .mcpRequestFailed,
        severity: .warning,
        outcome: .failure,
        durationMilliseconds: durationMilliseconds,
        httpStatus: failure.httpStatus,
        errorCode: failure.errorCode,
        metadata: metadata
      )
    )
  }

  func cancelled(
    _ context: MCPTransportTelemetryContext,
    durationMilliseconds: Double
  ) {
    var metadata = metadata(context)
    metadata["classification"] = "cancelled"
    emit(
      TelemetryEvent(
        dataClass: .analytics,
        category: .mcp,
        name: .mcpRequestCancelled,
        severity: .notice,
        outcome: .cancelled,
        durationMilliseconds: durationMilliseconds,
        errorCode: "cancelled",
        metadata: metadata
      )
    )
  }

  static func milliseconds(_ duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds) * 1_000
      + Double(components.attoseconds) / 1_000_000_000_000_000
  }

  private func metadata(_ context: MCPTransportTelemetryContext) -> [String: String] {
    var metadata: [String: String] = [
      "method": context.method,
      "protocolEra": context.protocolEra.rawValue,
      "hasSession": String(context.hasSession),
    ]
    if let protocolVersion = context.protocolVersion {
      metadata["protocolVersion"] = protocolVersion
    }
    if let toolName = context.toolName {
      metadata["toolName"] = toolName
    }
    return metadata
  }

  private func failureDescriptor(
    _ error: Error
  ) -> (errorCode: String, classification: String, httpStatus: Int?, metadata: [String: String]) {
    if case MCPError.transport(let message) = error,
      message == "Legacy MCP probe required."
    {
      return (
        "legacy_probe_fallback",
        "protocol_fallback",
        nil,
        ["expectedFallback": "true"]
      )
    }
    if let error = error as? MCPError {
      let value = ChatToolTelemetry.failureDescriptor(for: error)
      return (value.errorCode, value.classification, nil, value.metadata)
    }
    if let error = error as? ProviderError {
      let value = ChatRuntimeTelemetry.failureDescriptor(for: error)
      return (value.errorCode, value.classification, value.httpStatus, value.metadata)
    }
    return ("unknown", "unknown", nil, [:])
  }

  private func emit(_ event: TelemetryEvent) {
    guard let recorder else { return }
    _ = Task.detached(priority: .utility) {
      await recorder.record(event)
    }
  }
}
