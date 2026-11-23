import AppFoundation
import BYOKchatProviderCore
import Foundation
import SwiftUI

#if DEBUG
struct BYOKDeveloperToolsView: View {
  let purchases: BYOKPurchaseStore
  var restartApp: () -> Void = {}

  @Environment(AppModel.self) private var model
  @AppStorage("byokchat.onboarding.completed.v1") private var hasCompletedOnboarding = true

  var body: some View {
    FoundationDeveloperView(
      purchaseManager: purchases.manager,
      configuration: configuration
    )
    .environment(purchases.manager)
    .task {
      _ = await model.chats.refreshSearchIndexStatus()
    }
    .onChange(of: purchases.manager.isUsingSimulatedPurchases) { _, enabled in
      UserDefaults.standard.set(enabled, forKey: BYOKPurchaseStore.simulatedModeKey)
    }
  }

  private var configuration: FoundationDeveloperConfiguration {
    FoundationDeveloperConfiguration(
      replays: [
        FoundationDeveloperReplay(
          id: "paywall",
          title: "Paywall",
          systemImage: "rectangle.portrait.and.arrow.forward"
        ) { _ in
          ProPaywallView(
            purchases: purchases.manager,
            configuration: BYOKPurchaseStore.paywallConfiguration,
            initialSelectedProductID: BYOKPurchaseStore.yearlyProductID
          )
          .environment(purchases.manager)
        },
        FoundationDeveloperReplay(
          id: "provider-upsell",
          title: "Connection Limit Upsell",
          systemImage: "crown"
        ) { _ in
          BYOKProUpsellFlow(feature: .providerAccounts)
            .environment(purchases.manager)
        },
        FoundationDeveloperReplay(
          id: "chat-search-upsell",
          title: "Chat Search Upsell",
          systemImage: "magnifyingglass"
        ) { _ in
          BYOKProUpsellFlow(feature: .chatSearch)
            .environment(purchases.manager)
        },
        FoundationDeveloperReplay(
          id: "onboarding",
          title: "Onboarding",
          systemImage: "rectangle.stack.fill",
          presentation: .fullScreen
        ) { close in
          BYOKOnboardingView {
            close()
          }
          .appFoundationTheme(model.themeManager)
        },
      ],
      resetOnboarding: FoundationDeveloperAction(
        id: "reset-onboarding",
        title: "Reset Onboarding",
        systemImage: "arrow.counterclockwise",
        role: .destructive
      ) {
        hasCompletedOnboarding = false
      },
      additionalSections: [
        FoundationDeveloperSection(
          id: "byokchat",
          title: "BYOKchat",
          items: [
            .value(
              FoundationDeveloperValue(
                id: "connections",
                title: "Connections",
                value: { String(model.providers.accounts.count) }
              )
            ),
            .value(
              FoundationDeveloperValue(
                id: "mcp-servers",
                title: "MCP servers",
                value: { String(model.mcp.servers.count) }
              )
            ),
            .value(
              FoundationDeveloperValue(
                id: "model-catalog-status",
                title: "Model catalog",
                value: {
                  guard let status = model.providers.modelCatalogStatus else { return "Unavailable" }
                  let layer = status.source == .remote ? "Remote" : "Bundled"
                  return "\(layer) · \(status.version)"
                }
              )
            ),
            .value(
              FoundationDeveloperValue(
                id: "full-text-search-status",
                title: "Full-text search",
                value: {
                  guard let status = model.chats.searchIndexStatus else {
                    return purchases.hasPro ? "Checking…" : "Disabled (Free)"
                  }
                  if !status.isEnabled {
                    return status.statistics.databaseExists ? "Paused (Free)" : "Disabled (Free)"
                  }
                  return "\(status.phase.displayTitle) · \(status.statistics.indexedConversationCount)/\(status.eligibleConversationCount)"
                }
              )
            ),
            .destination(
              FoundationDeveloperDestination(
                id: "full-text-search",
                title: "Full Text Search",
                systemImage: "magnifyingglass"
              ) {
                FullTextSearchDeveloperView(purchases: purchases)
              }
            ),
            .destination(
              FoundationDeveloperDestination(
                id: "model-catalog",
                title: "Model Catalog",
                systemImage: "square.stack.3d.up"
              ) {
                ModelCatalogDeveloperView()
              }
            ),
            .destination(
              FoundationDeveloperDestination(
                id: "provider-simulator",
                title: "AI Provider Simulator",
                systemImage: "server.rack"
              ) {
                ProviderSimulatorDeveloperView()
              }
            ),
            .destination(
              FoundationDeveloperDestination(
                id: "provider-console",
                title: "Provider Console",
                systemImage: "terminal"
              ) {
                ProviderConsoleView(model: model.providers)
              }
            ),
            .destination(
              FoundationDeveloperDestination(
                id: "seed-data",
                title: "Seed Data",
                systemImage: "tray.and.arrow.down.fill"
              ) {
                SeedDataDeveloperView(restartApp: restartApp)
              }
            ),
            .destination(
              FoundationDeveloperDestination(
                id: "screenshot-studio",
                title: "Screenshot Studio",
                systemImage: "photo.stack.fill"
              ) {
                BYOKScreenshotStudioView()
                  .navigationTitle("Screenshot Studio")
                  .navigationBarTitleDisplayMode(.inline)
              }
            ),
          ]
        )
      ]
    )
  }
}

private enum SimulatorConfigurationConstants {
  static let sourceKey = "configurationSource"
  static let sourceValue = "ai-provider-simulator"
  static let manifestURLKey = "simulatorManifestURL"
  static let versionKey = "simulatorVersion"
  static let schemaVersionKey = "simulatorSchemaVersion"
  static let mcpName = "AI Provider Simulator"
  static let defaultManifestURL = "https://ai-provider-simulator.hoangbkit.workers.dev/manifest.json"
}

private struct SimulatorManifest: Decodable {
  struct Authentication: Decodable {
    var providerEndpointsProtected: Bool
  }

