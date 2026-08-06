import Foundation

public enum ProviderError: Error, LocalizedError, Sendable, Equatable {
  case invalidDefinition(String)
  case duplicateProvider(ProviderID)
  case providerNotFound(ProviderID)
  case unsupportedAPIFamily(String)
  case invalidBaseURL
  case invalidModel
  case invalidMessages
  case missingCredential(ProviderID)
  case unsafeHeader(String)
  case authenticationFailed
  case permissionDenied
  case insufficientCredits
  case rateLimited(retryAfter: String?)
  case modelUnavailable
  case invalidEndpoint
  case invalidRequest(String)
  case provider(status: Int, message: String)
  case midStreamProvider(code: String?, message: String)
  case transport(message: String, completionUnknown: Bool)
  case invalidResponse
  case emptyOutput
  case prematureStreamEnd

  public var errorDescription: String? {
    switch self {
    case .invalidDefinition(let message): return message
    case .duplicateProvider(let id): return "Duplicate provider ID: \(id.rawValue)"
    case .providerNotFound(let id): return "Provider not found: \(id.rawValue)"
    case .unsupportedAPIFamily(let family): return "Unsupported API family: \(family)"
    case .invalidBaseURL: return "The provider base URL is invalid."
    case .invalidModel: return "A model ID is required."
    case .invalidMessages: return "At least one non-empty message is required."
    case .missingCredential: return "An API key is required for this provider account."
    case .unsafeHeader(let name): return "The custom header \(name) is not allowed."
    case .authenticationFailed: return "The provider rejected the API key."
    case .permissionDenied: return "The provider denied this request."
    case .insufficientCredits: return "The provider account has insufficient credit or quota."
    case .rateLimited: return "The provider rate limited this request."
    case .modelUnavailable: return "The selected model is unavailable."
    case .invalidEndpoint: return "The provider endpoint could not be found."
    case .invalidRequest(let message): return message
    case .provider(_, let message): return message
    case .midStreamProvider(_, let message): return message
    case .transport(let message, _): return message
    case .invalidResponse: return "The provider returned an invalid response."
    case .emptyOutput: return "The provider returned an empty response."
    case .prematureStreamEnd: return "The provider stream ended before completion."
    }
  }
}
