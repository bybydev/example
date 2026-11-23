import Foundation
import Testing

@testable import BYOKchatProviderCore

private actor StubCatalogTransport: ProviderHTTPTransport {
  struct RecordedRequest: Sendable {
    var url: URL?
    var ifNoneMatch: String?
  }

  private var responses: [Result<ProviderHTTPResponse, Error>]
  private(set) var recordedRequests: [RecordedRequest] = []

  init(responses: [Result<ProviderHTTPResponse, Error>]) {
    self.responses = responses
  }

  func data(for request: URLRequest) async throws -> ProviderHTTPResponse {
    recordedRequests.append(
      RecordedRequest(
        url: request.url,
        ifNoneMatch: request.value(forHTTPHeaderField: "If-None-Match")
      )
    )
    guard !responses.isEmpty else {
      throw ProviderError.transport(message: "No stubbed response.", completionUnknown: true)
    }
    return try responses.removeFirst().get()
  }

  func stream(for request: URLRequest) async throws -> ProviderHTTPByteStream {
    throw ProviderError.invalidResponse
  }
}

@Suite("Two-layer model catalog", .serialized)
struct ModelCatalogTests {
  @Test("Bundled Layer 1 catalog decodes and powers seeds, reasoning, and pricing")
  func bundledCatalogBaseline() throws {
    ModelCatalogRegistry.resetToBundled()
    let bundled = try #require(ModelCatalog.bundled)
    #expect(bundled.schemaVersion == ModelCatalog.supportedSchemaVersion)
    #expect(bundled.revision > 0)
    #expect(!ProviderKind.openai.seedModels.isEmpty)
    #expect(!ProviderKind.anthropic.seedModels.isEmpty)
    #expect(!ProviderKind.gemini.seedModels.isEmpty)

    let openAI = ProviderAccount(kind: .openai, id: "oa", providerID: "openai", label: "OpenAI")
    let pricing = try #require(ModelPriceResolver.resolve(account: openAI, modelID: "gpt-6.2-astra", model: nil))
    #expect(pricing.source == "bundledCatalog")
    #expect(pricing.version == bundled.version)
  }

  @Test("Layer 2 remote refresh activates newer revision, caches ETag, and handles 304")
  func remoteRefreshAndConditionalETag() async throws {
    let bundled = try #require(ModelCatalog.bundled)
    var remote = bundled
    remote.revision = bundled.revision + 10
    remote.version = "2026-12-01"
    remote.providers["openai"]?.models.insert(
      ModelCatalog.ModelEntry(
        id: "gpt-6.3-nova",
        displayName: "GPT-6.3 Nova",
        contextWindow: 2_000_000,
        contextWindowKind: .combined,
        maxOutputTokens: 256_000,
        inputModalities: ["text", "image", "file"],
        outputModalities: ["text"],
        supportedParameters: ["max_output_tokens", "reasoning", "tools"]
      ),
      at: 0
    )
    let encodedRemote = try JSONEncoder().encode(remote)

    let persistence = InMemoryModelCatalogPersistence()
    let transport = StubCatalogTransport(responses: [
      .success(
        ProviderHTTPResponse(
          statusCode: 200,
          headers: ["ETag": "\"rev-next\""],
          data: encodedRemote
        )
      ),
      .success(
        ProviderHTTPResponse(
          statusCode: 304,
          headers: ["ETag": "\"rev-next\""],
          data: Data()
        )
      ),
    ])

    let store = ModelCatalogStore(
      remoteURL: URL(string: "https://spokiostudio.com/byokchat/catalog/v1/models.json")!,
      persistence: persistence,
      transport: transport,
      activatesGlobally: false
    )

    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let first = try await store.refresh(force: true, now: t0)
    #expect(first == .updated(revision: remote.revision, version: "2026-12-01"))

    let status = await store.status()
    #expect(status.source == .remote)
    #expect(status.revision == remote.revision)
    #expect(status.version == "2026-12-01")
    #expect(await store.activeCatalog()?.seedModels(for: .openai).first?.id == "gpt-6.3-nova")

    // Second refresh within TTL returns .upToDate without hitting the network.
    let throttled = try await store.refresh(force: false, now: t0.addingTimeInterval(60))
    #expect(throttled == .upToDate)
    #expect(await transport.recordedRequests.count == 1)

    // Forced refresh sends If-None-Match and keeps the cached remote snapshot on 304.
    let second = try await store.refresh(force: true, now: t0.addingTimeInterval(120))
    #expect(second == .notModified)
    let requests = await transport.recordedRequests
    #expect(requests.count == 2)
    #expect(requests[1].ifNoneMatch == "\"rev-next\"")
    #expect(await store.status().source == .remote)
  }