  struct Provider: Decodable {
    var id: String
    var name: String
    var baseURL: URL
    var defaultModel: String
  }

  struct MCP: Decodable {
    var url: URL
    var protected: Bool
  }

  var schemaVersion: Int
  var service: String
  var version: String
  var authentication: Authentication
  var mcp: MCP
  var providers: [Provider]
}

private struct SimulatorProviderConfiguration {
  var providerID: ProviderID
  var label: String
  var baseURL: URL
  var defaultModelID: ModelID
  var metadata: [String: String]
}

private struct ProviderSimulatorDeveloperView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.appFoundationTheme) private var theme
  @AppStorage("byokchat.dev.simulator.manifestURL") private var simulatorManifestURL = SimulatorConfigurationConstants.defaultManifestURL
  @AppStorage("byokchat.dev.simulator.mcpServerID") private var simulatorMCPServerID = ""

  @State private var simulatorEnabled = false
  @State private var simulatorAPIKey = ""
  @State private var simulatorBusy = false
  @State private var simulatorStatus: String?
  @State private var simulatorError: String?

  var body: some View {
    Form {
      Section {
        Toggle(
          "AI Provider Simulator",
          isOn: Binding(
            get: { simulatorEnabled },
            set: { enabled in
              simulatorEnabled = enabled
              Task { @MainActor in
                await setSimulatorEnabled(enabled)
              }
            }
          )
        )
        .disabled(simulatorBusy)

        TextField(
          "Manifest URL",
          text: $simulatorManifestURL,
          prompt: Text("https://…/manifest.json")
        )
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .keyboardType(.URL)

        SecureField("Simulator API Key", text: $simulatorAPIKey)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()

        if simulatorBusy {
          HStack(spacing: 10) {
            ProgressView()
            Text(simulatorEnabled ? "Configuring simulator…" : "Removing simulator configuration…")
              .font(.footnote)
              .foregroundStyle(theme.secondaryForegroundColor)
          }
        } else if let simulatorStatus {
          Text(simulatorStatus)
            .font(.footnote)
            .foregroundStyle(theme.secondaryForegroundColor)
        }

        if let simulatorError {
          Text(simulatorError)
            .font(.footnote)
            .foregroundStyle(.red)
        }
      } header: {
        Text("Simulator")
      } footer: {
        Text("Simulator mode creates managed provider accounts and an MCP server from the simulator manifest. Turning it off removes only those generated entries and their credentials.")
      }
      .listRowBackground(theme.surfaceColor)
    }
    .scrollContentBackground(.hidden)
    .foregroundStyle(theme.primaryForegroundColor)
    .background(AppThemeBackground(theme: theme))
    .navigationTitle("Provider Simulator")
    .navigationBarTitleDisplayMode(.inline)
    .onAppear {
      synchronizeSimulatorToggle()
    }
  }

  @MainActor
  private func setSimulatorEnabled(_ enabled: Bool) async {
    simulatorBusy = true
    simulatorError = nil
    simulatorStatus = nil
    defer { simulatorBusy = false }

    if enabled {
      await enableSimulator()
    } else {
      await disableSimulator()
    }
  }

  @MainActor
  private func enableSimulator() async {
    let trimmedURL = simulatorManifestURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let manifestURL = URL(string: trimmedURL), !trimmedURL.isEmpty else {
      simulatorEnabled = false
      simulatorError = "Enter the simulator manifest URL first."
      return
    }

    do {
      let (data, response) = try await URLSession.shared.data(from: manifestURL)
      if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
        throw SimulatorConfigurationError.manifestHTTPStatus(http.statusCode)
      }

      let manifest = try JSONDecoder().decode(SimulatorManifest.self, from: data)
      let trimmedKey = simulatorAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
      if (manifest.authentication.providerEndpointsProtected || manifest.mcp.protected), trimmedKey.isEmpty {
        throw SimulatorConfigurationError.missingAPIKey
      }

      let providerCredential = trimmedKey.isEmpty ? "simulator" : trimmedKey
      let providerConfigurations = manifest.providers.map { provider in
        SimulatorProviderConfiguration(
          providerID: ProviderID(rawValue: provider.id),
          label: "\(provider.name) Simulator",
          baseURL: provider.baseURL,
          defaultModelID: ModelID(rawValue: provider.defaultModel),
          metadata: [
            SimulatorConfigurationConstants.sourceKey: SimulatorConfigurationConstants.sourceValue,
            SimulatorConfigurationConstants.manifestURLKey: manifestURL.absoluteString,
            SimulatorConfigurationConstants.versionKey: manifest.version,
            SimulatorConfigurationConstants.schemaVersionKey: String(manifest.schemaVersion),
          ]
        )
      }

      let providerResult = await model.providers.configureSimulatorAccounts(
        providerConfigurations,
        credential: providerCredential
      )

      let storedServerID = simulatorMCPServerID.isEmpty
        ? nil
        : MCPServerID(rawValue: simulatorMCPServerID)
      guard
        let mcpServerID = await model.mcp.configureSimulatorServer(
          endpoint: manifest.mcp.url,
          credential: manifest.mcp.protected ? trimmedKey : nil,
          preferredServerID: storedServerID
        )
      else {
        simulatorEnabled = model.providers.hasSimulatorAccounts
        simulatorError = model.mcp.errorMessage ?? "Provider simulator accounts were created, but MCP setup failed."
        return
      }

      simulatorMCPServerID = mcpServerID.rawValue
      simulatorEnabled = true

      let skipped = max(0, manifest.providers.count - providerResult.configuredCount)
      if skipped == 0 {
        simulatorStatus = "Configured \(providerResult.configuredCount) provider accounts + MCP · manifest v\(manifest.schemaVersion)"
      } else {
        simulatorStatus = "Configured \(providerResult.configuredCount) provider accounts + MCP · skipped \(skipped) unsupported provider\(skipped == 1 ? "" : "s")"
      }
    } catch {
      synchronizeSimulatorToggle()
      simulatorError = error.localizedDescription
    }
  }

  @MainActor
  private func disableSimulator() async {
    await model.providers.clearSimulatorAccounts()

    let storedServerID = simulatorMCPServerID.isEmpty
      ? nil
      : MCPServerID(rawValue: simulatorMCPServerID)
    await model.mcp.clearSimulatorServer(preferredServerID: storedServerID)
    simulatorMCPServerID = ""

    synchronizeSimulatorToggle()
    if simulatorEnabled {
      simulatorError = "Some simulator configuration could not be removed."
    } else {
      simulatorStatus = "Simulator provider accounts and MCP server removed."
    }
  }

  @MainActor
  private func synchronizeSimulatorToggle() {
    let hasStoredMCP = !simulatorMCPServerID.isEmpty
      && model.mcp.servers.contains {
        $0.id.rawValue == simulatorMCPServerID
      }
    let hasNamedMCP = model.mcp.servers.contains {
      $0.name == SimulatorConfigurationConstants.mcpName
    }
    simulatorEnabled = model.providers.hasSimulatorAccounts || hasStoredMCP || hasNamedMCP
  }
}

