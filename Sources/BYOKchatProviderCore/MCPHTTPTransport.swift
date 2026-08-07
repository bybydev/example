import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// Production HTTP wrapper for MCP. Pre-2026 servers can ignore `server/discover`
/// instead of returning an error, so the modern probe must be bounded before the
/// runtime can fall back to the initialize-era protocol.
public struct MCPHTTPTransport: ProviderHTTPTransport, Sendable {
  private let base: any ProviderHTTPTransport
  private let discoverProbeTimeout: TimeInterval

  public init(
    base: any ProviderHTTPTransport = URLSessionProviderHTTPTransport(),
    discoverProbeTimeout: TimeInterval = 5
  ) {
    self.base = base
    self.discoverProbeTimeout = discoverProbeTimeout
  }

  public func data(for request: URLRequest) async throws -> ProviderHTTPResponse {
    guard isDiscoverProbe(request) else {
      return try await base.data(for: request)
    }

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
    guard isDiscoverProbe(request) else {
      return try await base.stream(for: request)
    }

    var bounded = request
    bounded.timeoutInterval = discoverProbeTimeout
    let base = self.base
    let timeout = discoverProbeTimeout

    return try await withThrowingTaskGroup(of: ProviderHTTPByteStream.self) { group in
      group.addTask {
        let upstream = try await base.stream(for: bounded)
        var data = Data()
        for try await chunk in upstream.chunks {
          try Task.checkCancellation()
          data.append(chunk)
        }
        return ProviderHTTPByteStream(
          statusCode: upstream.statusCode,
          headers: upstream.headers,
          chunks: AsyncThrowingStream { continuation in
            if !data.isEmpty { continuation.yield(data) }
            continuation.finish()
          }
        )
      }

      group.addTask {
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

  private func isDiscoverProbe(_ request: URLRequest) -> Bool {
    request.value(forHTTPHeaderField: "Mcp-Method") == "server/discover"
  }
}
