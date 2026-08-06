import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public struct ProviderHTTPResponse: Sendable {
  public var statusCode: Int
  public var headers: [String: String]
  public var data: Data

  public init(statusCode: Int, headers: [String: String], data: Data) {
    self.statusCode = statusCode
    self.headers = headers
    self.data = data
  }
}

public struct ProviderHTTPByteStream: Sendable {
  public var statusCode: Int
  public var headers: [String: String]
  public var chunks: AsyncThrowingStream<Data, Error>

  public init(
    statusCode: Int,
    headers: [String: String],
    chunks: AsyncThrowingStream<Data, Error>
  ) {
    self.statusCode = statusCode
    self.headers = headers
    self.chunks = chunks
  }
}

public protocol ProviderHTTPTransport: Sendable {
  func data(for request: URLRequest) async throws -> ProviderHTTPResponse
  func stream(for request: URLRequest) async throws -> ProviderHTTPByteStream
}

public struct URLSessionProviderHTTPTransport: ProviderHTTPTransport, @unchecked Sendable {
  private let session: URLSession

  public init(session: URLSession? = nil) {
    self.session = session ?? Self.makeDefaultSession()
  }

  public func data(for request: URLRequest) async throws -> ProviderHTTPResponse {
    do {
      let (data, response) = try await session.data(for: request)
      guard let response = response as? HTTPURLResponse else {
        throw ProviderError.invalidResponse
      }
      return .init(
        statusCode: response.statusCode,
        headers: Self.headers(response),
        data: data
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as ProviderError {
      throw error
    } catch {
      throw ProviderError.transport(
        message: error.localizedDescription,
        completionUnknown: true
      )
    }
  }

  public func stream(for request: URLRequest) async throws -> ProviderHTTPByteStream {
    #if canImport(Darwin)
      do {
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else {
          throw ProviderError.invalidResponse
        }

        let pair = AsyncThrowingStream<Data, Error>.makeStream()
        let task = Task { @Sendable in
          var pending: [UInt8] = []
          do {
            for try await byte in bytes {
              try Task.checkCancellation()
              pending.append(byte)
              if pending.count >= 1024 {
                pair.continuation.yield(Data(pending))
                pending.removeAll(keepingCapacity: true)
              }
            }
            if !pending.isEmpty {
              pair.continuation.yield(Data(pending))
            }
            pair.continuation.finish()
          } catch {
            pair.continuation.finish(throwing: error)
          }
        }
        pair.continuation.onTermination = { @Sendable _ in
          task.cancel()
        }

        return .init(
          statusCode: response.statusCode,
          headers: Self.headers(response),
          chunks: pair.stream
        )
      } catch is CancellationError {
        throw CancellationError()
      } catch let error as ProviderError {
        throw error
      } catch {
        throw ProviderError.transport(
          message: error.localizedDescription,
          completionUnknown: true
        )
      }
    #else
      let response = try await data(for: request)
      let chunks = AsyncThrowingStream<Data, Error> { continuation in
        continuation.yield(response.data)
        continuation.finish()
      }
      return .init(
        statusCode: response.statusCode,
        headers: response.headers,
        chunks: chunks
      )
    #endif
  }

  private static func makeDefaultSession() -> URLSession {
    #if canImport(Darwin)
      let configuration = URLSessionConfiguration.ephemeral
      configuration.httpShouldSetCookies = false
      configuration.httpCookieAcceptPolicy = .never
      configuration.urlCache = nil
      configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
      return URLSession(
        configuration: configuration,
        delegate: ProviderSameOriginRedirectDelegate.shared,
        delegateQueue: nil
      )
    #else
      return .shared
    #endif
  }

  private static func headers(_ response: HTTPURLResponse) -> [String: String] {
    Dictionary(
      uniqueKeysWithValues: response.allHeaderFields.map {
        (String(describing: $0.key), String(describing: $0.value))
      }
    )
  }
}

#if canImport(Darwin)
  private final class ProviderSameOriginRedirectDelegate: NSObject, URLSessionTaskDelegate,
    @unchecked Sendable
  {
    static let shared = ProviderSameOriginRedirectDelegate()

    func urlSession(
      _ session: URLSession,
      task: URLSessionTask,
      willPerformHTTPRedirection response: HTTPURLResponse,
      newRequest request: URLRequest
    ) async -> URLRequest? {
      guard let sourceURL = response.url,
        let destinationURL = request.url,
        ProviderHTTP.isSameOriginRedirect(from: sourceURL, to: destinationURL)
      else {
        return nil
      }

      var redirected = request
      let headers =
        task.currentRequest?.allHTTPHeaderFields
        ?? task.originalRequest?.allHTTPHeaderFields
      for (name, value) in headers ?? [:]
      where ProviderHTTP.canForwardHeaderAcrossRedirect(name) {
        redirected.setValue(value, forHTTPHeaderField: name)
      }
      return redirected
    }
  }
#endif

public enum ProviderHTTP {
  private static let forbiddenHeaders: Set<String> = [
    "authorization",
    "proxy-authorization",
    "host",
    "content-length",
    "connection",
    "cookie",
    "set-cookie",
    "transfer-encoding",
  ]

  public static func endpoint(
    baseURL: URL,
    path: String,
    allowsLocalHTTP: Bool = false
  ) throws -> URL {
    try validateBaseURL(baseURL, allowsLocalHTTP: allowsLocalHTTP)
    let relative = path.hasPrefix("/") ? String(path.dropFirst()) : path
    return baseURL.appendingPathComponent(relative)
  }

  public static func validateBaseURL(
    _ baseURL: URL,
    allowsLocalHTTP: Bool = false
  ) throws {
    guard baseURL.user == nil,
      baseURL.password == nil,
      let host = baseURL.host
    else {
      throw ProviderError.invalidBaseURL
    }

    switch baseURL.scheme?.lowercased() {
    case "https":
      return
    case "http" where allowsLocalHTTP && isPrivateNetworkHost(host):
      return
    default:
      throw ProviderError.invalidBaseURL
    }
  }

  public static func isPrivateNetworkHost(_ host: String) -> Bool {
    let value = host.lowercased().trimmingCharacters(
      in: CharacterSet(charactersIn: "[]")
    )
    if value == "localhost" || value.hasSuffix(".localhost") || value.hasSuffix(".local") {
      return true
    }

    if let parts = parseIPv4(value) {
      if parts[0] == 10 || parts[0] == 127 { return true }
      if parts[0] == 169 && parts[1] == 254 { return true }
      if parts[0] == 192 && parts[1] == 168 { return true }
      if parts[0] == 172 && (16...31).contains(parts[1]) { return true }
      return false
    }

    guard let groups = parseIPv6(value) else { return false }
    let first = groups[0]
    if first & 0xFE00 == 0xFC00 { return true }
    if first & 0xFFC0 == 0xFE80 { return true }
    return groups.dropLast().allSatisfy { $0 == 0 } && groups.last == 1
  }

  public static func isSameOriginRedirect(
    from source: URL,
    to destination: URL
  ) -> Bool {
    guard source.user == nil,
      source.password == nil,
      destination.user == nil,
      destination.password == nil,
      let sourceScheme = source.scheme?.lowercased(),
      let destinationScheme = destination.scheme?.lowercased(),
      let sourceHost = source.host?.lowercased(),
      let destinationHost = destination.host?.lowercased()
    else {
      return false
    }

    return sourceScheme == destinationScheme
      && sourceHost == destinationHost
      && effectivePort(source) == effectivePort(destination)
  }

  public static func makeRequest(
    url: URL,
    method: String,
    authentication: ProviderAuthentication,
    secret: String?,
    additionalHeaders: [String: String] = [:]
  ) throws -> URLRequest {
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.timeoutInterval = 120
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    let normalizedSecret = secret?.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    switch authentication {
    case .bearer:
      if let normalizedSecret, !normalizedSecret.isEmpty {
        request.setValue(
          "Bearer \(normalizedSecret)",
          forHTTPHeaderField: "Authorization"
        )
      }
    case .header(let name):
      guard !Self.isForbiddenCustomHeader(name) else {
        throw ProviderError.unsafeHeader(name)
      }
      if let normalizedSecret, !normalizedSecret.isEmpty {
        request.setValue(normalizedSecret, forHTTPHeaderField: name)
      }
    case .none:
      break
    }

    for (name, value) in additionalHeaders {
      guard !Self.isForbiddenCustomHeader(name) else {
        throw ProviderError.unsafeHeader(name)
      }
      request.setValue(value, forHTTPHeaderField: name)
    }
    return request
  }

  public static func isForbiddenCustomHeader(_ name: String) -> Bool {
    forbiddenHeaders.contains(
      name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    )
  }

  static func canForwardHeaderAcrossRedirect(_ name: String) -> Bool {
    let normalized = name.trimmingCharacters(
      in: .whitespacesAndNewlines
    ).lowercased()
    return ![
      "host",
      "content-length",
      "connection",
      "transfer-encoding",
      "cookie",
    ].contains(normalized)
  }

  private static func parseIPv4(_ value: String) -> [Int]? {
    let pieces = value.split(separator: ".", omittingEmptySubsequences: false)
    guard pieces.count == 4 else { return nil }
    var result: [Int] = []
    for piece in pieces {
      guard !piece.isEmpty,
        piece.allSatisfy(\.isNumber),
        let number = Int(piece),
        (0...255).contains(number)
      else {
        return nil
      }
      result.append(number)
    }
    return result
  }

  private static func parseIPv6(_ value: String) -> [UInt16]? {
    let address = value.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)
      .first.map(String.init) ?? value
    guard address.contains(":") else { return nil }

    let halves = address.components(separatedBy: "::")
    guard halves.count <= 2 else { return nil }

    func parseHalf(_ half: String) -> [UInt16]? {
      guard !half.isEmpty else { return [] }
      let pieces = half.split(separator: ":", omittingEmptySubsequences: false)
      var values: [UInt16] = []
      for piece in pieces {
        guard !piece.isEmpty,
          piece.count <= 4,
          let value = UInt16(piece, radix: 16)
        else {
          return nil
        }
        values.append(value)
      }
      return values
    }

    guard let left = parseHalf(halves[0]) else { return nil }
    if halves.count == 1 {
      return left.count == 8 ? left : nil
    }

    guard let right = parseHalf(halves[1]), left.count + right.count < 8 else { return nil }
    return left + Array(repeating: 0, count: 8 - left.count - right.count) + right
  }

  private static func effectivePort(_ url: URL) -> Int? {
    if let port = url.port { return port }
    switch url.scheme?.lowercased() {
    case "http": return 80
    case "https": return 443
    default: return nil
    }
  }
}