private struct SimulatorProviderConfigurationResult {
  var configuredCount: Int
}

private extension ProviderManagementModel {
  var simulatorAccounts: [ProviderAccount] {
    accounts.filter {
      $0.metadata[SimulatorConfigurationConstants.sourceKey]
        == SimulatorConfigurationConstants.sourceValue
    }
  }

  var hasSimulatorAccounts: Bool {
    !simulatorAccounts.isEmpty
  }

  @MainActor
  func configureSimulatorAccounts(
    _ configurations: [SimulatorProviderConfiguration],
    credential: String
  ) async -> SimulatorProviderConfigurationResult {
    var configuredProviderIDs: Set<ProviderID> = []

    for configuration in configurations {
      guard provider(for: configuration.providerID) != nil else { continue }
      let kind = ProviderKind(providerID: configuration.providerID)

      let matches = simulatorAccounts.filter { $0.providerID == configuration.providerID }
      let succeeded: Bool

      if var existing = matches.first {
        existing.label = configuration.label
        existing.defaultModelID = configuration.defaultModelID
        succeeded = await updateAccount(
          existing,
          newCredential: credential,
          baseURL: configuration.baseURL.absoluteString,
          headers: [:],
          metadata: configuration.metadata
        )
      } else {
        succeeded = await createAccount(
          kind: kind,
          label: configuration.label,
          credential: credential,
          baseURL: configuration.baseURL.absoluteString,
          defaultModel: configuration.defaultModelID.rawValue,
          headers: [:],
          metadata: configuration.metadata
        )
      }

      guard succeeded else { continue }
      configuredProviderIDs.insert(configuration.providerID)

      for duplicate in matches.dropFirst() {
        await deleteAccount(duplicate.id)
      }

      if let configured = simulatorAccounts.first(where: {
        $0.providerID == configuration.providerID
      }), provider(for: configuration.providerID)?.modelsPath != nil {
        _ = await refreshModelsResult(accountID: configured.id)
      }
    }

    for stale in simulatorAccounts where !configuredProviderIDs.contains(stale.providerID) {
      await deleteAccount(stale.id)
    }

    return SimulatorProviderConfigurationResult(configuredCount: configuredProviderIDs.count)
  }

  @MainActor
  func clearSimulatorAccounts() async {
    for account in simulatorAccounts {
      await deleteAccount(account.id)
    }
  }
}

private extension MCPManagementModel {
  @MainActor
  func configureSimulatorServer(
    endpoint: URL,
    credential: String?,
    preferredServerID: MCPServerID?
  ) async -> MCPServerID? {
    let existing = preferredServerID.flatMap { preferredID in
      servers.first(where: { $0.id == preferredID })
    } ?? servers.first(where: {
      $0.name == SimulatorConfigurationConstants.mcpName
    })

    let authenticationKind: MCPAuthenticationKind = credential == nil ? .none : .bearer
    let saved = await saveServer(
      existing: existing,
      name: SimulatorConfigurationConstants.mcpName,
      endpoint: endpoint.absoluteString,
      authenticationKind: authenticationKind,
      authenticationHeader: "Authorization",
      credential: credential,
      additionalHeaders: [:],
      isEnabled: true
    )
    guard let saved else { return nil }
    await discoverSavedServer(saved)
    return saved.id
  }

  @MainActor
  func clearSimulatorServer(preferredServerID: MCPServerID?) async {
    if let preferredServerID,
      servers.contains(where: { $0.id == preferredServerID })
    {
      await deleteServer(preferredServerID)
      return
    }

    if let fallback = servers.first(where: {
      $0.name == SimulatorConfigurationConstants.mcpName
    }) {
      await deleteServer(fallback.id)
    }
  }
}

private enum SimulatorConfigurationError: LocalizedError {
  case manifestHTTPStatus(Int)
  case missingAPIKey

  var errorDescription: String? {
    switch self {
    case .manifestHTTPStatus(let status):
      "Simulator manifest request failed with HTTP \(status)."
    case .missingAPIKey:
      "This simulator deployment requires a Simulator API Key."
    }
  }
}

