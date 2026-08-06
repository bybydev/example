import Foundation

extension ProviderHTTP {
  @available(*, deprecated, message: "Pass allowsLocalHTTP explicitly from the provider definition.")
  public static func endpoint(baseURL: URL, path: String) throws -> URL {
    try endpoint(baseURL: baseURL, path: path, allowsLocalHTTP: false)
  }

  @available(*, deprecated, message: "Pass allowsLocalHTTP explicitly from the provider definition.")
  public static func validateBaseURL(_ baseURL: URL) throws {
    try validateBaseURL(baseURL, allowsLocalHTTP: false)
  }
}
