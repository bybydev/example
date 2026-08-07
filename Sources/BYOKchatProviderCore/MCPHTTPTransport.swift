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
    try await base.data(for: bounded(request))
  }

  public func stream(for request: URLRequest) async throws -> ProviderHTTPByteStream {
    try await base.stream(for: bounded(request))
  }

  private func bounded(_ request: URLRequest) -> URLRequest {
    guard request.value(forHTTPHeaderField: "Mcp-Method") == "server/discover" else {
      return request
    }
    var copy = request
    copy.timeoutInterval = discoverProbeTimeout
    return copy
  }
}