private struct ModelCatalogDeveloperView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.appFoundationTheme) private var theme

  @State private var isWorking = false
  @State private var actionStatus: String?
  @State private var actionError: String?
  @State private var cachedFileBytes: Int64?

  private var status: ModelCatalogStatus? {
    model.providers.modelCatalogStatus
  }

  private var activeSnapshot: ModelCatalogSnapshot? {
    _ = model.providers.modelCatalogRevision
    return ModelCatalogRegistry.current
  }

  private var bundledSnapshot: ModelCatalogSnapshot? {
    ModelCatalogRegistry.bundled
  }

  private struct ProviderSummary: Identifiable {
    var id: String { key }
    let key: String
    let models: [ModelCatalog.ModelEntry]
    let rules: [ModelCatalog.ReasoningRule]
    let pricingByModelID: [String: ModelPricingCatalog.Entry]
  }

  private var providerSummaries: [ProviderSummary] {
    guard let catalog = activeSnapshot?.catalog else { return [] }
    var pricingByProvider: [String: [String: ModelPricingCatalog.Entry]] = [:]
    for entry in catalog.pricing.entries {
      for modelID in entry.modelIDs {
        pricingByProvider[entry.provider, default: [:]][modelID] = entry
      }
    }
    return catalog.providers
      .map {
        ProviderSummary(
          key: $0.key,
          models: $0.value.models,
          rules: $0.value.reasoningRules,
          pricingByModelID: pricingByProvider[$0.key] ?? [:]
        )
      }
      .sorted { $0.key < $1.key }
  }

  var body: some View {
    List {
      Section {
        if let status {
          LabeledContent(
            "Active Layer",
            value: status.source == .remote ? "Layer 2 (Remote)" : "Layer 1 (Bundled)"
          )
          LabeledContent("Version", value: status.version)
          LabeledContent("Revision", value: String(status.revision))
          LabeledContent("Schema", value: "v\(status.schemaVersion)")
          if let generatedAt = status.generatedAt {
            LabeledContent("Generated", value: generatedAt)
          }
          LabeledContent(
            "Contents",
            value: "\(status.providerCount) providers · \(status.modelCount) models · \(status.pricingEntryCount) prices"
          )
          LabeledContent("Reasoning Rules", value: status.reasoningRuleCount.formatted())
        } else {
          Text("Catalog status unavailable.")
            .foregroundStyle(theme.secondaryForegroundColor)
        }
      } header: {
        Text("Active Catalog")
          .foregroundStyle(theme.secondaryForegroundColor)
      }
      .listRowBackground(theme.surfaceColor)

      Section {
        if let bundled = bundledSnapshot {
          LabeledContent("Version", value: bundled.version)
          LabeledContent("Revision", value: String(bundled.revision))
          LabeledContent(
            "Contents",
            value: "\(bundled.catalog.providers.count) providers · \(bundled.catalog.providers.values.reduce(0) { $0 + $1.models.count }) models · \(bundled.catalog.pricing.entries.count) prices"
          )
        } else {
          Text("Bundled catalog missing.")
            .foregroundStyle(.red)
        }
      } header: {
        Text("Layer 1 · Bundled")
          .foregroundStyle(theme.secondaryForegroundColor)
      }
      .listRowBackground(theme.surfaceColor)

      Section {
        if let status {
          LabeledContent("Endpoint") {
            Text(status.remoteURL.absoluteString)
              .font(.caption.monospaced())
              .foregroundStyle(theme.secondaryForegroundColor)
              .multilineTextAlignment(.trailing)
              .textSelection(.enabled)
          }
          LabeledContent(
            "Cached Remote",
            value: status.cachedVersion.map { version in
              if let revision = status.cachedRevision {
                return "\(version) (\(revision))"
              }
              return version
            } ?? "None"
          )
          if let cachedFileBytes {
            LabeledContent(
              "Disk Cache",
              value: ByteCountFormatter.string(fromByteCount: cachedFileBytes, countStyle: .file)
            )
          }
          if let etag = status.etag {
            LabeledContent("ETag") {
              Text(etag)
                .font(.caption.monospaced())
                .foregroundStyle(theme.secondaryForegroundColor)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            }
          }
          if let lastCheckedAt = status.lastCheckedAt {
            LabeledContent("Last Checked") {
              Text(lastCheckedAt, format: .dateTime.month(.abbreviated).day().hour().minute().second())
                .foregroundStyle(theme.secondaryForegroundColor)
            }
          }
          if let lastUpdatedAt = status.lastUpdatedAt {
            LabeledContent("Last Updated") {
              Text(lastUpdatedAt, format: .dateTime.month(.abbreviated).day().hour().minute().second())
                .foregroundStyle(theme.secondaryForegroundColor)
            }
          }
          if let lastFailureAt = status.lastFailureAt {
            LabeledContent("Last Failure") {
              Text(lastFailureAt, format: .dateTime.month(.abbreviated).day().hour().minute().second())
                .foregroundStyle(.red)
            }
          }
          if let lastFailureMessage = status.lastFailureMessage {
            Text(lastFailureMessage)
              .font(.footnote)
              .foregroundStyle(.red)
          }
        }
      } header: {
        Text("Layer 2 · Remote (spokiostudio.com)")
          .foregroundStyle(theme.secondaryForegroundColor)
      }
      .listRowBackground(theme.surfaceColor)

      Section {
        Button {
          Task { await refreshCatalog(force: true) }
        } label: {
          HStack(spacing: 10) {
            Label("Force Refresh Remote Catalog", systemImage: "arrow.clockwise")
            if isWorking || model.providers.isRefreshingModelCatalog {
              Spacer()
              ProgressView()
                .controlSize(.small)
            }
          }
        }
        .disabled(isWorking || model.providers.isRefreshingModelCatalog)

        Button("Check If Stale (Respects TTL)", systemImage: "clock.arrow.circlepath") {
          Task { await refreshCatalog(force: false) }
        }
        .disabled(isWorking || model.providers.isRefreshingModelCatalog)

        Button("Clear Cached Remote Catalog", systemImage: "trash", role: .destructive) {
          Task { await clearCache() }
        }
        .disabled(
          isWorking || model.providers.isRefreshingModelCatalog
            || (status?.cachedRevision == nil && status?.etag == nil && cachedFileBytes == nil)
        )

        if let actionStatus {
          Text(actionStatus)
            .font(.footnote)
            .foregroundStyle(theme.secondaryForegroundColor)
        }
        if let actionError {
          Text(actionError)
            .font(.footnote)
            .foregroundStyle(.red)
        }
      } header: {
        Text("Actions")
          .foregroundStyle(theme.secondaryForegroundColor)
      }
      .listRowBackground(theme.surfaceColor)

      if !providerSummaries.isEmpty {
        Section {
          ForEach(providerSummaries) { item in
            DisclosureGroup {
              DisclosureGroup("Models (\(item.models.count))") {
                if item.models.isEmpty {
                  Text("No seed models")
                    .font(.caption)
                    .foregroundStyle(theme.secondaryForegroundColor)
                } else {
                  ForEach(item.models, id: \.id) { entry in
                    VStack(alignment: .leading, spacing: 3) {
                      Text(entry.displayName)
                        .font(.subheadline.weight(.medium))
                      Text(entry.id)
                        .font(.caption.monospaced())
                        .foregroundStyle(theme.secondaryForegroundColor)
                        .textSelection(.enabled)
                      Text(modelDetailLine(entry, pricing: item.pricingByModelID[entry.id]))
                        .font(.caption)
                        .foregroundStyle(theme.secondaryForegroundColor)
                    }
                    .padding(.vertical, 2)
                  }
                }
              }

              DisclosureGroup("Reasoning Rules (\(item.rules.count))") {
                if item.rules.isEmpty {
                  Text("No reasoning rules")
                    .font(.caption)
                    .foregroundStyle(theme.secondaryForegroundColor)
                } else {
                  ForEach(Array(item.rules.enumerated()), id: \.offset) { index, rule in
                    VStack(alignment: .leading, spacing: 3) {
                      Text("#\(index + 1)  \(ruleMatchSummary(rule.match))")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                      Text(ruleControlSummary(rule.control))
                        .font(.caption)
                        .foregroundStyle(theme.secondaryForegroundColor)
                    }
                    .padding(.vertical, 2)
                  }
                }
              }
            } label: {
              LabeledContent(item.key) {
                Text("\(item.models.count) models · \(item.rules.count) rules")
                  .foregroundStyle(theme.secondaryForegroundColor)
              }
            }
          }
        } header: {
          Text("Active Providers")
            .foregroundStyle(theme.secondaryForegroundColor)
        }
        .listRowBackground(theme.surfaceColor)
      }
    }
    .listStyle(.insetGrouped)
    .scrollContentBackground(.hidden)
    .foregroundStyle(theme.primaryForegroundColor)
    .background(AppThemeBackground(theme: theme))
    .navigationTitle("Model Catalog")
    .navigationBarTitleDisplayMode(.inline)
    .onAppear {
      refreshDiskCacheSize()
    }
    .onChange(of: model.providers.modelCatalogRevision) { _, _ in
      refreshDiskCacheSize()
    }
  }

  private func modelDetailLine(
    _ entry: ModelCatalog.ModelEntry,
    pricing: ModelPricingCatalog.Entry?
  ) -> String {
    var parts: [String] = []
    if let ctx = entry.contextWindow {
      parts.append("\(ctx.formatted()) ctx")
    }
    if let maxOut = entry.maxOutputTokens {
      parts.append("\(maxOut.formatted()) out")
    }
    if !entry.inputModalities.isEmpty {
      parts.append(entry.inputModalities.joined(separator: ", "))
    }
    if let pricing {
      let input = pricing.rates.input ?? "?"
      let output = pricing.rates.output ?? "?"
      parts.append("$\(input)/$\(output) per 1M")
    }
    return parts.joined(separator: " · ")
  }

  private func ruleMatchSummary(_ match: ModelCatalog.ReasoningRule.Match) -> String {
    var parts: [String] = []
    if let exact = match.exactAny, !exact.isEmpty {
      parts.append("exact: \(exact.joined(separator: ", "))")
    }
    if let prefix = match.prefixAny, !prefix.isEmpty {
      parts.append("prefix: \(prefix.joined(separator: ", "))")
    }
    if let contains = match.containsAny, !contains.isEmpty {
      parts.append("contains: \(contains.joined(separator: ", "))")
    }
    return parts.joined(separator: " & ")
  }

  private func ruleControlSummary(_ control: ModelCatalog.ReasoningRule.Control) -> String {
    var parts: [String] = [control.kind.rawValue]
    if let efforts = control.efforts, !efforts.isEmpty {
      parts.append("[\(efforts.map(\.rawValue).joined(separator: ", "))]")
    }
    if let defaultEffort = control.defaultEffort {
      parts.append("default: \(defaultEffort.rawValue)")
    }
    if let budget = control.budget {
      let maxText = budget.maximum.map { $0.formatted() } ?? "∞"
      let autoText = budget.allowsAutomatic ? " (auto)" : ""
      parts.append("budget \(budget.minimum.formatted())..\(maxText)\(autoText)")
    }
    if control.combinesEffortAndBudget == true {
      parts.append("effort+budget")
    }
    if control.allowsOff == true {
      if let offWire = control.offWireValue {
        parts.append("off: \(offWire)")
      } else {
        parts.append("allows off")
      }
    }
    return parts.joined(separator: " · ")
  }

  private func refreshDiskCacheSize() {
    let url = model.storageEnvironment.layout.modelCatalogFile
    let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    if values?.isRegularFile == true, let size = values?.fileSize {
      cachedFileBytes = Int64(size)
    } else {
      cachedFileBytes = nil
    }
  }

  @MainActor
  private func refreshCatalog(force: Bool) async {
    isWorking = true
    actionStatus = nil
    actionError = nil
    defer {
      isWorking = false
      refreshDiskCacheSize()
    }
    do {
      let result = try await model.providers.refreshModelCatalog(force: force)
      switch result {
      case .updated(let revision, let version):
        actionStatus = "Updated to Layer 2 remote catalog \(version) (rev \(revision))."
      case .notModified:
        actionStatus = "HTTP 304 Not Modified (ETag matched)."
      case .upToDate:
        actionStatus = "Skipped network check (within refresh interval)."
      case .throttled:
        actionStatus = "Skipped network check (recent failure retry cooldown)."
      case .ignoredOlderThanBundled(let remoteRevision, let bundledRevision):
        actionStatus = "Remote rev \(remoteRevision) is not newer than bundled rev \(bundledRevision); kept Layer 1."
      }
    } catch {
      actionError = error.localizedDescription
    }
  }

  @MainActor
  private func clearCache() async {
    isWorking = true
    actionStatus = nil
    actionError = nil
    defer {
      isWorking = false
      refreshDiskCacheSize()
    }
    do {
      try await model.providers.clearModelCatalogCache()
      actionStatus = "Cleared cached Layer 2 catalog and reverted to Layer 1 bundled."
    } catch {
      actionError = error.localizedDescription
    }
  }
}

