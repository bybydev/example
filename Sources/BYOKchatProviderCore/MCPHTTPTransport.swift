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

    let boundedRequest: URLRequest = {
      var copy = request
      copy.timeoutInterval = discoverProbeTimeout
      return copy
    }()
    let baseTransport = self.base
    let timeout = discoverProbeTimeout

    return try await withThrowingTaskGroup(of: ProviderHTTPByteStream.self) { group in
      group.addTask { @Sendable [baseTransport, boundedRequest] in
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

  private func isDiscoverProbe(_ request: URLRequest) -> Bool {
    request.value(forHTTPHeaderField: "Mcp-Method") == "server/discover"
  }
}
