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
  public init(statusCode: Int, headers: [String: String], chunks: AsyncThrowingStream<Data, Error>)
  {
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
  public init(session: URLSession = .shared) { self.session = session }

  public func data(for request: URLRequest) async throws -> ProviderHTTPResponse {
    do {
      let (data, response) = try await session.data(for: request)
      guard let response = response as? HTTPURLResponse else { throw ProviderError.invalidResponse }
      return .init(statusCode: response.statusCode, headers: Self.headers(response), data: data)
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as ProviderError {
      throw error
    } catch {
      throw ProviderError.transport(message: error.localizedDescription, completionUnknown: true)
    }
  }

  public func stream(for request: URLRequest) async throws -> ProviderHTTPByteStream {
    #if canImport(Darwin)
      do {
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else {
          throw ProviderError.invalidResponse
        }
        let chunks = AsyncThrowingStream<Data, Error> { continuation in
          let task = Task {
            var pending: [UInt8] = []
            do {
              for try await byte in bytes {
                try Task.checkCancellation()
                pending.append(byte)
                if pending.count >= 1024 {
                  continuation.yield(Data(pending))
                  pending.removeAll(keepingCapacity: true)
                }
              }
              if !pending.isEmpty { continuation.yield(Data(pending)) }
              continuation.finish()
            } catch {
              continuation.finish(throwing: error)
            }
          }
          continuation.onTermination = { _ in task.cancel() }
        }
        return .init(
          statusCode: response.statusCode, headers: Self.headers(response), chunks: chunks)
      } catch is CancellationError {
        throw CancellationError()
      } catch let error as ProviderError {
        throw error
      } catch {
        throw ProviderError.transport(message: error.localizedDescription, completionUnknown: true)
      }
    #else
      let response = try await data(for: request)
      let chunks = AsyncThrowingStream<Data, Error> { continuation in
        continuation.yield(response.data)
        continuation.finish()
      }
      return .init(statusCode: response.statusCode, headers: response.headers, chunks: chunks)
    #endif
  }

  private static func headers(_ response: HTTPURLResponse) -> [String: String] {
    Dictionary(
      uniqueKeysWithValues: response.allHeaderFields.map {
        (String(describing: $0.key), String(describing: $0.value))
      })
  }
}

public enum ProviderHTTP {
  private static let forbiddenHeaders: Set<String> = [
    "authorization", "proxy-authorization", "host", "content-length", "connection",
    "cookie", "set-cookie", "transfer-encoding",
  ]

  public static func endpoint(
    baseURL: URL, path: String, allowsLocalHTTP: Bool = false
  ) throws -> URL {
    try validateBaseURL(baseURL, allowsLocalHTTP: allowsLocalHTTP)
    let relative = path.hasPrefix("/") ? String(path.dropFirst()) : path
    return baseURL.appendingPathComponent(relative)
  }

  public static func validateBaseURL(_ baseURL: URL, allowsLocalHTTP: Bool = false) throws {
    guard baseURL.user == nil, baseURL.password == nil, let host = baseURL.host else {
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
    let value = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    if value == "localhost" || value == "::1" || value.hasSuffix(".local") { return true }
    if !value.contains(".") && !value.contains(":") { return true }
    if value.hasPrefix("fe80:") || value.hasPrefix("fc") || value.hasPrefix("fd") { return true }
    let parts = value.split(separator: ".").compactMap { Int($0) }
    guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
    if parts[0] == 10 || parts[0] == 127 { return true }
    if parts[0] == 169 && parts[1] == 254 { return true }
    if parts[0] == 192 && parts[1] == 168 { return true }
    if parts[0] == 172 && (16...31).contains(parts[1]) { return true }
    return false
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

    let normalizedSecret = secret?.trimmingCharacters(in: .whitespacesAndNewlines)
    switch authentication {
    case .bearer:
      if let normalizedSecret, !normalizedSecret.isEmpty {
        request.setValue("Bearer \(normalizedSecret)", forHTTPHeaderField: "Authorization")
      }
    case .header(let name):
      guard !Self.isForbiddenCustomHeader(name) else { throw ProviderError.unsafeHeader(name) }
      if let normalizedSecret, !normalizedSecret.isEmpty {
        request.setValue(normalizedSecret, forHTTPHeaderField: name)
      }
    case .none:
      break
    }

    for (name, value) in additionalHeaders {
      guard !Self.isForbiddenCustomHeader(name) else { throw ProviderError.unsafeHeader(name) }
      request.setValue(value, forHTTPHeaderField: name)
    }
    return request
  }

  public static func isForbiddenCustomHeader(_ name: String) -> Bool {
    forbiddenHeaders.contains(name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
  }
}