private struct SeedDataDeveloperView: View {
  let restartApp: () -> Void

  @Environment(AppModel.self) private var model
  @Environment(\.appFoundationTheme) private var theme

  @State private var preset: BYOKSeedPreset = .showcase
  @State private var themeID = BYOKchatThemes.midnight.id
  @State private var proEnabled = true
  @State private var isWorking = false
  @State private var errorMessage: String?
  @State private var confirmSeed = false
  @State private var confirmReset = false

  var body: some View {
    Form {
      Section {
        Picker("Preset", selection: $preset) {
          ForEach(BYOKSeedPreset.allCases) { option in
            Text(option.title).tag(option)
          }
        }

        Picker("Theme", selection: $themeID) {
          ForEach(BYOKchatThemes.catalog.themes) { option in
            Label(option.title, systemImage: option.symbolName).tag(option.id)
          }
        }

        Toggle("Simulated Pro Access", isOn: $proEnabled)
      } header: {
        Text("Configuration")
      } footer: {
        Text(preset.subtitle)
          .foregroundStyle(theme.secondaryForegroundColor)
      }
      .disabled(isWorking)
      .listRowBackground(theme.surfaceColor)

      Section {
        Button("Seed & Restart App", systemImage: "tray.and.arrow.down.fill") {
          confirmSeed = true
        }
        .disabled(isWorking)

        Button("Reset All Local Data", systemImage: "trash", role: .destructive) {
          confirmReset = true
        }
        .disabled(isWorking)

        if isWorking {
          HStack(spacing: 10) {
            ProgressView()
            Text("Updating local data…")
              .font(.footnote)
              .foregroundStyle(theme.secondaryForegroundColor)
          }
        }

        if let errorMessage {
          Text(errorMessage)
            .font(.footnote)
            .foregroundStyle(.red)
        }
      } header: {
        Text("Actions")
      } footer: {
        Text("Seeding replaces all local providers, projects, MCP servers, chats, Library files, credentials, and analytics telemetry, then restarts BYOKchat with the selected theme.")
          .foregroundStyle(theme.secondaryForegroundColor)
      }
      .listRowBackground(theme.surfaceColor)
    }
    .scrollContentBackground(.hidden)
    .foregroundStyle(theme.primaryForegroundColor)
    .background(AppThemeBackground(theme: theme))
    .navigationTitle("Seed Data")
    .navigationBarTitleDisplayMode(.inline)
    .onAppear {
      themeID = model.themeManager.effectiveTheme.id
    }
    .confirmationDialog(
      "Replace local data with seeded data?",
      isPresented: $confirmSeed,
      titleVisibility: .visible
    ) {
      Button("Seed & Restart App", role: .destructive) {
        Task { @MainActor in
          await runSeed()
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("All current local chats, connections, projects, MCP servers, Library files, and analytics on this device will be wiped and replaced.")
    }
    .confirmationDialog(
      "Reset all local data?",
      isPresented: $confirmReset,
      titleVisibility: .visible
    ) {
      Button("Reset & Restart App", role: .destructive) {
        Task { @MainActor in
          await runReset()
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Deletes all local workspaces, Keychain credentials, and telemetry, then restarts BYOKchat to onboarding.")
    }
  }

  @MainActor
  private func runSeed() async {
    guard !isWorking else { return }
    isWorking = true
    errorMessage = nil

    do {
      await model.chats.stopAllGenerations()
      let configuration = BYOKSeedConfiguration(
        preset: preset,
        themeID: themeID,
        proEnabled: proEnabled
      )
      try await BYOKSeedDataService.seedAll(
        configuration,
        environment: model.storageEnvironment,
        telemetryRecorder: model.telemetryRecorder
      )
      isWorking = false
      restartApp()
    } catch {
      isWorking = false
      errorMessage = error.localizedDescription
    }
  }

  @MainActor
  private func runReset() async {
    guard !isWorking else { return }
    isWorking = true
    errorMessage = nil

    do {
      await model.chats.stopAllGenerations()
      try await AppStorageBootstrap.resetLocalData(
        environment: model.storageEnvironment,
        telemetryRecorder: model.telemetryRecorder,
        createBackup: false
      )
      isWorking = false
      restartApp()
    } catch {
      isWorking = false
      errorMessage = error.localizedDescription
    }
  }
}

private struct FullTextSearchDeveloperView: View {
  let purchases: BYOKPurchaseStore

  @Environment(AppModel.self) private var model
  @Environment(\.appFoundationTheme) private var theme

  @State private var status: ConversationSearchIndexStatus?
  @State private var isWorking = false
  @State private var actionStatus: String?
  @State private var actionError: String?
  @State private var confirmClear = false
  @State private var testQuery = ""
  @State private var isRunningQuery = false
  @State private var testResult: ConversationSearchQueryResult?

  var body: some View {
    List {
      statusSection
      coverageSection
      databaseSection
      performanceSection
      testQuerySection
      actionsSection
    }
    .listStyle(.insetGrouped)
    .scrollContentBackground(.hidden)
    .foregroundStyle(theme.primaryForegroundColor)
    .background(AppThemeBackground(theme: theme))
    .navigationTitle("Full Text Search")
    .navigationBarTitleDisplayMode(.inline)
    .task {
      await reloadStatus()
    }
    .refreshable {
      await reloadStatus()
    }
    .onChange(of: purchases.hasPro) { _, _ in
      Task { await reloadStatus() }
    }
    .confirmationDialog(
      "Clear search index?",
      isPresented: $confirmClear,
      titleVisibility: .visible
    ) {
      Button("Clear Search Index", role: .destructive) {
        Task { await clearIndex() }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Deletes the derived SQLite FTS5 index files. Authoritative conversation shards are never modified and can be reindexed at any time.")
    }
  }

  private var statusSection: some View {
    Section {
      LabeledContent("Entitlement", value: purchases.hasPro ? "Pro (Full text search)" : "Free (Titles only)")
      if let status {
        LabeledContent("Indexing Enabled", value: status.isEnabled ? "Yes" : "No")
        LabeledContent("Index State", value: phaseLabel(for: status))
        LabeledContent("Store Attached", value: status.isConfigured ? "SQLite FTS5" : "Not configured")
        if status.statistics.consecutiveFailureCount > 0 {
          LabeledContent("Consecutive Failures") {
            Text(status.statistics.consecutiveFailureCount.formatted())
              .foregroundStyle(.red)
          }
        }
        if let lastErrorAt = status.statistics.lastErrorAt {
          LabeledContent("Last Error At") {
            Text(lastErrorAt, format: .dateTime.month(.abbreviated).day().hour().minute().second())
              .foregroundStyle(.red)
          }
        }
        if let lastError = status.statistics.lastErrorDescription {
          Text(lastError)
            .font(.footnote)
            .foregroundStyle(.red)
        }
      } else {
        HStack(spacing: 10) {
          ProgressView()
          Text("Loading index status…")
            .foregroundStyle(theme.secondaryForegroundColor)
        }
      }
    } header: {
      Text("Status")
        .foregroundStyle(theme.secondaryForegroundColor)
    } footer: {
      Text("Free users search chat titles in memory from index.json. Pro enables incremental SQLite FTS5 indexing across titles, message content, and attachment names.")
        .foregroundStyle(theme.secondaryForegroundColor)
    }
    .listRowBackground(theme.surfaceColor)
  }

  private var coverageSection: some View {
    Section {
      if let status {
        LabeledContent("Total Chats in Index", value: status.totalConversationCount.formatted())
        LabeledContent("Eligible Chats", value: status.eligibleConversationCount.formatted())
        LabeledContent("Indexed Chats", value: status.statistics.indexedConversationCount.formatted())
        LabeledContent("Stale / Pending Chats") {
          Text(status.staleConversationCount.formatted())
            .foregroundStyle(status.staleConversationCount > 0 ? Color.orange : theme.secondaryForegroundColor)
        }
        LabeledContent("Indexed Documents", value: status.statistics.indexedDocumentCount.formatted())
        LabeledContent("Indexed Messages", value: status.statistics.indexedMessageCount.formatted())
        if status.excludedEmptyChatCount > 0 {
          LabeledContent("Excluded Empty Drafts", value: status.excludedEmptyChatCount.formatted())
        }
        if status.quarantinedShardCount > 0 {
          LabeledContent("Quarantined Shards") {
            Text(status.quarantinedShardCount.formatted())
              .foregroundStyle(Color.orange)
          }
        }
      } else {
        Text("Unavailable")
          .foregroundStyle(theme.secondaryForegroundColor)
      }
    } header: {
      Text("Coverage")
        .foregroundStyle(theme.secondaryForegroundColor)
    }
    .listRowBackground(theme.surfaceColor)
  }

  private var databaseSection: some View {
    Section {
      if let stats = status?.statistics {
        LabeledContent("Database File", value: stats.databaseExists ? "Present" : "Not created")
        LabeledContent("Schema Version", value: "v\(stats.schemaVersion)")
        LabeledContent("Tokenizer") {
          Text(stats.tokenizer)
            .font(.caption.monospaced())
            .foregroundStyle(theme.secondaryForegroundColor)
            .multilineTextAlignment(.trailing)
        }
        LabeledContent("iCloud Backup", value: stats.isExcludedFromBackup ? "Excluded" : "Included")
        LabeledContent("Total Footprint", value: formattedBytes(stats.totalBytes))
        LabeledContent("Main DB", value: formattedBytes(stats.databaseBytes))
        LabeledContent("WAL / SHM", value: "\(formattedBytes(stats.walBytes)) / \(formattedBytes(stats.shmBytes))")
        if !stats.databasePath.isEmpty {
          VStack(alignment: .leading, spacing: 4) {
            Text("Path")
              .font(.caption)
              .foregroundStyle(theme.secondaryForegroundColor)
            Text(stats.databasePath)
              .font(.caption2.monospaced())
              .foregroundStyle(theme.secondaryForegroundColor)
              .textSelection(.enabled)
          }
          .padding(.vertical, 2)
        }
      } else {
        Text("Unavailable")
          .foregroundStyle(theme.secondaryForegroundColor)
      }
    } header: {
      Text("Database & Engine")
        .foregroundStyle(theme.secondaryForegroundColor)
    }
    .listRowBackground(theme.surfaceColor)
  }

  private var performanceSection: some View {
    Section {
      if let stats = status?.statistics {
        if let rebuildAt = stats.lastRebuildAt {
          LabeledContent("Last Full Rebuild") {
            Text(rebuildAt, format: .dateTime.month(.abbreviated).day().hour().minute().second())
              .foregroundStyle(theme.secondaryForegroundColor)
          }
        } else {
          LabeledContent("Last Full Rebuild", value: "Never")
        }
        if let durationMs = stats.lastRebuildDurationMilliseconds {
          LabeledContent("Rebuild Duration", value: formattedMilliseconds(durationMs))
        }
        if let syncAt = stats.lastIncrementalSyncAt {
          LabeledContent("Last Sync") {
            Text(syncAt, format: .dateTime.month(.abbreviated).day().hour().minute().second())
              .foregroundStyle(theme.secondaryForegroundColor)
          }
        } else {
          LabeledContent("Last Sync", value: "Never")
        }
        if let latencyMs = stats.lastQueryLatencyMilliseconds {
          let hitsText = stats.lastQueryHitCount.map { " · \($0) hit\($0 == 1 ? "" : "s")" } ?? ""
          LabeledContent("Last Query", value: "\(formattedMilliseconds(latencyMs))\(hitsText)")
        } else {
          LabeledContent("Last Query", value: "None")
        }
      } else {
        Text("Unavailable")
          .foregroundStyle(theme.secondaryForegroundColor)
      }
    } header: {
      Text("Performance & Timestamps")
        .foregroundStyle(theme.secondaryForegroundColor)
    }
    .listRowBackground(theme.surfaceColor)
  }

  private var testQuerySection: some View {
    Section {
      HStack(spacing: 10) {
        TextField("Run test FTS query…", text: $testQuery)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .submitLabel(.search)
          .onSubmit {
            Task { await runTestQuery() }
          }
        Button("Run") {
          Task { await runTestQuery() }
        }
        .disabled(isRunningQuery || testQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }

      if isRunningQuery {
        HStack(spacing: 10) {
          ProgressView()
            .controlSize(.small)
          Text("Querying FTS5…")
            .font(.footnote)
            .foregroundStyle(theme.secondaryForegroundColor)
        }
      } else if let testResult {
        LabeledContent(
          "Engine",
          value: testResult.usedFTSIndex ? "SQLite FTS5" : "Linear Scan Fallback"
        )
        LabeledContent(
          "Latency / Hits",
          value: "\(formattedMilliseconds(testResult.latencyMilliseconds)) · \(testResult.results.count) match\(testResult.results.count == 1 ? "" : "es")"
        )
        ForEach(Array(testResult.results.prefix(10))) { match in
          VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
              Text(match.role.rawValue.uppercased())
                .font(.caption2.weight(.semibold).monospaced())
                .foregroundStyle(theme.accentColor)
              Text(match.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            }
            Text(match.snippet)
              .font(.caption)
              .foregroundStyle(theme.secondaryForegroundColor)
              .lineLimit(2)
          }
          .padding(.vertical, 2)
        }
      }
    } header: {
      Text("Test Query")
        .foregroundStyle(theme.secondaryForegroundColor)
    } footer: {
      Text("Executes full-text search directly against the store regardless of current entitlement for debugging.")
        .foregroundStyle(theme.secondaryForegroundColor)
    }
    .listRowBackground(theme.surfaceColor)
  }

  private var actionsSection: some View {
    Section {
      Button {
        Task { await reconcileIndex() }
      } label: {
        HStack(spacing: 10) {
          Label("Reconcile Stale Shards", systemImage: "arrow.triangle.2.circlepath")
          if isWorking {
            Spacer()
            ProgressView()
              .controlSize(.small)
          }
        }
      }
      .disabled(isWorking)

      Button("Force Rebuild Index", systemImage: "arrow.clockwise") {
        Task { await rebuildIndex() }
      }
      .disabled(isWorking)

      Button("Clear Search Index", systemImage: "trash", role: .destructive) {
        confirmClear = true
      }
      .disabled(isWorking || status?.statistics.databaseExists != true)

      if let actionStatus {
        Text(actionStatus)
          .font(.footnote)
          .foregroundStyle(theme.secondaryForegroundColor)
      }
      if let actionError {
        Text(actionError)
          .font(.footnote)
          .foregroundStyle(.red)
      }
    } header: {
      Text("Actions")
        .foregroundStyle(theme.secondaryForegroundColor)
    }
    .listRowBackground(theme.surfaceColor)
  }

  private func phaseLabel(for status: ConversationSearchIndexStatus) -> String {
    if status.phase == .indexing, let progress = status.progress, progress.total > 0 {
      return "Indexing (\(progress.processed)/\(progress.total))"
    }
    return status.phase.displayTitle
  }

  private func formattedBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
  }

  private func formattedMilliseconds(_ value: Double) -> String {
    if value < 1 {
      return String(format: "%.2f ms", value)
    }
    return String(format: "%.1f ms", value)
  }

  @MainActor
  private func reloadStatus() async {
    status = await model.chats.refreshSearchIndexStatus()
  }

  @MainActor
  private func reconcileIndex() async {
    isWorking = true
    actionStatus = nil
    actionError = nil
    defer { isWorking = false }
    await model.chats.reconcileSearchIndex()
    await reloadStatus()
    if let status {
      actionStatus = "Reconciled: \(status.statistics.indexedConversationCount)/\(status.eligibleConversationCount) chats indexed."
    }
  }

  @MainActor
  private func rebuildIndex() async {
    isWorking = true
    actionStatus = nil
    actionError = nil
    defer { isWorking = false }
    do {
      try await model.chats.rebuildSearchIndex()
      await reloadStatus()
      if let status {
        let duration = status.statistics.lastRebuildDurationMilliseconds.map(formattedMilliseconds) ?? "—"
        actionStatus = "Rebuilt index for \(status.statistics.indexedConversationCount) chats in \(duration)."
      }
    } catch {
      actionError = error.localizedDescription
    }
  }

  @MainActor
  private func clearIndex() async {
    isWorking = true
    actionStatus = nil
    actionError = nil
    defer { isWorking = false }
    do {
      try await model.chats.clearSearchIndex()
      testResult = nil
      await reloadStatus()
      actionStatus = "Cleared derived SQLite FTS5 index."
    } catch {
      actionError = error.localizedDescription
    }
  }

  @MainActor
  private func runTestQuery() async {
    let trimmed = testQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    isRunningQuery = true
    defer { isRunningQuery = false }
    testResult = await model.chats.debugSearchFullText(trimmed, limit: 50)
    await reloadStatus()
  }
}
#endif