  @Test("Remote catalog older than or equal to bundled is ignored")
  func ignoresOlderOrEqualRemoteRevision() async throws {
    let bundled = try #require(ModelCatalog.bundled)
    let encodedSame = try JSONEncoder().encode(bundled)

    let persistence = InMemoryModelCatalogPersistence()
    let transport = StubCatalogTransport(responses: [
      .success(ProviderHTTPResponse(statusCode: 200, headers: [:], data: encodedSame))
    ])
    let store = ModelCatalogStore(
      persistence: persistence,
      transport: transport,
      activatesGlobally: false
    )

    let result = try await store.refresh(force: true)
    #expect(
      result
        == .ignoredOlderThanBundled(
          remoteRevision: bundled.revision,
          bundledRevision: bundled.revision
        )
    )
    #expect(await store.status().source == .bundled)
    #expect(try await persistence.loadCatalogData() == nil)
  }

  @Test("Invalid remote payload is rejected and never overwrites Layer 1")
  func rejectsInvalidRemoteCatalog() async throws {
    let badJSON = Data(#"{"schemaVersion":99,"revision":9999999999,"version":"future","generatedAt":"2030-01-01T00:00:00Z","providers":{},"pricing":{"currency":"USD","units":"USD per 1000000 tokens","entries":[]}}"#.utf8)
    let persistence = InMemoryModelCatalogPersistence()
    let transport = StubCatalogTransport(responses: [
      .success(ProviderHTTPResponse(statusCode: 200, headers: [:], data: badJSON))
    ])
    let store = ModelCatalogStore(
      persistence: persistence,
      transport: transport,
      activatesGlobally: false
    )

    await #expect(throws: ModelCatalogError.invalidCatalog) {
      _ = try await store.refresh(force: true)
    }
    #expect(await store.status().source == .bundled)
    #expect(try await persistence.loadCatalogData() == nil)
  }

  @Test("Cached Layer 2 catalog loads from disk on startup and clears if bundled is newer")
  func loadsCachedRemoteAndEvictsStaleCache() async throws {
    let bundled = try #require(ModelCatalog.bundled)
    var remote = bundled
    remote.revision = bundled.revision + 5
    remote.version = "2026-12-05"
    let remoteData = try JSONEncoder().encode(remote)

    let persistence = InMemoryModelCatalogPersistence(
      catalogData: remoteData,
      metadata: ModelCatalogMetadata(
        etag: "\"v5\"",
        cachedRevision: remote.revision,
        cachedVersion: remote.version
      )
    )

    let store = ModelCatalogStore(
      persistence: persistence,
      activatesGlobally: false
    )
    await store.load()
    #expect(await store.status().source == .remote)
    #expect(await store.status().revision == remote.revision)

    // Simulate an App Store upgrade whose bundled revision is newer than the cached remote revision.
    var newerBundled = bundled
    newerBundled.revision = remote.revision + 1
    newerBundled.version = "2026-12-10"
    let upgradedStore = ModelCatalogStore(
      persistence: persistence,
      activatesGlobally: false,
      bundledSnapshot: ModelCatalogSnapshot(source: .bundled, catalog: newerBundled)
    )
    await upgradedStore.load()
    #expect(await upgradedStore.status().source == .bundled)
    #expect(await upgradedStore.status().revision == newerBundled.revision)
    #expect(try await persistence.loadCatalogData() == nil)
  }

  @Test("Global registry activation updates pricing source to remoteCatalog and resets cleanly")
  func globalActivationUpdatesResolvers() throws {
    defer { ModelCatalogRegistry.resetToBundled() }
    let bundled = try #require(ModelCatalog.bundled)
    var remote = bundled
    remote.revision = bundled.revision + 1
    remote.version = "2026-12-02"
    remote.pricing.entries.append(
      ModelPricingCatalog.Entry(
        provider: "openai",
        modelIDs: ["gpt-6.9-test"],
        sourceURL: "https://developers.openai.com/api/docs/pricing",
        verifiedAt: "2026-12-02",
        rates: ModelPricingRates(input: "3", output: "15")
      )
    )

    let activated = ModelCatalogRegistry.activate(
      ModelCatalogSnapshot(source: .remote, catalog: remote)
    )
    #expect(activated)

    let openAI = ProviderAccount(kind: .openai, id: "oa", providerID: "openai", label: "OpenAI")
    let pricing = try #require(
      ModelPriceResolver.resolve(account: openAI, modelID: "gpt-6.9-test", model: nil)
    )
    #expect(pricing.source == "remoteCatalog")
    #expect(pricing.version == "2026-12-02")
    #expect(pricing.rates.input == "3")

    ModelCatalogRegistry.resetToBundled()
    #expect(ModelPriceResolver.resolve(account: openAI, modelID: "gpt-6.9-test", model: nil) == nil)
  }
}
