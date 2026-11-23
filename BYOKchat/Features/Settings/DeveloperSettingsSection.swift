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
#endif
