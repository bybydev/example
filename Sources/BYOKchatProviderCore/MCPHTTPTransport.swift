import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// Production HTTP wrapper for MCP. Pre-2026 servers can ignore `server/discover`
/// instead of returning an error, so the modern probe must be bounded before the
/// runtime can fall back to the initialize-era protocol.
public struct MCPHTTPTransport: ProviderHTTPTransport, Sendable {
  private static let maximumDiscoverResponseBytes = 1_024 * 1_024

  private let base: any ProviderHTTPTransport
  private let discoverProbeTimeout: TimeInterval
  private let telemetry: MCPTransportTelemetry

  public init(
    base: any ProviderHTTPTransport = URLSessionProviderHTTPTransport(),
    discoverProbeTimeout: TimeInterval = 5,
    telemetryRecorder: TelemetryRecorder? = nil
  ) {
    self.base = base
    self.discoverProbeTimeout = discoverProbeTimeout
    telemetry = MCPTransportTelemetry(recorder: telemetryRecorder)
  }

  public func data(for request: URLRequest) async throws -> ProviderHTTPResponse {
    let stream = try await stream(for: request)
    var data = Data()
    for try await chunk in stream.chunks {
      data.append(chunk)
    }
    return ProviderHTTPResponse(
      statusCode: stream.statusCode,
      headers: stream.headers,
      data: data
    )
  }

  public func stream(for request: URLRequest) async throws -> ProviderHTTPByteStream {
    let context = telemetryContext(for: request)
    let clock = ContinuousClock()
    let startedAt = clock.now
    telemetry.started(context)

    if isDiscoverProbe(request) {
      do {
        let response = try await boundedDiscoverResponse(for: request)
        telemetry.completed(
          context,
          statusCode: response.statusCode,
          durationMilliseconds: MCPTransportTelemetry.milliseconds(
            startedAt.duration(to: clock.now)
          ),
          responseMode: responseMode(response.headers)
        )
        return response
      } catch {
        telemetry.failed(
          context,
          error: error,
          durationMilliseconds: MCPTransportTelemetry.milliseconds(
            startedAt.duration(to: clock.now)
          )
        )
        throw error
      }
    }

    do {
      let upstream = try await base.stream(for: request)
      let pair = AsyncThrowingStream<Data, Error>.makeStream()
      let telemetry = self.telemetry
      let responseMode = responseMode(upstream.headers)
      let task = Task { @Sendable in
        do {
          for try await chunk in upstream.chunks {
            try Task.checkCancellation()
            pair.continuation.yield(chunk)
          }
          telemetry.completed(
            context,
            statusCode: upstream.statusCode,
            durationMilliseconds: MCPTransportTelemetry.milliseconds(
              startedAt.duration(to: ContinuousClock().now)
            ),
            responseMode: responseMode
          )
          pair.continuation.finish()
        } catch is CancellationError {
          telemetry.cancelled(
            context,
            durationMilliseconds: MCPTransportTelemetry.milliseconds(
              startedAt.duration(to: ContinuousClock().now)
            )
          )
          pair.continuation.finish(throwing: CancellationError())
        } catch {
          telemetry.failed(
            context,
            error: error,
            durationMilliseconds: MCPTransportTelemetry.milliseconds(
              startedAt.duration(to: ContinuousClock().now)
            )
          )
          pair.continuation.finish(throwing: error)
        }
      }
      pair.continuation.onTermination = { @Sendable _ in
        task.cancel()
      }

      return ProviderHTTPByteStream(
        statusCode: upstream.statusCode,
        headers: upstream.headers,
        chunks: pair.stream
      )
    } catch {
      telemetry.failed(
        context,
        error: error,
        durationMilliseconds: MCPTransportTelemetry.milliseconds(
          startedAt.duration(to: clock.now)
        )
      )
      throw error
    }
  }

  private func boundedDiscoverResponse(for request: URLRequest) async throws -> ProviderHTTPByteStream {
    let boundedRequest: URLRequest = {
      var copy = request
      // Give the explicit probe timer a slight lead over URLSession's request
      // timeout so silent legacy servers reliably fall back instead of racing.
      copy.timeoutInterval = discoverProbeTimeout + 1
      return copy
    }()
    let baseTransport = self.base
    let timeout = discoverProbeTimeout

    return try await withThrowingTaskGroup(of: ProviderHTTPByteStream.self) { group in
      group.addTask { @Sendable [baseTransport, boundedRequest] in
        do {
          let upstream = try await baseTransport.stream(for: boundedRequest)
          var data = Data()
          for try await chunk in upstream.chunks {
            try Task.checkCancellation()
            guard data.count + chunk.count <= Self.maximumDiscoverResponseBytes else {
              throw MCPError.invalidResponse
            }
            data.append(chunk)
          }
          let bufferedData = data
          return ProviderHTTPByteStream(
            statusCode: upstream.statusCode,
            headers: upstream.headers,
            chunks: AsyncThrowingStream { continuation in
              if !bufferedData.isEmpty { continuation.yield(bufferedData) }
              continuation.finish()
            }
          )
        } catch let error as URLError where error.code == .timedOut {
          throw MCPError.transport("Legacy MCP probe required.")
        }
      }

      group.addTask { @Sendable [timeout] in
        try await Task.sleep(for: .seconds(timeout))
        throw MCPError.transport("Legacy MCP probe required.")
      }

      guard let first = try await group.next() else {
        throw MCPError.invalidResponse
      }
      group.cancelAll()
      return first
    }
  }

  private func telemetryContext(for request: URLRequest) -> MCPTransportTelemetryContext {
    let body = rpcMetadata(request.httpBody)
    let headerMethod = request.value(forHTTPHeaderField: "Mcp-Method")
    let method = headerMethod ?? body.method ?? "unknown"
    return MCPTransportTelemetryContext(
      method: method,
      protocolEra: headerMethod == nil ? .legacy : .modern,
      protocolVersion: request.value(forHTTPHeaderField: "MCP-Protocol-Version"),
      toolName: body.toolName ?? request.value(forHTTPHeaderField: "Mcp-Name"),
      hasSession: request.value(forHTTPHeaderField: "Mcp-Session-Id")?.isEmpty == false
    )
  }

  private func rpcMetadata(_ body: Data?) -> (method: String?, toolName: String?) {
    guard let body,
      let value = try? JSONDecoder.provider.decode(JSONValue.self, from: body),
      case .object(let root) = value
    else {
      return (nil, nil)
    }

    let method: String?
    if case .string(let value)? = root["method"] {
      method = value
    } else {
      method = nil
    }

    let toolName: String?
    if case .object(let params)? = root["params"],
      case .string(let value)? = params["name"]
    {
      toolName = value
    } else {
      toolName = nil
    }
    return (method, toolName)
  }

  private func responseMode(_ headers: [String: String]) -> String {
    let contentType = headers.first {
      $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame
    }?.value.lowercased() ?? ""
    return contentType.contains("text/event-stream") ? "sse" : "json"
  }

  private func isDiscoverProbe(_ request: URLRequest) -> Bool {
    request.value(forHTTPHeaderField: "Mcp-Method") == "server/discover"
  }
}
