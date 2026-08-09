import Foundation
import Testing

@testable import BYOKchatProviderCore

@Test func privateHTTPProvidersRequirePrivateHosts() throws {
  let local = try CustomProviderFactory.makeOpenAICompatible(
    id: "ollama",
    displayName: "Ollama",
    baseURL: URL(string: "http://192.168.1.20:11434/v1")!,
    authentication: .none,
    seedModelIDs: ["qwen3"],
    allowsLocalHTTP: true
  )
  #expect(local.allowsLocalHTTP)

  #expect(throws: ProviderError.self) {
    _ = try CustomProviderFactory.makeOpenAICompatible(
      id: "unsafe",
      displayName: "Unsafe",
      baseURL: URL(string: "http://example.com/v1")!,
      allowsLocalHTTP: true
    )
  }
}

@Test func providerRedirectsAreRestrictedToSameOrigin() throws {
  let source = try #require(URL(string: "http://192.168.1.20:11434/v1/chat/completions"))
  let sameOrigin = try #require(URL(string: "http://192.168.1.20:11434/v1/redirected"))
  let changedPort = try #require(URL(string: "http://192.168.1.20:8080/v1/redirected"))
  let changedHost = try #require(URL(string: "http://192.168.1.21:11434/v1/redirected"))
  let upgradedScheme = try #require(URL(string: "https://192.168.1.20:11434/v1/redirected"))

  #expect(ProviderHTTP.isSameOriginRedirect(from: source, to: sameOrigin))
  #expect(!ProviderHTTP.isSameOriginRedirect(from: source, to: changedPort))
  #expect(!ProviderHTTP.isSameOriginRedirect(from: source, to: changedHost))
  #expect(!ProviderHTTP.isSameOriginRedirect(from: source, to: upgradedScheme))
}
