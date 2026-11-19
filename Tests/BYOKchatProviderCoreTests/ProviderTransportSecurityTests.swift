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

@Test func localNetworkHostValidationCoversLANLocalUnqualifiedAndRejectsPublic() throws {
  #expect(ProviderHTTP.isPrivateNetworkHost("192.168.1.42"))
  #expect(ProviderHTTP.isPrivateNetworkHost("10.0.0.5"))
  #expect(ProviderHTTP.isPrivateNetworkHost("172.16.0.2"))
  #expect(ProviderHTTP.isPrivateNetworkHost("100.64.0.1"))
  #expect(ProviderHTTP.isPrivateNetworkHost("127.0.0.1"))
  #expect(ProviderHTTP.isPrivateNetworkHost("localhost"))
  #expect(ProviderHTTP.isPrivateNetworkHost("macbook.local"))
  #expect(ProviderHTTP.isPrivateNetworkHost("homelab"))
  #expect(ProviderHTTP.isPrivateNetworkHost("my-studio-1"))

  #expect(!ProviderHTTP.isPrivateNetworkHost("example.com"))
  #expect(!ProviderHTTP.isPrivateNetworkHost("api.openai.com"))
  #expect(!ProviderHTTP.isPrivateNetworkHost("8.8.8.8"))
  #expect(!ProviderHTTP.isPrivateNetworkHost("134744072"))
  #expect(!ProviderHTTP.isPrivateNetworkHost("-badhost"))

  try ProviderHTTP.validateBaseURL(
    try #require(URL(string: "http://macbook.local:11434/v1")),
    allowsLocalHTTP: true
  )
  try ProviderHTTP.validateBaseURL(
    try #require(URL(string: "http://homelab:1234/v1")),
    allowsLocalHTTP: true
  )
  try ProviderHTTP.validateBaseURL(
    try #require(URL(string: "https://ollama.example.com/v1")),
    allowsLocalHTTP: true
  )
  #expect(throws: ProviderError.self) {
    try ProviderHTTP.validateBaseURL(
      try #require(URL(string: "http://ollama.example.com/v1")),
      allowsLocalHTTP: true
    )
  }
}

@Test func loopbackHostDetectionIdentifiesLocalDeviceAddresses() {
  #expect(ProviderHTTP.isLoopbackHost("localhost"))
  #expect(ProviderHTTP.isLoopbackHost("sub.localhost"))
  #expect(ProviderHTTP.isLoopbackHost("127.0.0.1"))
  #expect(ProviderHTTP.isLoopbackHost("::1"))
  #expect(ProviderHTTP.isLoopbackHost("[::1]"))

  #expect(!ProviderHTTP.isLoopbackHost("192.168.1.20"))
  #expect(!ProviderHTTP.isLoopbackHost("macbook.local"))
  #expect(!ProviderHTTP.isLoopbackHost("homelab"))
}

@Test func localProviderBaseURLAutoAppendsV1WhenMissing() throws {
  #expect(
    ProviderKind.ollama.normalizedBaseURL(try #require(URL(string: "http://192.168.1.20:11434")))
      .absoluteString == "http://192.168.1.20:11434/v1"
  )
  #expect(
    ProviderKind.ollama.normalizedBaseURL(try #require(URL(string: "http://192.168.1.20:11434/")))
      .absoluteString == "http://192.168.1.20:11434/v1"
  )
  #expect(
    ProviderKind.lmStudio.normalizedBaseURL(try #require(URL(string: "http://macbook.local:1234")))
      .absoluteString == "http://macbook.local:1234/v1"
  )
  #expect(
    ProviderKind.lmStudio.normalizedBaseURL(
      try #require(URL(string: "http://macbook.local:1234/v1/"))
    ).absoluteString == "http://macbook.local:1234/v1"
  )
  #expect(
    ProviderKind.ollama.normalizedBaseURL(
      try #require(URL(string: "https://proxy.example.com/api"))
    ).absoluteString == "https://proxy.example.com/api"
  )
  #expect(
    ProviderKind.openAICompatible.normalizedBaseURL(
      try #require(URL(string: "http://192.168.1.20:8080"))
    ).absoluteString == "http://192.168.1.20:8080"
  )
}
