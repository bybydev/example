import Foundation
import Testing

@testable import BYOKchatProviderCore

@Test(arguments: 0...5)
func changingAccountPricingContextInvalidatesOnlyItsDiscoveryRates(change: Int) async throws {
  let persistence = InMemoryProviderWorkspacePersistence()
  let workspace = ProviderWorkspaceStore(persistence: persistence)
  try await workspace.load()
  let original = pricingContextAccount()
  try await workspace.upsertAccount(original)
  var other = original
  other.id = "other-pricing-account"
  try await workspace.upsertAccount(other)
  let model = pricingContextModel()
  for account in [original, other] {
    try await workspace.addManualModel(model, for: account.id)
  }
  try await workspace.setFavorite(true, modelID: model.id, accountID: original.id)
  try await workspace.setHidden(true, modelID: model.id, accountID: original.id)

  var updated = original
  switch change {
  case 0: updated.baseURLOverride = URL(string: "https://new.example/v1")
  case 1: updated.additionalHeaders = ["X-Account": "new-tenant"]
  case 2: updated.metadata = ["region": "new-region"]
  case 3: updated.modelsPath = "/other-models"
  case 4: updated.chatCompletionsPath = "/other-chat"
  default: updated.authChoice = .header(name: "X-API-Key")
  }
  try await workspace.upsertAccount(updated)

  // The invalidation must survive relaunch, without deleting selected models
  // or affecting another account's rates.
  let restored = ProviderWorkspaceStore(persistence: persistence)
  try await restored.load()
  let records = await restored.modelRecords(for: original.id, includeHidden: true)
  let retained = try #require(records.first)
  #expect(retained.isManual && retained.isFavorite && retained.isHidden)
  #expect(retained.model.id == model.id)
  #expect(retained.model.contextWindow == model.contextWindow)
  #expect(retained.model.promptPricePerToken == nil)
  #expect(retained.model.completionPricePerToken == nil)
  #expect(retained.model.cachedInputPricePerToken == nil)
  #expect(retained.model.cacheWritePricePerToken == nil)
  #expect(retained.model.hasAdditionalPricingDimensions == nil)
  #expect(ModelPriceResolver.resolve(account: updated, modelID: model.id, model: retained.model) == nil)
  let otherRecords = await restored.modelRecords(for: other.id)
  #expect(otherRecords.first?.model == model)
}

@Test func oldDiscoveryCannotRestorePricesAfterAnEndpointEdit() async throws {
  let workspace = ProviderWorkspaceStore(persistence: InMemoryProviderWorkspacePersistence())
  try await workspace.load()
  let original = pricingContextAccount()
  let model = pricingContextModel()
  try await workspace.upsertAccount(original)
  try await workspace.addManualModel(model, for: original.id)
  var updated = original
  updated.baseURLOverride = URL(string: "https://new.example/v1")
  try await workspace.upsertAccount(updated)
  try await workspace.mergeModels([model], for: original.id, expectedAccount: original)
  let staleResult = await workspace.modelRecords(for: original.id)
  #expect(staleResult.first?.model.promptPricePerToken == nil)

  var fresh = model
  fresh.promptPricePerToken = "0.000003"
  try await workspace.mergeModels([fresh], for: original.id, expectedAccount: updated)
  updated.label = "Renamed account"
  updated.defaultModelID = model.id
  updated.isEnabled = false
  try await workspace.upsertAccount(updated)
  let renamed = await workspace.modelRecords(for: original.id)
  #expect(renamed.first?.model.promptPricePerToken == fresh.promptPricePerToken)
  #expect(renamed.first?.model.completionPricePerToken == fresh.completionPricePerToken)
}

private func pricingContextAccount() -> ProviderAccount {
  ProviderAccount(kind: .openAICompatible, id: "pricing-context-account", providerID: "custom-pricing",
    label: "Pricing context", baseURLOverride: URL(string: "https://old.example/v1"))
}

private func pricingContextModel() -> ProviderModel {
  ProviderModel(providerID: "custom-pricing", id: "priced-model", displayName: "Priced model",
    contextWindow: 16_384, maxOutputTokens: 1_024,
    promptPricePerToken: "0.000001", completionPricePerToken: "0.000002",
    cachedInputPricePerToken: "0.0000001", cacheWritePricePerToken: "0.00000125",
    hasAdditionalPricingDimensions: true)
}
