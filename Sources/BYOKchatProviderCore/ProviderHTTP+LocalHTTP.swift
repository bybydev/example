import Foundation

extension ProviderHTTP {
  public static func endpoint(baseURL: URL, path: String) throws -> URL {
    let allowLocal =
      baseURL.scheme?.lowercased() == "http"
      && baseURL.host.map(isPrivateNetworkHost) == true
    return try endpoint(baseURL: baseURL, path: path, allowsLocalHTTP: allowLocal)
  }

  public static func validateBaseURL(_ baseURL: URL) throws {
    let allowLocal =
      baseURL.scheme?.lowercased() == "http"
      && baseURL.host.map(isPrivateNetworkHost) == true
    try validateBaseURL(baseURL, allowsLocalHTTP: allowLocal)
  }
}
