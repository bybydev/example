import Foundation

extension ProviderDefinition {
  public var allowsLocalHTTP: Bool {
    if let kind, kind.allowsLocalHTTP {
      return true
    }
    guard defaultBaseURL.scheme?.lowercased() == "http", let host = defaultBaseURL.host else {
      return false
    }
    return ProviderHTTP.isPrivateNetworkHost(host)
  }

  public var requiresCredential: Bool {
    guard authentication != .none else { return false }
    if let kind {
      return kind.requiresCredential
    }
    return isBuiltIn
  }

  public init(
    id: ProviderID,
    displayName: String,
    apiFamily: ProviderAPIFamily = .openAIChatCompletions,
    behavior: ProviderBehaviorID,
    defaultBaseURL: URL,
    chatCompletionsPath: String = "/chat/completions",
    modelsPath: String? = "/models",
    authentication: ProviderAuthentication = .bearer,
    seedModels: [ProviderModel] = [],
    allowsLocalHTTP: Bool,
    isBuiltIn: Bool = false
  ) {
    let resolvedURL: URL
    if defaultBaseURL.scheme?.lowercased() == "http" && !allowsLocalHTTP {
      resolvedURL = URL(string: "http://invalid.invalid")!
    } else {
      resolvedURL = defaultBaseURL
    }
    self.init(
      id: id,
      displayName: displayName,
      apiFamily: apiFamily,
      behavior: behavior,
      defaultBaseURL: resolvedURL,
      chatCompletionsPath: chatCompletionsPath,
      modelsPath: modelsPath,
      authentication: authentication,
      seedModels: seedModels,
      isBuiltIn: isBuiltIn
    )
  }
}
