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

  public init(session: URLSession = .shared) {
    self.session = session
  }

  public func data(for request: URLRequest) async throws -> ProviderHTTPResponse {
    do {
      let (data, response) = try await session.data(for: request)
      guard let response = response as? HTTPURLResponse else {
        throw ProviderError.invalidResponse
      }
      return ProviderHTTPResponse(
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
        let chunks = AsyncThrowingStream<Data, Error> { continuation in
          let task = Task {
            var pending: [UInt8] = []
            pending.reserveCapacity(1024)
            do {
              for try await byte in bytes {
                try Task.checkCancellation()
                pending.append(byte)
                if pending.count >= 1024 {
                  continuation.yield(Data(pending))
                  pending.removeAll(keepingCapacity: true)
                }
              }
              if !pending.isEmpty {
                continuation.yield(Data(pending))
              }
              continuation.finish()
            } catch is CancellationError {
              continuation.finish(throwing: CancellationError())
            } catch {
              continuation.finish(throwing: error)
            }
          }
          continuation.onTermination = { _ in
            task.cancel()
          }
        }
        return ProviderHTTPByteStream(
          statusCode: response.statusCode,
          headers: Self.headers(response),
          chunks: chunks
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
      return ProviderHTTPByteStream(
        statusCode: response.statusCode,
        headers: response.headers,
        chunks: chunks
      )
    #endif
  }

  private static func headers(_ response: HTTPURLResponse) -> [String: String] {
    var values: [String: String] = [:]
    for (key, value) in response.allHeaderFields {
      values[String(describing: key)] = String(describing: value)
    }
    return values
  }
}

public enum ProviderHTTP {
  private static let forbiddenHeaders: Set<String> = [
    "authorization", "proxy-authorization", "host", "content-length",
    "connection", "cookie", "set-cookie", "transfer-encoding",
  ]

  public static func endpoint(baseURL: URL, path: String) throws -> URL {
    guard baseURL.scheme?.lowercased() == "https" else {
      throw ProviderError.invalidBaseURL
    }
    let relative = path.hasPrefix("/") ? String(path.dropFirst()) : path
    return baseURL.appendingPathComponent(relative)
  }

  public static func makeRequest(
    url: URL,
    method: String,
    apiKey: String?,
    additionalHeaders: [String: String] = [:]
  ) throws -> URLRequest {
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.timeoutInterval = 120
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    if let apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines),
      !apiKey.isEmpty
    {
      request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    }

    for (name, value) in additionalHeaders {
      let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      guard !forbiddenHeaders.contains(normalized) else {
        throw ProviderError.unsafeHeader(name)
      }
      request.setValue(value, forHTTPHeaderField: name)
    }
    return request
  }
}
