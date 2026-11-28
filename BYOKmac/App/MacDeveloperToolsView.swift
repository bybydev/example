#if DEBUG
import BYOKchatProviderCore
import Foundation
import MacAppFoundation
import SwiftUI

@MainActor
enum MacDeveloperTools {
  static func configuration(
    model: MacAppModel,
    purchases: PurchaseManager,
    replayOnboarding: @escaping @MainActor () -> Void
  ) -> FoundationDeveloperConfiguration {
    var replays = MacPurchaseStore.developerConfiguration.replays
    for feature in MacProFeature.allCases {
      replays.append(
        FoundationDeveloperReplay(
          id: "upsell-\(feature.rawValue)",
          title: "Upsell · \(feature.title)",
          systemImage: featureSymbol(feature)
        ) { _ in
          MacProUpsellSheet(feature: feature)
        }
      )
    }

    let sections: [FoundationDeveloperSection] = [
      FoundationDeveloperSection(
        id: "byok-chat-tools",
        title: "BYOK Chat",
        items: [
          .destination(
            FoundationDeveloperDestination(
              id: "model-catalog",
              title: "Model Catalog",
              systemImage: "square.stack.3d.up"
            ) {
              MacCatalogInspectorTab(model: model)
                .padding(16)
                .background(MacDesignTokens.Colors.canvas)
            }
          ),
          .destination(
            FoundationDeveloperDestination(
              id: "fts5-search",
              title: "FTS5 Search",
              systemImage: "magnifyingglass"
            ) {
              MacFTS5InspectorTab(model: model, purchases: purchases)
                .padding(16)
                .background(MacDesignTokens.Colors.canvas)
            }
          ),
          .destination(
            FoundationDeveloperDestination(
              id: "seed-data",
              title: "Seed Data",
              systemImage: "tray.and.arrow.down.fill"
            ) {
              MacSeedDataTab(model: model)
                .padding(16)
                .background(MacDesignTokens.Colors.canvas)
            }
          ),
          .destination(
            FoundationDeveloperDestination(
              id: "provider-console",
              title: "Provider Console",
              systemImage: "terminal"
            ) {
              MacProviderConsoleTab(model: model)
                .padding(16)
                .background(MacDesignTokens.Colors.canvas)
            }
          ),
          .action(
            FoundationDeveloperAction(
              id: "replay-onboarding",
              title: "Replay Onboarding",
              systemImage: "rectangle.stack.fill"
            ) {
              await MainActor.run {
                replayOnboarding()
              }
            }
          ),
        ]
      )
    ]

    return FoundationDeveloperConfiguration(
      replays: replays,
      additionalSections: sections
    )
  }

  private static func featureSymbol(_ feature: MacProFeature) -> String {
    switch feature {
    case .providerAccounts: "key.horizontal.fill"
    case .projects: "folder.fill"
    case .mcpServers: "shippingbox.fill"
    case .analytics: "chart.bar.xaxis"
    case .themes: "paintpalette.fill"
    case .chatSearch: "magnifyingglass"
    }
  }
}

// MARK: - Model Catalog Inspector

@MainActor
private struct MacCatalogInspectorTab: View {
  let model: MacAppModel

  @State private var searchText = ""
  @State private var isWorking = false
  @State private var actionStatus: String?
  @State private var actionError: String?
  @State private var cachedFileBytes: Int64?

  private var providers: MacProviderModel? { model.providers }
  private var status: ModelCatalogStatus? { providers?.modelCatalogStatus }

  private var activeSnapshot: ModelCatalogSnapshot? {
    _ = providers?.modelCatalogRevision
    return ModelCatalogRegistry.current
  }

  private var bundledSnapshot: ModelCatalogSnapshot? {
    ModelCatalogRegistry.bundled
  }

  private struct ProviderSectionSummary: Identifiable {
    var id: String { key }
    let key: String
    let models: [ModelCatalog.ModelEntry]
    let ruleCount: Int
    let pricingByModelID: [String: ModelPricingCatalog.Entry]
  }

  private var filteredSections: [ProviderSectionSummary] {
    guard let catalog = activeSnapshot?.catalog else { return [] }
    var pricingByProvider: [String: [String: ModelPricingCatalog.Entry]] = [:]
    for entry in catalog.pricing.entries {
      for modelID in entry.modelIDs {
        pricingByProvider[entry.provider, default: [:]][modelID] = entry
      }
    }

    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return catalog.providers
      .keys
      .sorted()
      .compactMap { key -> ProviderSectionSummary? in
        guard let section = catalog.providers[key] else { return nil }
        let matchedModels: [ModelCatalog.ModelEntry]
        if query.isEmpty || key.lowercased().contains(query) {
          matchedModels = section.models
        } else {
          matchedModels = section.models.filter { entry in
            entry.id.lowercased().contains(query)
              || entry.displayName.lowercased().contains(query)
          }
          if matchedModels.isEmpty { return nil }
        }
        return ProviderSectionSummary(
          key: key,
          models: matchedModels,
          ruleCount: section.reasoningRules.count,
          pricingByModelID: pricingByProvider[key] ?? [:]
        )
      }
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        HStack(alignment: .top, spacing: 16) {
          GroupBox("Active Catalog") {
            VStack(alignment: .leading, spacing: 8) {
              if let status {
                LabeledContent(
                  "Active Layer",
                  value: status.source == .remote ? "Layer 2 (Remote)" : "Layer 1 (Bundled)"
                )
                LabeledContent("Version", value: status.version)
                LabeledContent("Revision", value: status.revision.formatted())
                LabeledContent("Schema", value: "v\(status.schemaVersion)")
                if let generatedAt = status.generatedAt {
                  LabeledContent("Generated", value: generatedAt)
                }
                LabeledContent(
                  "Entries",
                  value: "\(status.providerCount) providers · \(status.modelCount) models · \(status.pricingEntryCount) prices"
                )
                LabeledContent("Reasoning Rules", value: status.reasoningRuleCount.formatted())
              } else {
                Text("Catalog status unavailable until workspace startup finishes.")
                  .foregroundStyle(MacDesignTokens.Colors.textMuted)
              }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
          }

          GroupBox("Layer 1 (Bundled) vs Layer 2 (Remote)") {
            VStack(alignment: .leading, spacing: 8) {
              if let bundled = bundledSnapshot {
                let bundledModels = bundled.catalog.providers.values.reduce(0) { $0 + $1.models.count }
                LabeledContent("Layer 1 Bundled", value: "\(bundled.version) (rev \(bundled.revision)) · \(bundledModels) models")
              } else {
                LabeledContent("Layer 1 Bundled", value: "Missing")
              }

              if let status {
                LabeledContent("Remote URL") {
                  Text(status.remoteURL.absoluteString)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                }
                LabeledContent(
                  "Cached Remote",
                  value: status.cachedVersion.map { version in
                    status.cachedRevision.map { "\(version) (rev \($0))" } ?? version
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
                      .lineLimit(1)
                      .truncationMode(.middle)
                      .textSelection(.enabled)
                  }
                }
                if let lastCheckedAt = status.lastCheckedAt {
                  LabeledContent(
                    "Last Checked",
                    value: lastCheckedAt.formatted(date: .abbreviated, time: .standard)
                  )
                }
                if let lastUpdatedAt = status.lastUpdatedAt {
                  LabeledContent(
                    "Last Updated",
                    value: lastUpdatedAt.formatted(date: .abbreviated, time: .standard)
                  )
                }
                if let lastFailureAt = status.lastFailureAt {
                  LabeledContent(
                    "Last Failure",
                    value: lastFailureAt.formatted(date: .abbreviated, time: .standard)
                  )
                }
                if let lastFailureMessage = status.lastFailureMessage {
                  Text(lastFailureMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                }
              }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
          }
        }

        GroupBox("Catalog Actions") {
          VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
              Button("Force Refresh Catalog", systemImage: "arrow.clockwise") {
                Task { await refreshCatalog(force: true) }
              }
              .buttonStyle(MacActionButtonStyle(.secondary))
              .disabled(isWorking || providers == nil || providers?.isRefreshingModelCatalog == true)

              Button("Check If Stale (TTL)", systemImage: "clock.arrow.circlepath") {
                Task { await refreshCatalog(force: false) }
              }
              .buttonStyle(MacActionButtonStyle(.secondary))
              .disabled(isWorking || providers == nil || providers?.isRefreshingModelCatalog == true)

              Button("Clear Catalog Cache", systemImage: "trash", role: .destructive) {
                Task { await clearCache() }
              }
              .buttonStyle(MacActionButtonStyle(.destructive))
              .disabled(
                isWorking || providers == nil || providers?.isRefreshingModelCatalog == true
                  || (status?.cachedRevision == nil && status?.etag == nil && cachedFileBytes == nil)
              )

              if isWorking || providers?.isRefreshingModelCatalog == true {
                ProgressView()
                  .controlSize(.small)
              }
              Spacer()
            }

            if let actionStatus {
              Text(actionStatus)
                .font(.caption)
                .foregroundStyle(MacDesignTokens.Colors.textMuted)
            }
            if let actionError {
              Text(actionError)
                .font(.caption)
                .foregroundStyle(.red)
            }
          }
          .padding(8)
        }

        GroupBox("Browse Active Catalog Models") {
          VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
              Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
              TextField("Search providers or model IDs…", text: $searchText)
                .textFieldStyle(.plain)
              if !searchText.isEmpty {
                Button {
                  searchText = ""
                } label: {
                  Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
              }
            }
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))

            if filteredSections.isEmpty {
              Text("No catalog entries match your filter.")
                .font(.caption)
                .foregroundStyle(MacDesignTokens.Colors.textMuted)
                .padding(.vertical, 8)
            } else {
              ForEach(filteredSections) { section in
                DisclosureGroup {
                  VStack(alignment: .leading, spacing: 6) {
                    ForEach(section.models, id: \.id) { entry in
                      VStack(alignment: .leading, spacing: 2) {
                        HStack {
                          Text(entry.displayName)
                            .font(.subheadline.weight(.medium))
                          Spacer()
                          Text(entry.id)
                            .font(.caption.monospaced())
                            .foregroundStyle(MacDesignTokens.Colors.textMuted)
                            .textSelection(.enabled)
                        }
                        Text(modelSummary(entry, pricing: section.pricingByModelID[entry.id]))
                          .font(.caption)
                          .foregroundStyle(MacDesignTokens.Colors.textMuted)
                      }
                      .padding(.vertical, 3)
                      Divider()
                    }
                  }
                  .padding(.top, 4)
                } label: {
                  HStack {
                    Text(section.key)
                      .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(section.models.count) models · \(section.ruleCount) reasoning rules")
                      .font(.caption)
                      .foregroundStyle(MacDesignTokens.Colors.textMuted)
                  }
                }
              }
            }
          }
          .padding(8)
        }
      }
      .padding(4)
    }
    .onAppear {
      refreshDiskCacheSize()
    }
    .onChange(of: providers?.modelCatalogRevision) { _, _ in
      refreshDiskCacheSize()
    }
  }

  private func modelSummary(
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
    return parts.isEmpty ? "No additional metadata" : parts.joined(separator: " · ")
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

  private func refreshCatalog(force: Bool) async {
    guard let providers else { return }
    isWorking = true
    actionStatus = nil
    actionError = nil
    defer {
      isWorking = false
      refreshDiskCacheSize()
    }
    do {
      let result = try await providers.refreshModelCatalog(force: force)
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

  private func clearCache() async {
    guard let providers else { return }
    isWorking = true
    actionStatus = nil
    actionError = nil
    defer {
      isWorking = false
      refreshDiskCacheSize()
    }
    do {
      try await providers.clearModelCatalogCache()
      actionStatus = "Cleared cached Layer 2 catalog and reverted to Layer 1 bundled."
    } catch {
      actionError = error.localizedDescription
    }
  }
}

// MARK: - FTS5 Search Inspector

@MainActor
private struct MacFTS5InspectorTab: View {
  let model: MacAppModel
  let purchases: PurchaseManager

  @State private var status: ConversationSearchIndexStatus?
  @State private var isWorking = false
  @State private var actionStatus: String?
  @State private var actionError: String?
  @State private var confirmClear = false
  @State private var testQuery = ""
  @State private var isRunningQuery = false
  @State private var testResult: ConversationSearchQueryResult?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        HStack(alignment: .top, spacing: 16) {
          GroupBox("Index Status & Coverage") {
            VStack(alignment: .leading, spacing: 8) {
              LabeledContent("Entitlement", value: purchases.hasPro ? "Pro (Full-text search)" : "Free (Titles only)")
              if let status {
                LabeledContent("Indexing Enabled", value: status.isEnabled ? "Yes" : "No")
                LabeledContent("Phase", value: phaseLabel(for: status))
                LabeledContent("Store Attached", value: status.isConfigured ? "SQLite FTS5" : "Not configured")
                LabeledContent("Total / Eligible Chats", value: "\(status.totalConversationCount) / \(status.eligibleConversationCount)")
                LabeledContent("Indexed / Stale Chats", value: "\(status.statistics.indexedConversationCount) / \(status.staleConversationCount)")
                LabeledContent("Indexed Docs / Messages", value: "\(status.statistics.indexedDocumentCount) / \(status.statistics.indexedMessageCount)")
                if status.excludedEmptyChatCount > 0 {
                  LabeledContent("Excluded Empty Drafts", value: status.excludedEmptyChatCount.formatted())
                }
                if status.quarantinedShardCount > 0 {
                  LabeledContent("Quarantined Shards", value: status.quarantinedShardCount.formatted())
                }
                if let lastError = status.statistics.lastErrorDescription {
                  Text(lastError)
                    .font(.caption)
                    .foregroundStyle(.red)
                }
              } else {
                Text("Status unavailable.")
                  .foregroundStyle(MacDesignTokens.Colors.textMuted)
              }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
          }

          GroupBox("Database & Performance") {
            VStack(alignment: .leading, spacing: 8) {
              if let stats = status?.statistics {
                LabeledContent("Database File", value: stats.databaseExists ? "Present" : "Not created")
                LabeledContent("Schema Version", value: "v\(stats.schemaVersion)")
                LabeledContent("Tokenizer", value: stats.tokenizer)
                LabeledContent("Total Footprint", value: formattedBytes(stats.totalBytes))
                LabeledContent("Main / WAL / SHM", value: "\(formattedBytes(stats.databaseBytes)) / \(formattedBytes(stats.walBytes)) / \(formattedBytes(stats.shmBytes))")
                LabeledContent(
                  "Last Rebuild",
                  value: stats.lastRebuildAt?.formatted(date: .abbreviated, time: .standard) ?? "Never"
                )
                if let duration = stats.lastRebuildDurationMilliseconds {
                  LabeledContent("Rebuild Duration", value: formattedMilliseconds(duration))
                }
                LabeledContent(
                  "Last Sync",
                  value: stats.lastIncrementalSyncAt?.formatted(date: .abbreviated, time: .standard) ?? "Never"
                )
                if let latency = stats.lastQueryLatencyMilliseconds {
                  let hits = stats.lastQueryHitCount.map { " · \($0) hit\($0 == 1 ? "" : "s")" } ?? ""
                  LabeledContent("Last Query", value: "\(formattedMilliseconds(latency))\(hits)")
                }
                if !stats.databasePath.isEmpty {
                  Text(stats.databasePath)
                    .font(.caption2.monospaced())
                    .foregroundStyle(MacDesignTokens.Colors.textMuted)
                    .textSelection(.enabled)
                }
              } else {
                Text("Unavailable.")
                  .foregroundStyle(MacDesignTokens.Colors.textMuted)
              }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
          }
        }

        GroupBox("Index Maintenance") {
          VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
              Button("Reconcile Index", systemImage: "arrow.triangle.2.circlepath") {
                Task { await reconcileIndex() }
              }
              .buttonStyle(MacActionButtonStyle(.secondary))
              .disabled(isWorking || model.coreServices == nil)

              Button("Rebuild Index", systemImage: "arrow.clockwise") {
                Task { await rebuildIndex() }
              }
              .buttonStyle(MacActionButtonStyle(.secondary))
              .disabled(isWorking || model.coreServices == nil)

              Button("Clear Index", systemImage: "trash", role: .destructive) {
                confirmClear = true
              }
              .buttonStyle(MacActionButtonStyle(.destructive))
              .disabled(isWorking || status?.statistics.databaseExists != true)

              Button("Refresh Status", systemImage: "arrow.clockwise.circle") {
                Task { await reloadStatus() }
              }
              .buttonStyle(MacActionButtonStyle(.secondary))
              .disabled(isWorking)

              if isWorking {
                ProgressView()
                  .controlSize(.small)
              }
              Spacer()
            }

            if let actionStatus {
              Text(actionStatus)
                .font(.caption)
                .foregroundStyle(MacDesignTokens.Colors.textMuted)
            }
            if let actionError {
              Text(actionError)
                .font(.caption)
                .foregroundStyle(.red)
            }
          }
          .padding(8)
        }

        GroupBox("Live Test Query Runner") {
          VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
              TextField("Enter full-text search query…", text: $testQuery)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                  Task { await runTestQuery() }
                }

              Button("Run Query", systemImage: "play.fill") {
                Task { await runTestQuery() }
              }
              .buttonStyle(MacActionButtonStyle(.secondary))
              .disabled(
                isRunningQuery
                  || model.coreServices == nil
                  || testQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              )

              if isRunningQuery {
                ProgressView()
                  .controlSize(.small)
              }
            }

            if let testResult {
              HStack(spacing: 16) {
                LabeledContent("Engine", value: testResult.usedFTSIndex ? "SQLite FTS5" : "Linear Scan Fallback")
                LabeledContent("Latency", value: formattedMilliseconds(testResult.latencyMilliseconds))
                LabeledContent("Matches", value: testResult.results.count.formatted())
              }
              .font(.caption)

              if testResult.results.isEmpty {
                Text("No matches found.")
                  .font(.caption)
                  .foregroundStyle(MacDesignTokens.Colors.textMuted)
              } else {
                Divider()
                ForEach(Array(testResult.results.prefix(20))) { match in
                  VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                      Text(match.role.rawValue.uppercased())
                        .font(.caption2.weight(.bold).monospaced())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(MacDesignTokens.Colors.accentSoft, in: Capsule())
                        .foregroundStyle(MacDesignTokens.Colors.accent)

                      Text(match.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)

                      Spacer()

                      Text(match.messageID?.rawValue ?? "title")
                        .font(.caption2.monospaced())
                        .foregroundStyle(MacDesignTokens.Colors.textMuted)
                        .textSelection(.enabled)
                    }
                    Text(match.snippet)
                      .font(.caption)
                      .foregroundStyle(MacDesignTokens.Colors.textMuted)
                      .lineLimit(3)
                    Text("Conversation: \(match.conversationID.rawValue)")
                      .font(.caption2.monospaced())
                      .foregroundStyle(MacDesignTokens.Colors.textMuted.opacity(0.8))
                      .textSelection(.enabled)
                  }
                  .padding(.vertical, 4)
                  Divider()
                }
              }
            }
          }
          .padding(8)
        }
      }
      .padding(4)
    }
    .task {
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
      Button("Clear Index", role: .destructive) {
        Task { await clearIndex() }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Deletes the derived SQLite FTS5 index files. Conversations are untouched and can be reindexed anytime.")
    }
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
    value < 1 ? String(format: "%.2f ms", value) : String(format: "%.1f ms", value)
  }

  private func reloadStatus() async {
    guard let store = model.coreServices?.conversationStore else {
      status = nil
      return
    }
    status = await store.searchIndexStatus()
  }

  private func reconcileIndex() async {
    guard let store = model.coreServices?.conversationStore else { return }
    isWorking = true
    actionStatus = nil
    actionError = nil
    defer { isWorking = false }
    if let chats = model.chats {
      await chats.reconcileSearchIndex()
    } else {
      await store.reconcileSearchIndex()
    }
    await reloadStatus()
    if let status {
      actionStatus = "Reconciled: \(status.statistics.indexedConversationCount)/\(status.eligibleConversationCount) chats indexed."
    }
  }

  private func rebuildIndex() async {
    guard let store = model.coreServices?.conversationStore else { return }
    isWorking = true
    actionStatus = nil
    actionError = nil
    defer { isWorking = false }
    do {
      if let chats = model.chats {
        try await chats.rebuildSearchIndex()
      } else {
        try await store.rebuildSearchIndex()
      }
      await reloadStatus()
      if let status {
        let duration = status.statistics.lastRebuildDurationMilliseconds.map(formattedMilliseconds) ?? "—"
        actionStatus = "Rebuilt index for \(status.statistics.indexedConversationCount) chats in \(duration)."
      }
    } catch {
      actionError = error.localizedDescription
    }
  }

  private func clearIndex() async {
    guard let store = model.coreServices?.conversationStore else { return }
    isWorking = true
    actionStatus = nil
    actionError = nil
    defer { isWorking = false }
    do {
      if let chats = model.chats {
        try await chats.clearSearchIndex()
      } else {
        try await store.clearSearchIndex()
      }
      testResult = nil
      await reloadStatus()
      actionStatus = "Cleared derived SQLite FTS5 index."
    } catch {
      actionError = error.localizedDescription
    }
  }

  private func runTestQuery() async {
    guard let store = model.coreServices?.conversationStore else { return }
    let trimmed = testQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    isRunningQuery = true
    defer { isRunningQuery = false }
    testResult = await store.searchFullTextWithMetrics(trimmed, limit: 50)
    await reloadStatus()
  }
}

// MARK: - Seed Data Tab

@MainActor
private struct MacSeedDataTab: View {
  let model: MacAppModel

  @State private var includeConversations = true
  @State private var includeProjects = true
  @State private var includeLibraryItems = true
  @State private var includeTelemetry = true
  @State private var isWorking = false
  @State private var statusMessage: String?
  @State private var errorMessage: String?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        GroupBox("Sample Data to Seed") {
          VStack(alignment: .leading, spacing: 10) {
            Toggle(
              "Sample Conversations (4 rich multi-turn chats testing all renderer components)",
              isOn: $includeConversations
            )
            Toggle("Sample Projects (with instructions and assigned chats)", isOn: $includeProjects)
            Toggle("Sample Library Items (Markdown notes & JSON config)", isOn: $includeLibraryItems)
            Toggle("Sample Telemetry Events (Chat, Provider, Tool, MCP with request/tool counts)", isOn: $includeTelemetry)
          }
          .padding(8)
          .frame(maxWidth: .infinity, alignment: .leading)
        }

        GroupBox("Actions") {
          VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
              Button("Seed Sample Data", systemImage: "tray.and.arrow.down.fill") {
                Task { await seedSampleData() }
              }
              .buttonStyle(MacActionButtonStyle(.primary))
              .disabled(
                isWorking
                  || model.coreServices == nil
                  || (!includeConversations && !includeProjects && !includeLibraryItems && !includeTelemetry)
              )

              Button("Reload Workspace", systemImage: "arrow.clockwise") {
                Task { await reloadWorkspace() }
              }
              .buttonStyle(MacActionButtonStyle(.secondary))
              .disabled(isWorking || model.coreServices == nil)

              if isWorking {
                ProgressView()
                  .controlSize(.small)
              }
              Spacer()
            }

            Text("Appends realistic sample records into the active local workspace and calls reloadAfterDataMutation() without deleting your existing credentials or chats.")
              .font(.caption)
              .foregroundStyle(MacDesignTokens.Colors.textMuted)

            if let statusMessage {
              Text(statusMessage)
                .font(.caption)
                .foregroundStyle(MacDesignTokens.Colors.accent)
            }
            if let errorMessage {
              Text(errorMessage)
                .font(.caption)
                .foregroundStyle(.red)
            }
          }
          .padding(8)
        }
      }
      .padding(4)
    }
  }

  private func seedSampleData() async {
    guard let services = model.coreServices else { return }
    isWorking = true
    statusMessage = nil
    errorMessage = nil
    defer { isWorking = false }

    do {
      let now = Date()
      let target = resolvedSeedTarget()
      var seededSummary: [String] = []
      var createdConversationIDs: [ConversationID] = []

      if includeConversations {
        let fixtures = MacDeveloperSeedFixtures.conversations(referenceDate: now)
        var totalTurns = 0

        for (conversationOffset, spec) in fixtures.enumerated() {
          let conversation = try await services.conversationStore.createConversation(
            providerID: target.providerID,
            accountID: target.accountID,
            modelID: target.modelID,
            systemPrompt: spec.systemPrompt
          )

          let baseDate = now.addingTimeInterval(Double(-3_600 * (conversationOffset + 1)))
          for (turnOffset, turnSpec) in spec.turns.enumerated() {
            let turnDate = baseDate.addingTimeInterval(Double(turnOffset * 180))
            let turn = try await services.conversationStore.beginTurn(
              conversationID: conversation.id,
              userText: turnSpec.prompt,
              at: turnDate
            )

            for (roundOffset, round) in turnSpec.toolRounds.enumerated() {
              _ = try await services.conversationStore.appendToolRound(
                conversationID: conversation.id,
                messageID: turn.assistantMessage.id,
                round: round,
                at: turnDate.addingTimeInterval(Double(roundOffset + 1) * 1.5)
              )
            }

            let completionDate = turnDate.addingTimeInterval(
              Double(max(3, turnSpec.reasoningDurationSeconds ?? 4))
            )
            switch turnSpec.outcome {
            case .complete:
              var metadata: [String: String] = [
                ChatBilling.costKey: turnSpec.cost,
                ChatBilling.accuracyKey: ChatCostAccuracy.providerReported.rawValue,
                ChatBilling.modelRequestCountKey: String(max(1, turnSpec.toolRounds.count + 1)),
              ]
              if let duration = turnSpec.reasoningDurationSeconds {
                metadata["reasoningDurationSeconds"] = String(duration)
              }
              let response = ProviderResponse(
                text: turnSpec.answer,
                reasoning: turnSpec.reasoning,
                providerID: target.providerID,
                accountID: target.accountID,
                modelID: target.modelID,
                finishReason: "stop",
                usage: ProviderUsage(
                  inputTokens: turnSpec.inTokens,
                  outputTokens: turnSpec.outTokens,
                  cachedInputTokens: turnSpec.inTokens / 3,
                  reasoningTokens: turnSpec.reasoning.isEmpty ? 0 : turnSpec.reasoningTokens
                ),
                metadata: metadata,
                citations: turnSpec.citations
              )
              _ = try await services.conversationStore.completeMessage(
                conversationID: conversation.id,
                messageID: turn.assistantMessage.id,
                response: response,
                at: completionDate
              )

            case .cancelled:
              _ = try await services.conversationStore.cancelMessage(
                conversationID: conversation.id,
                messageID: turn.assistantMessage.id,
                content: turnSpec.answer,
                reasoning: turnSpec.reasoning,
                at: completionDate
              )

            case .failed(let error):
              _ = try await services.conversationStore.failMessage(
                conversationID: conversation.id,
                messageID: turn.assistantMessage.id,
                content: turnSpec.answer,
                reasoning: turnSpec.reasoning,
                error: error,
                at: completionDate
              )
            }
            totalTurns += 1
          }

          try await services.conversationStore.renameConversation(conversation.id, title: spec.title)
          createdConversationIDs.append(conversation.id)
        }
        seededSummary.append("\(createdConversationIDs.count) conversations (\(totalTurns) turns)")
      }

      if includeProjects {
        let existingNames = Set(await services.projectWorkspace.snapshot().projects.map(\.name))
        let baseName = "BYOK macOS Debug Project"
        var candidateName = baseName
        var suffix = 2
        while existingNames.contains(candidateName) {
          candidateName = "\(baseName) \(suffix)"
          suffix += 1
        }
        let project = try await services.projectWorkspace.createProject(
          name: candidateName,
          symbolName: "hammer.fill",
          accentID: "blue",
          accountID: model.providers?.accounts.first?.id,
          modelID: model.providers?.accounts.first?.defaultModelID,
          instructions: "Focus on macOS 15 SwiftUI architecture, strict concurrency, and local-first privacy."
        )
        if let firstConversation = createdConversationIDs.first {
          try await services.projectWorkspace.assignConversation(firstConversation, to: project.id)
        }
        seededSummary.append("1 project (\(candidateName))")
      }

      if includeLibraryItems {
        let noteMarkdown = """
        # BYOKchat macOS Debug Notes

        - Local Keychain storage for provider API keys
        - SQLite FTS5 full-text conversation search
        - Privacy-sanitized local telemetry and rollups
        """
        if let noteData = noteMarkdown.data(using: .utf8) {
          _ = try await services.libraryStore.add(
            filename: "debug-architecture-notes.md",
            mimeType: "text/markdown",
            data: noteData
          )
        }
        let configJSON = """
        {
          "workspace": "BYOKmac",
          "deploymentTarget": "macOS 15.0",
          "fts5": true
        }
        """
        if let jsonData = configJSON.data(using: .utf8) {
          _ = try await services.libraryStore.add(
            filename: "debug-workspace-config.json",
            mimeType: "application/json",
            data: jsonData
          )
        }
        seededSummary.append("2 library items")
      }

      if includeTelemetry {
        let sampleConversationID = createdConversationIDs.first ?? ConversationID(rawValue: "seed-debug-chat")
        let events: [TelemetryEvent] = [
          TelemetryEvent(
            timestamp: now.addingTimeInterval(-300),
            dataClass: .analytics,
            category: .chat,
            name: .chatTurnCompleted,
            severity: .info,
            outcome: .success,
            conversationID: sampleConversationID,
            providerID: target.providerID,
            accountID: target.accountID,
            modelID: target.modelID,
            durationMilliseconds: 2_450,
            timeToFirstTokenMilliseconds: 340,
            inputTokens: 1_840,
            outputTokens: 412,
            cachedInputTokens: 610,
            reasoningTokens: 140,
            modelRequestCount: 2,
            toolCallCount: 1,
            metadata: ["seed": "developer_tools"]
          ),
          TelemetryEvent(
            timestamp: now.addingTimeInterval(-240),
            dataClass: .diagnostic,
            category: .mcp,
            name: .mcpRequestCompleted,
            severity: .info,
            outcome: .success,
            conversationID: sampleConversationID,
            providerID: target.providerID,
            accountID: target.accountID,
            modelID: target.modelID,
            durationMilliseconds: 185,
            modelRequestCount: 1,
            toolCallCount: 2,
            httpStatus: 200,
            metadata: ["transport": "streamable_http", "seed": "developer_tools"]
          ),
          TelemetryEvent(
            timestamp: now.addingTimeInterval(-180),
            dataClass: .diagnostic,
            category: .provider,
            name: .providerRequestFailed,
            severity: .warning,
            outcome: .failure,
            conversationID: sampleConversationID,
            providerID: target.providerID,
            accountID: target.accountID,
            modelID: target.modelID,
            durationMilliseconds: 610,
            httpStatus: 429,
            errorCode: "rate_limit_exceeded",
            metadata: ["classification": "rate_limit", "seed": "developer_tools"]
          ),
        ]
        for event in events {
          await services.telemetryRecorder.record(event)
        }
        await services.telemetryRecorder.performMaintenance(referenceDate: now)
        seededSummary.append("\(events.count) telemetry events")
      }

      try await model.reloadAfterDataMutation()
      await model.chats?.reconcileSearchIndex()
      statusMessage = "Seeded \(seededSummary.joined(separator: ", ")) and reloaded workspace."
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func reloadWorkspace() async {
    isWorking = true
    statusMessage = nil
    errorMessage = nil
    defer { isWorking = false }
    do {
      try await model.reloadAfterDataMutation()
      statusMessage = "Workspace reloaded."
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func resolvedSeedTarget() -> (providerID: ProviderID, accountID: ProviderAccountID, modelID: ModelID) {
    if let providers = model.providers {
      if let preferred = providers.preferredTarget(), let account = providers.account(preferred.accountID) {
        return (account.providerID, account.id, preferred.modelID)
      }
      if let first = providers.accounts.first {
        let modelID = first.defaultModelID
          ?? providers.models(for: first.id).first?.model.id
          ?? ModelID(rawValue: "claude-sonnet-4-5")
        return (first.providerID, first.id, modelID)
      }
    }
    return (
      BuiltInProviders.anthropicID,
      ProviderAccountID(rawValue: "seed-debug-account"),
      ModelID(rawValue: "claude-sonnet-4-5")
    )
  }
}

private enum MacDeveloperSeedFixtures {
  enum TurnOutcome: Sendable {
    case complete
    case cancelled
    case failed(ProviderError)
  }

  struct SeedTurn: Sendable {
    let prompt: String
    let answer: String
    let reasoning: String
    let reasoningDurationSeconds: Int?
    let inTokens: Int
    let outTokens: Int
    let reasoningTokens: Int
    let cost: String
    let citations: [ChatCitation]
    let toolRounds: [ChatToolRound]
    let outcome: TurnOutcome

    init(
      prompt: String,
      answer: String,
      reasoning: String = "",
      reasoningDurationSeconds: Int? = nil,
      inTokens: Int = 1_400,
      outTokens: Int = 520,
      reasoningTokens: Int = 180,
      cost: String = "0.0094",
      citations: [ChatCitation] = [],
      toolRounds: [ChatToolRound] = [],
      outcome: TurnOutcome = .complete
    ) {
      self.prompt = prompt
      self.answer = answer
      self.reasoning = reasoning
      self.reasoningDurationSeconds = reasoningDurationSeconds
      self.inTokens = inTokens
      self.outTokens = outTokens
      self.reasoningTokens = reasoningTokens
      self.cost = cost
      self.citations = citations
      self.toolRounds = toolRounds
      self.outcome = outcome
    }
  }

  struct SeedConversationSpec: Sendable {
    let title: String
    let systemPrompt: String
    let turns: [SeedTurn]
  }

  /// Self-contained 128×64 geometric PNG data URI so inline image rendering and
  /// the Save Images toolbar action can be tested completely offline.
  private static let samplePNGDataURI =
    "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAIAAAABACAYAAADS1n9/AAAA4ElEQVR42u3SMRGAMBBE0UiIgvQ4YAY5mcEHsigQlY4ORFx394oV8GdfG9vxRbY/b2jzXKH1+wqten8DAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgJQAH1u4HAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgJwAH1u4HAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgJwAH1u4HAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgZf8POf58Zky55iMAAAAASUVORK5CYII="

  static func conversations(referenceDate now: Date) -> [SeedConversationSpec] {
    [
      rendererKitchenSinkConversation(),
      mathAndTablesConversation(),
      diagramsArtifactsAndImagesConversation(),
      toolsReasoningAndLongSessionConversation(referenceDate: now),
    ]
  }

  // MARK: - 1. Typography, Callouts, Disclosures, Footnotes, Code & States

  private static func rendererKitchenSinkConversation() -> SeedConversationSpec {
    SeedConversationSpec(
      title: "Renderer Kitchen Sink — Typography, Callouts & Footnotes",
      systemPrompt: "Provide thorough, well-structured Markdown responses covering every formatting element.",
      turns: [
        SeedTurn(
          prompt: "Show a full Markdown typography stress test: H1–H6 headings, inline styles, 3-level nested bullets, a 12-item ordered list, task checkboxes, blockquotes, and thematic breaks.",
          answer: #"""
          # H1 · Typography & Hierarchy with `inlineCode`

          ## H2 · Body Copy, **Bold**, *Italic* & Links

          Paragraphs should flow cleanly with unified leading across selectable text, streaming tail, and `MarkdownUI`. This line mixes **bold emphasis**, *italic phrasing*, ***bold italic***, ~~deprecated APIs~~, inline `NSLayoutManager` pills, and a named link to [Apple Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/).

          ### H3 · Nested Unordered Lists (`•` → `◦` → `▪`)

          - **Level 1 · Transcript Layout**
            - **Level 2 · Hanging Indents**
              - **Level 3 · Deep Leaf**: Wrapped lines stay aligned under the first character of the item text rather than falling back under the bullet glyph.
              - **Level 3 · Inline Code**: Keep `NSTextTab` stops synced with `headIndent`.
            - **Level 2 · Block Spacing**: Trailing list items get extra breathing room before the next paragraph.
          - **Level 1 · Selection & Copy**
            - Supports cross-block selection and **Copy as Markdown** fidelity.

          #### H4 · Multi-Digit Ordered List Alignment

          1. Normalize incoming Markdown chunks and strip stray carriage returns.
          2. Split top-level fences, display math, GFM tables, callouts, `<details>`, and footnotes.
          3. Pre-warm `MacAnswerContentParseCache` off the main thread.
          4. Measure the widest ordinal prefix so single- and double-digit numbers align cleanly.
          5. Apply stepped bullet glyphs (`•`, `◦`, `▪`) per indentation level.
          6. Render GFM task checkboxes using crisp SF Symbol attachments.
          7. Draw rounded inline code pills and left-accent blockquote cards in `drawBackground(in:)`.
          8. Draw full-width `1pt` thematic break hairlines instead of Unicode dash runs.
          9. Highlight in-conversation Find (`⌘F`) matches with distinct active-match tinting.
          10. Verify tab-stop alignment at item ten so `10.` never collides with body copy.
          11. Preserve original raw Markdown in `markdownSourceAttributeKey` for Copy as Markdown.
          12. Confirm trailing paragraph spacing clears to `0pt` on the final line of a block.

          ##### H5 · GFM Task Checklist

          - [x] Unified body leading (`0.32em`) and list leading (`0.28em`)
          - [x] Tab-stopped hanging indents for nested lists and multi-digit ordinals
          - [x] Custom rounded inline-code pills and blockquote cards
          - [ ] Verify light and dark themes across all 10+ palette presets

          ###### H6 · Blockquotes & Thematic Breaks

          > Good typography is invisible until it breaks.
          >
          > Multi-paragraph blockquotes should retain a continuous subtle card surface and a crisp `3pt` left accent bar without injecting copyable literal bar glyphs.

          ---

          That concludes the typography baseline below a full-width horizontal rule.
          """#,
          reasoning: """
          Organize the typography audit so every heading level (H1–H6), inline decoration, list depth, checkbox state, blockquote card, and thematic break can be visually inspected in a single turn.

          Include at least 12 ordered list items so the single-to-double digit transition (`9.` → `10.`) exercises measured tab stops.
          """,
          reasoningDurationSeconds: 6,
          inTokens: 1_920,
          outTokens: 690,
          reasoningTokens: 210,
          cost: "0.0154"
        ),
        SeedTurn(
          prompt: "Now render all five GitHub-style callout alerts plus collapsible HTML details disclosures.",
          answer: #"""
          Here are all five supported GFM callout alert variants followed by collapsible `<details>` disclosures:

          > [!NOTE]
          > Useful context that users should notice even when skimming a long technical explanation. Links like [Swift.org](https://swift.org) remain clickable inside callouts.

          > [!TIP]
          > Press `⌘+`, `⌘-`, or `⌘0` to scale transcript typography smoothly across paragraphs, code blocks, tables, footnotes, and LaTeX equations.

          > [!IMPORTANT]
          > Key architectural requirement: always keep SQLite persistence and background parsing off `@MainActor` to guarantee 60fps scrolling.

          > [!WARNING]
          > Modifying `*.xcodeproj` directly will be overwritten the next time `xcodegen generate` runs. Edit `project.yml` instead.

          > [!CAUTION]
          > Destructive operations such as wiping local credentials or resetting the workspace database cannot be undone without a backup.

          <details>
          <summary>Collapsible Disclosure · Build & Cache Pipeline Notes</summary>

          Disclosures stay collapsed by default to keep long responses compact, and can contain rich Markdown inside:

          - Pre-parsed `MacPreparedAnswer` blocks cached by content hash
          - Deduplicated source extraction across paragraphs, tables, callouts, `<details>`, and footnotes
          - In-chat Find (`⌘F`) highlighting inside expanded bodies

          See https://developer.apple.com/documentation/swiftui for reference.
          </details>

          <details>
          <summary>Collapsible Disclosure · Sample Configuration Snippet</summary>

          Set `transcriptFontSize` between `12pt` and `24pt` in Preferences, or right-click any prose selection to **Copy as Markdown**.
          </details>
          """#,
          reasoning: "Include every MacCalloutKind case (.note, .tip, .important, .warning, .caution) and two <details> blocks with inline formatting and links.",
          reasoningDurationSeconds: 4,
          inTokens: 2_310,
          outTokens: 480,
          reasoningTokens: 120,
          cost: "0.0128"
        ),
        SeedTurn(
          prompt: "Test GFM footnotes with inline superscripts, multi-line continuations, bare URLs, and structured provider citations.",
          answer: #"""
          Modern macOS AI workspaces combine native AppKit text selection[^1] with structured streaming snapshots[^2] so completed paragraphs never re-layout while tokens arrive[^perf]. Keep literal markers like `[^3]` inside inline code untouched so technical docs about Markdown syntax stay accurate.

          Structured provider citations also merge cleanly into the **Sources** toolbar popover alongside footnote links.

          **Footnotes / Sources:**
          [^1]: Apple Developer Documentation - *NSTextView & TextKit 2*: https://developer.apple.com/documentation/appkit/nstextview
          [^2]: Swift Evolution - *Structured Concurrency & Actors*: https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/

          [^perf]: Performance notes from internal profiling:
            Keep streaming tail formatting lightweight via `MacStreamingTailFormatter`, and promote blocks to `MacStableRenderedAnswerBlockView` once structurally closed.
            Reference: [WWDC Performance Sessions](https://developer.apple.com/videos/performance/)
          """#,
          reasoning: "Combine inline [^1]/[^2]/[^perf] markers, literal `[^3]` inside backticks, multi-line indented footnote continuation, and structured ChatCitation metadata.",
          reasoningDurationSeconds: 5,
          inTokens: 2_640,
          outTokens: 390,
          reasoningTokens: 145,
          cost: "0.0119",
          citations: [
            ChatCitation(
              url: "https://developer.apple.com/documentation/appkit/nstextview",
              title: "NSTextView — AppKit Documentation",
              snippet: "A view that draws text and handles user interactions with that text.",
              startIndex: nil,
              endIndex: nil
            ),
            ChatCitation(
              url: "https://github.github.com/gfm/",
              title: "GitHub Flavored Markdown Spec",
              snippet: "Formal specification for tables, task lists, autolinks, and GFM extensions.",
              startIndex: nil,
              endIndex: nil
            ),
          ]
        ),
        SeedTurn(
          prompt: """
          Can you show multi-language syntax-highlighted code blocks (Swift, TypeScript, Python, SQL, Bash, JSON) with at least one wide line to test horizontal code scrolling?
          Reference links to test user bubble link detection:
          - https://docs.swift.org/swift-book/
          - Check (www.apple.com/macos)!
          """,
          answer: #"""
          Here is a multi-language syntax highlighting suite covering copy buttons, language badges, and horizontal overflow:

          ```swift
          import Foundation

          actor SnapshotPipeline<Element: Sendable> {
            private var cache: [String: Element] = [:]

            func cachedValue(for key: String, build: @Sendable () async throws -> Element) async rethrows -> Element {
              if let existing = cache[key] { return existing }
              let computed = try await build()
              cache[key] = computed
              return computed
            }
          }
          ```

          ```typescript
          export interface StreamChunk {
            readonly id: string;
            readonly delta: string;
            readonly usage?: { inputTokens: number; outputTokens: number; cachedInputTokens?: number };
          }

          export async function* decodeSSE(stream: ReadableStream<Uint8Array>): AsyncGenerator<StreamChunk> {
            const decoder = new TextDecoder();
            for await (const raw of stream) {
              for (const line of decoder.decode(raw, { stream: true }).split("\n")) {
                if (line.startsWith("data: ") && line !== "data: [DONE]") yield JSON.parse(line.slice(6));
              }
            }
          }
          ```

          ```python
          from dataclasses import dataclass
          from typing import Iterable

          @dataclass(frozen=True)
          class LatencySummary:
              p50_ms: float
              p95_ms: float
              sample_count: int

          def summarize_latencies(samples: Iterable[float]) -> LatencySummary:
              ordered = sorted(samples)
              n = len(ordered)
              return LatencySummary(ordered[n // 2], ordered[int(n * 0.95)], n)
          ```

          ```sql
          SELECT
            c.id AS conversation_id,
            c.title,
            COUNT(m.id) AS message_count,
            ROUND(SUM(COALESCE(m.cost_usd, 0)), 4) AS total_cost_usd
          FROM conversations c
          LEFT JOIN messages m ON m.conversation_id = c.id
          WHERE c.archived_at IS NULL
          GROUP BY c.id
          ORDER BY c.updated_at DESC
          LIMIT 25;
          ```

          ```bash
          # Long horizontal command line to verify code block horizontal scroll without wrapping distortion
          xcodebuild -project BYOKchat.xcodeproj -scheme BYOKmac -configuration Debug -destination "platform=macOS,arch=arm64" CODE_SIGNING_ALLOWED=NO test-without-building
          ```

          ```json
          {
            "renderer": "BYOKmac",
            "unifiedSelection": true,
            "features": ["markdown", "latex", "mermaid", "tables", "callouts", "details", "footnotes", "artifacts"]
          }
          ```
          """#,
          reasoning: "Cover 6 common languages with realistic idioms plus one intentionally long line in bash to test horizontal scrolling.",
          reasoningDurationSeconds: 5,
          inTokens: 3_120,
          outTokens: 780,
          reasoningTokens: 160,
          cost: "0.0198"
        ),
        SeedTurn(
          prompt: "Simulate a cancelled generation so we can verify partial output styling.",
          answer: """
          Starting a deep dive into SQLite WAL checkpoint tuning for macOS desktop apps:

          1. **WAL Mode**: Enables concurrent readers while a single writer appends frames to `-wal`.
          2. **Checkpoint Thresholds**: By default SQLite runs a passive checkpoint every 1,000 pages…
          """,
          reasoning: "Outline WAL mode, checkpoint cadence, and pragma settings before cancellation.",
          outcome: .cancelled
        ),
        SeedTurn(
          prompt: "Simulate a rate-limited provider error turn to verify error presentation in the transcript.",
          answer: "Partial draft before the upstream gateway returned HTTP 429.",
          reasoning: "Attempting completion against upstream provider.",
          outcome: .failed(.rateLimited(retryAfter: "30"))
        ),
      ]
    )
  }

  // MARK: - 2. Inline Math, Display Math & Rich GFM Tables

  private static func mathAndTablesConversation() -> SeedConversationSpec {
    SeedConversationSpec(
      title: "Math Equations & Rich GFM Tables Showcase",
      systemPrompt: "Use clear LaTeX math notation and well-formatted GFM tables.",
      turns: [
        SeedTurn(
          prompt: "Show inline math across plain text, bold-labeled lines, \\(...\\) syntax, mixed bold/links, and currency non-math edge cases.",
          answer: #"""
          Here are several inline math cases paired with real-world Markdown formatting:

          **Inline math:**
          The famous mass-energy equivalence is $E = mc^2$, and the Pythagorean theorem states that $a^2 + b^2 = c^2$.
          Another inline example: the sum of the first $n$ integers is $\sum_{i=1}^{n} i = \frac{n(n+1)}{2}$.

          The **derivative definition** using `\( ... \)` delimiters is \(f'(x) = \lim_{h \to 0} \frac{f(x+h) - f(x)}{h}\), while *Euler's identity* links five fundamental constants in $e^{i\pi} + 1 = 0$ (see [Wikipedia](https://en.wikipedia.org/wiki/Euler%27s_identity)).

          ### Non-Math Edge Cases
          Tickets cost $10-$20 each, discounted from \$25.00 to \$15.50, and shell environment variables like `$PATH` or `$HOME` stay literal text without triggering LaTeX rendering.
          """#,
          reasoning: "Exercise bold-labeled inline math without a blank line, both $...$ and \\(...\\) delimiters, inline bold/italic/links alongside math, and currency/backtick false-positive guards.",
          reasoningDurationSeconds: 5,
          inTokens: 1_450,
          outTokens: 340,
          reasoningTokens: 130,
          cost: "0.0096"
        ),
        SeedTurn(
          prompt: "Now show standalone display math blocks including integrals, matrices, limits, vector calculus, and multi-line aligned derivations.",
          answer: #"""
          **Standalone / Display math (`$$...$$` and `\[...\]`):**

          $$
          \int_a^b f(x)\,dx = F(b) - F(a)
          $$

          $$
          \begin{pmatrix} 1 & 0 & 0 \\ 0 & \cos\theta & -\sin\theta \\ 0 & \sin\theta & \cos\theta \end{pmatrix}
          $$

          $$
          \lim_{x \to \infty} \frac{1}{x} = 0
          $$

          \[
          \nabla \cdot \mathbf{E} = \frac{\rho}{\varepsilon_0}, \qquad \nabla \times \mathbf{B} = \mu_0 \mathbf{J} + \mu_0 \varepsilon_0 \frac{\partial \mathbf{E}}{\partial t}
          \]

          $$
          \begin{aligned}
          \text{Attention}(Q, K, V) &= \text{softmax}\!\left(\frac{QK^\top}{\sqrt{d_k}}\right) V \\
          \mathcal{L}_{\text{CE}} &= -\frac{1}{N} \sum_{i=1}^{N} \log p_\theta(y_i \mid x_i)
          \end{aligned}
          $$
          """#,
          reasoning: "Verify Retina scaling, display-math boost, horizontal overflow handling on wide equations, and both $$ and \\[...\\] block delimiters.",
          reasoningDurationSeconds: 4,
          inTokens: 1_890,
          outTokens: 310,
          reasoningTokens: 110,
          cost: "0.0099"
        ),
        SeedTurn(
          prompt: "Render both a compact aligned table with inline math, escaped pipes, and `<br>` cells, and a wide 7-column scrollable comparison table.",
          answer: #"""
          ### Compact Aligned Table (Math, Escaped Pipes, `<br>` & Links)

          | # | Algorithm | Time Complexity | Notes |
          | ---: | :--- | :---: | :--- |
          | 1 | Binary Search | $O(\log n)$ | Requires sorted input<br>Zero extra allocations |
          | 2 | Merge Sort | $O(n \log n)$ | Stable divide-and-conquer<br>Uses `a \| b` bitmask flags in variant |
          | 3 | Gauss Sum | $\frac{n(n+1)}{2}$ | Closed-form arithmetic series ([Proof](https://en.wikipedia.org/wiki/Triangular_number)) |
          | 4 | Matrix Multiply | $O(n^3)$ | Naive triple loop<br>SIMD / Accelerate lowers constants |

          ### Wide 7-Column Horizontally Scrollable Table

          | Model Family | Context Window | Streaming | Reasoning Traces | Tool Calling | Vision Input | Pricing Notes |
          | :--- | ---: | :---: | :---: | :---: | :---: | :--- |
          | Claude Sonnet 4.5 | 200,000 | Yes | Extended Thinking | Native + MCP | Images + PDF | Prompt caching reduces repeated system cost by up to 90% |
          | GPT-5 | 400,000 | Yes | Summary + Effort | Parallel Functions | High-res Vision | Automatic prefix cache discounts on long multi-turn histories |
          | Gemini 2.5 Pro | 1,000,000 | Yes | Thinking Budget | Grounding + Tools | Multimodal | Supports Google Search grounding with structured citations |
          | DeepSeek R1 | 128,000 | Yes | Full CoT | JSON + Tools | Text-focused | Competitive per-token pricing for math & code analysis |
          | Local Ollama (Qwen 3) | 32,768 | Yes | Optional `<think>` | Local MCP | Model-dependent | $0.00 local inference on Apple Silicon Unified Memory |
          """#,
          reasoning: "Build two tables: one compact with alignments, LaTeX cells, escaped pipes, and <br> line breaks; one wide 7-column matrix to exercise horizontal scrolling and TSV export.",
          reasoningDurationSeconds: 5,
          inTokens: 2_420,
          outTokens: 640,
          reasoningTokens: 155,
          cost: "0.0156"
        ),
      ]
    )
  }

  // MARK: - 3. Mermaid Diagrams, Sandboxed HTML/SVG Artifacts & Inline Image

  private static func diagramsArtifactsAndImagesConversation() -> SeedConversationSpec {
    SeedConversationSpec(
      title: "Diagrams, HTML/SVG Artifacts & Embedded Images",
      systemPrompt: "Demonstrate Mermaid diagrams, sandboxed HTML/SVG artifacts, and embedded data-URI images.",
      turns: [
        SeedTurn(
          prompt: "Render Mermaid flowchart, sequence, state, ER diagrams, plus an unsupported pie chart to verify fallback handling.",
          answer: #"""
          ### Streaming & Render Pipeline (`flowchart`)

          ```mermaid
          flowchart LR
            A[SSE Token Delta] --> B[splitStreamingSource]
            B --> C[Stable Blocks Cache]
            B --> D[Streaming Tail Formatter]
            C --> E[AppKit Selectable / LaTeX / Mermaid]
            D --> F[Progressive Inline SwiftUI Text]
          ```

          ### Tool-Augmented Turn (`sequenceDiagram`)

          ```mermaid
          sequenceDiagram
            participant U as User
            participant App as BYOKmac
            participant LLM as Provider API
            participant MCP as MCP Server
            U->>App: Send prompt
            App->>LLM: Stream request + tool schemas
            LLM-->>App: tool_call(search_docs)
            App->>MCP: Invoke tool
            MCP-->>App: JSON result
            App->>LLM: Replay tool result
            LLM-->>App: Final streamed answer
          ```

          ### Message Lifecycle (`stateDiagram-v2`)

          ```mermaid
          stateDiagram-v2
            [*] --> Streaming
            Streaming --> ToolCall : tool_use
            ToolCall --> Streaming : tool_result
            Streaming --> Complete : stop
            Streaming --> Cancelled : user_stop
            Streaming --> Failed : transport_error
            Complete --> [*]
          ```

          ### Workspace Schema (`erDiagram`)

          ```mermaid
          erDiagram
            PROJECT ||--o{ CONVERSATION : organizes
            CONVERSATION ||--|{ MESSAGE : contains
            MESSAGE ||--o{ TOOL_ROUND : invokes
            MESSAGE ||--o{ CITATION : references
          ```

          ### Graceful Unsupported Mermaid Fallback (`pie`)

          ```mermaid
          pie title Token Breakdown
            "Input" : 62
            "Cached Input" : 24
            "Output" : 14
          ```
          """#,
          reasoning: "Cover the supported BeautifulMermaid diagram types (flowchart, sequenceDiagram, stateDiagram-v2, erDiagram) plus one unsupported type (pie) to verify the fallback notice and source view.",
          reasoningDurationSeconds: 6,
          inTokens: 1_780,
          outTokens: 540,
          reasoningTokens: 165,
          cost: "0.0132"
        ),
        SeedTurn(
          prompt: "Generate both a sandboxed HTML interactive card and a crisp SVG vector graphic to test live artifact preview.",
          answer: #"""
          ### Sandboxed HTML Artifact (`html` — click **Preview** on the code block)

          ```html
          <!doctype html>
          <html lang="en">
          <head>
            <meta charset="utf-8" />
            <style>
              :root { color-scheme: light dark; font-family: -apple-system, BlinkMacSystemFont, sans-serif; }
              body { margin: 0; padding: 20px; background: #0f172a; color: #e2e8f0; }
              .card { max-width: 520px; border-radius: 14px; padding: 18px 20px; background: linear-gradient(135deg, #1e293b, #0f172a); border: 1px solid rgba(148, 163, 184, 0.25); }
              .row { display: grid; grid-template-columns: repeat(3, 1fr); gap: 10px; margin-top: 14px; }
              .stat { padding: 10px 12px; border-radius: 10px; background: rgba(15, 23, 42, 0.7); border: 1px solid rgba(148, 163, 184, 0.18); }
              .label { font-size: 11px; color: #94a3b8; text-transform: uppercase; letter-spacing: 0.04em; }
              .value { font-size: 20px; font-weight: 700; margin-top: 4px; color: #38bdf8; }
              .badge { display: inline-block; font-size: 11px; font-weight: 600; padding: 3px 8px; border-radius: 999px; background: rgba(16, 185, 129, 0.18); color: #34d399; }
            </style>
          </head>
          <body>
            <div class="card">
              <span class="badge">CSP SANDBOXED PREVIEW</span>
              <h2 style="margin: 10px 0 4px; font-size: 18px;">BYOKmac Renderer Telemetry</h2>
              <p style="margin: 0; font-size: 13px; color: #94a3b8;">Offline static HTML artifact with strict Content-Security-Policy.</p>
              <div class="row">
                <div class="stat"><div class="label">Frame Time</div><div class="value">4.2ms</div></div>
                <div class="stat"><div class="label">Cache Hit</div><div class="value">98.4%</div></div>
                <div class="stat"><div class="label">FTS5 Index</div><div class="value">12ms</div></div>
              </div>
            </div>
          </body>
          </html>
          ```

          ### Sandboxed SVG Artifact (`svg` — click **Preview** on the code block)

          ```svg
          <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 420 140" width="420" height="140">
            <rect width="420" height="140" rx="14" fill="#111827" />
            <text x="20" y="30" fill="#e5e7eb" font-family="-apple-system, sans-serif" font-size="13" font-weight="600">Render Latency by Block Type (ms)</text>
            <g font-family="-apple-system, sans-serif" font-size="11" fill="#9ca3af">
              <text x="20" y="58">Markdown</text>
              <rect x="96" y="47" width="84" height="14" rx="4" fill="#38bdf8" />
              <text x="188" y="58" fill="#e5e7eb">1.4 ms</text>
              <text x="20" y="84">LaTeX</text>
              <rect x="96" y="73" width="168" height="14" rx="4" fill="#818cf8" />
              <text x="272" y="84" fill="#e5e7eb">3.1 ms</text>
              <text x="20" y="110">Mermaid</text>
              <rect x="96" y="99" width="236" height="14" rx="4" fill="#34d399" />
              <text x="340" y="110" fill="#e5e7eb">4.6 ms</text>
            </g>
          </svg>
          ```
          """#,
          reasoning: "Provide self-contained HTML and SVG blocks with zero external resources so strict CSP preview works cleanly offline.",
          reasoningDurationSeconds: 4,
          inTokens: 2_190,
          outTokens: 610,
          reasoningTokens: 125,
          cost: "0.0147"
        ),
        SeedTurn(
          prompt: "Embed an offline inline data-URI image so we can verify Markdown image rendering and the Save Images toolbar button.",
          answer: """
          Below is an embedded `data:image/png;base64,...` geometric swatch rendered directly inside the Markdown stream without any network request:

          ![BYOKmac Offline Renderer Test Swatch](\(samplePNGDataURI))

          Hovering the message action bar should also display the **Save Images** control because `MacResponseImageScanner` detects valid embedded PNG payloads.
          """,
          reasoning: "Use a compact inline base64 PNG data URI so image loading and image export work reliably without network access.",
          reasoningDurationSeconds: 2,
          inTokens: 1_240,
          outTokens: 185,
          reasoningTokens: 65,
          cost: "0.0064"
        ),
      ]
    )
  }

  // MARK: - 4. MCP Tool Rounds, Error Recovery & Long Multi-Turn Scroll Session

  private static func toolsReasoningAndLongSessionConversation(referenceDate now: Date) -> SeedConversationSpec {
    let round1 = ChatToolRound(
      id: "seed-round-1",
      calls: [
        ChatToolCall(
          id: "call_search_1",
          name: "workspace.search_files",
          arguments: .object([
            "query": .string("MacAnswerContentParser"),
            "includeTests": .bool(true),
            "limit": .number(10),
          ])
        ),
        ChatToolCall(
          id: "call_metrics_2",
          name: "sqlite.query_metrics",
          arguments: .object([
            "windowDays": .number(7),
            "groupBy": .string("provider"),
          ])
        ),
      ],
      results: [
        ChatToolResult(
          callID: "call_search_1",
          name: "workspace.search_files",
          content: .object([
            "matches": .array([
              .string("BYOKmac/App/MacAnswerContentParser.swift"),
              .string("BYOKmac/App/MacAnswerContentParseCache.swift"),
              .string("Tests/BYOKmacTests/MacAnswerContentParserTests.swift"),
            ]),
            "durationMs": .number(18),
          ]),
          isError: false
        ),
        ChatToolResult(
          callID: "call_metrics_2",
          name: "sqlite.query_metrics",
          content: .object([
            "totalRequests": .number(142),
            "avgTTFTMs": .number(312),
            "cacheHitRatio": .number(0.68),
            "errorRate": .number(0.014),
          ]),
          isError: false
        ),
      ],
      assistantText: "Inspecting workspace parser files and recent 7-day SQLite latency metrics.",
      assistantReasoning: "Query file locations and telemetry aggregates before summarizing bottlenecks.",
      usage: ProviderUsage(inputTokens: 1_620, outputTokens: 190, cachedInputTokens: 540, reasoningTokens: 85),
      createdAt: now.addingTimeInterval(-14_350)
    )

    let errorRound = ChatToolRound(
      id: "seed-round-error-1",
      calls: [
        ChatToolCall(
          id: "call_fetch_err",
          name: "mcp.docs.fetch_section",
          arguments: .object([
            "path": .string("/api/v1/deprecated-endpoint"),
            "timeoutSeconds": .number(5),
          ])
        )
      ],
      results: [
        ChatToolResult(
          callID: "call_fetch_err",
          name: "mcp.docs.fetch_section",
          content: .object([
            "error": .string("NOT_FOUND"),
            "status": .number(404),
            "hint": .string("Use /api/v2/streaming-guide instead"),
          ]),
          isError: true
        )
      ],
      assistantText: "Checking the legacy documentation route first.",
      assistantReasoning: "Attempt v1 docs route and fall back to v2 if 404 is returned.",
      usage: ProviderUsage(inputTokens: 1_980, outputTokens: 95, cachedInputTokens: 900, reasoningTokens: 45),
      createdAt: now.addingTimeInterval(-14_150)
    )

    let recoveryRound = ChatToolRound(
      id: "seed-round-recovery-2",
      calls: [
        ChatToolCall(
          id: "call_fetch_ok",
          name: "mcp.docs.fetch_section",
          arguments: .object([
            "path": .string("/api/v2/streaming-guide"),
            "timeoutSeconds": .number(5),
          ])
        )
      ],
      results: [
        ChatToolResult(
          callID: "call_fetch_ok",
          name: "mcp.docs.fetch_section",
          content: .object([
            "status": .number(200),
            "title": .string("Streaming & Tool Continuation Guide v2"),
            "sections": .array([
              .string("Chunk Stabilization"),
              .string("Tool Replay Safety"),
              .string("Cancellation Semantics"),
            ]),
          ]),
          isError: false
        )
      ],
      assistantText: "Recovered via the v2 documentation endpoint.",
      assistantReasoning: "Synthesize the recovered guide into an actionable rollout checklist.",
      usage: ProviderUsage(inputTokens: 2_140, outputTokens: 140, cachedInputTokens: 1_120, reasoningTokens: 60),
      createdAt: now.addingTimeInterval(-14_145)
    )

    return SeedConversationSpec(
      title: "MCP Tool Rounds, Reasoning & Long Session Scroll Test",
      systemPrompt: "Use MCP tools when helpful, explain reasoning clearly, and keep engineering guidance concrete.",
      turns: [
        SeedTurn(
          prompt: "Audit our parser files and 7-day telemetry metrics using the workspace and SQLite tools.",
          answer: #"""
          ## Audit Summary

          Both tool calls completed cleanly:

          - **Parser Surface**: Found 3 primary files (`MacAnswerContentParser.swift`, `MacAnswerContentParseCache.swift`, and unit tests)[^1].
          - **7-Day Telemetry**: `142` requests with **312 ms** average TTFT, **68%** prompt-cache hit ratio, and a **1.4%** error rate.

          > [!TIP]
          > Expand the **2 tool calls** disclosure above to inspect the syntax-highlighted JSON arguments and responses.

          [^1]: Local workspace search matched `BYOKmac/App/MacAnswerContentParser.swift` in 18 ms.
          """#,
          reasoning: """
          1. Locate all parser files so we know the exact caching boundary.
          2. Pull 7-day SQLite latency aggregates to confirm TTFT and cache efficiency.
          3. Highlight the key metrics concisely without repeating raw JSON verbatim.
          """,
          reasoningDurationSeconds: 9,
          inTokens: 2_380,
          outTokens: 320,
          reasoningTokens: 240,
          cost: "0.0138",
          citations: [
            ChatCitation(
              url: "https://www.sqlite.org/fts5.html",
              title: "SQLite FTS5 Extension",
              snippet: "FTS5 is an SQLite virtual table module that provides full-text search functionality.",
              startIndex: nil,
              endIndex: nil
            )
          ],
          toolRounds: [round1]
        ),
        SeedTurn(
          prompt: "Fetch the streaming guide via MCP and recover gracefully if the old route returns 404.",
          answer: #"""
          The legacy `/api/v1/deprecated-endpoint` returned `404 NOT_FOUND` (shown as an error badge in Round 1), so I automatically followed the server hint to `/api/v2/streaming-guide`.

          | Section | Key Takeaway |
          | :--- | :--- |
          | Chunk Stabilization | Buffer incomplete `$...`, `[link](url`, and fenced blocks in the mutable tail |
          | Tool Replay Safety | Persist each `ChatToolRound` before starting the next provider round |
          | Cancellation Semantics | Retain partial streamed output and mark status `.cancelled` |
          """#,
          reasoning: "First tool round failed with 404; retried against /api/v2/streaming-guide and summarized all three sections.",
          reasoningDurationSeconds: 7,
          inTokens: 2_940,
          outTokens: 280,
          reasoningTokens: 175,
          cost: "0.0162",
          toolRounds: [errorRound, recoveryRound]
        ),
        SeedTurn(
          prompt: "How should we structure incremental FTS5 indexing so search stays instant even with 500+ long conversations?",
          answer: #"""
          ### Incremental FTS5 Strategy

          Keep an external-content FTS5 virtual table keyed by `message_id` and update only mutated rows inside the same write transaction as `ConversationStore.persist`:

          1. **Write-time delta sync**: Upsert the single changed message row on `.complete`, `.cancelled`, or rename rather than rebuilding the index.
          2. **Prefix queries (`prefix='2 3'`)**: Makes live search-as-you-type feel instantaneous on short queries like `swi` or `merm`.
          3. **BM25 column weights**: Weight conversation `title` (`4.0`) above message `content` (`1.0`) and `reasoning` (`0.4`).

          ```sql
          CREATE VIRTUAL TABLE IF NOT EXISTS message_fts USING fts5(
            conversation_id UNINDEXED,
            message_id UNINDEXED,
            title,
            content,
            reasoning,
            tokenize = 'unicode61 remove_diacritics 2',
            prefix = '2 3'
          );
          ```
          """#,
          reasoning: "Focus on write-time incremental updates, prefix tokenizers, and weighted BM25 ranking.",
          reasoningDurationSeconds: 5,
          inTokens: 3_320,
          outTokens: 360,
          reasoningTokens: 130,
          cost: "0.0149"
        ),
        SeedTurn(
          prompt: "Give me a quick Swift 6 checklist for keeping AppKit NSTextView bridges warning-free under strict concurrency.",
          answer: #"""
          ### Swift 6 + AppKit Bridge Checklist

          - **Isolate `NSViewRepresentable` helpers on `@MainActor`**: Avoid crossing isolation domains inside `updateNSView` or `drawBackground(in:)`.
          - **Capture value geometry before Objective-C block APIs**: Older AppKit methods like `enumerateEnclosingRects` lack `NS_NOESCAPE`, so capture `let viewWidth = bounds.width` outside the closure to avoid implicit `self` capture errors.
          - **Pass immutable `Sendable` style structs**: Compare `Style: Equatable` before mutating `NSTextStorage` so SwiftUI re-renders don't reset active text selection.
          - **Cache heavy parses off-main**: Keep `MacAnswerContentParser.parse` and `MarkdownContent` construction in `MacAnswerContentParseCache`.
          """#,
          reasoning: "Call out the exact Swift 6 strict concurrency pitfalls we hit with NSLayoutManager closures and NSTextView updates.",
          reasoningDurationSeconds: 4,
          inTokens: 3_680,
          outTokens: 295,
          reasoningTokens: 110,
          cost: "0.0141"
        ),
        SeedTurn(
          prompt: "Let's also check in-chat Find (⌘F) and Unified Selection Mode across long transcripts—what should we verify?",
          answer: #"""
          ### Verification Matrix for Long Transcripts

          > [!NOTE]
          > Try pressing `⌘F` and searching for **`Swift`**, **`FTS5`**, or **`LaTeX`** in this conversation to exercise multi-message match navigation and active highlight colors.

          - [x] `⌘F` highlights matches across user messages, assistant prose, callouts, `<details>`, footnotes, and code blocks
          - [x] Next/Previous match (`↩` / `⇧↩`) scrolls the active occurrence smoothly into view
          - [x] **Copy as Markdown** restores headings, lists, blockquotes, rules, and `[^id]` footnotes cleanly
          - [x] `⌘+` / `⌘-` / `⌘0` rescales body text, tables, footnotes, and MathJax SVGs together
          """#,
          reasoning: "Give concrete manual QA prompts so the developer can test ⌘F, Copy as Markdown, and zoom directly inside this seeded thread.",
          reasoningDurationSeconds: 3,
          inTokens: 4_010,
          outTokens: 265,
          reasoningTokens: 90,
          cost: "0.0139"
        ),
        SeedTurn(
          prompt: "Wrap up with a concise release sign-off summary and footnote references.",
          answer: #"""
          ### macOS Chat Renderer Sign-Off

          All core renderer subsystems—selectable AppKit Markdown, progressive streaming tail, `LaTeXSwiftUI` Retina math, `BeautifulMermaid` diagrams, sandboxed HTML/SVG previews, GFM callouts, `<details>` disclosures, footnotes, tables, embedded images, reasoning traces, and MCP tool rounds—are now represented across the seeded developer conversations[^signoff].

          [^signoff]: Seeded via **Developer Tools → Seed Data** (`MacDeveloperSeedFixtures`). Safe to re-run at any time; existing credentials and chats are preserved.
          """#,
          reasoning: "Provide a crisp final turn so the bottom of the 6-turn scroll view ends cleanly with a footnote.",
          reasoningDurationSeconds: 2,
          inTokens: 4_290,
          outTokens: 175,
          reasoningTokens: 70,
          cost: "0.0124"
        ),
      ]
    )
  }
}

// MARK: - Provider Console & Inspector

@MainActor
private struct MacProviderConsoleTab: View {
  let model: MacAppModel

  @State private var selectedAccountID: ProviderAccountID?
  @State private var selectedModelID: ModelID?
  @State private var prompt = "Respond in one concise sentence confirming native macOS streaming works."
  @State private var includeReasoning = false
  @State private var visibleText = ""
  @State private var reasoningText = ""
  @State private var consoleStatus = "Idle"
  @State private var actionFeedback: String?
  @State private var isTesting = false
  @State private var streamTask: Task<Void, Never>?
  @State private var streamRevision: UInt64 = 0

  private var providers: MacProviderModel? { model.providers }
  private var accounts: [ProviderAccount] { providers?.accounts ?? [] }

  private var selectedAccount: ProviderAccount? {
    guard let selectedAccountID else { return nil }
    return accounts.first { $0.id == selectedAccountID }
  }

  private var availableModels: [AccountModelRecord] {
    guard let providers, let selectedAccountID else { return [] }
    return providers.models(for: selectedAccountID, includeHidden: true)
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        GroupBox("Configured Account Inspector") {
          VStack(alignment: .leading, spacing: 10) {
            if accounts.isEmpty {
              Text("No provider connections configured yet. Add one in Settings → Connections.")
                .foregroundStyle(MacDesignTokens.Colors.textMuted)
            } else {
              HStack(spacing: 12) {
                Picker("Account", selection: $selectedAccountID) {
                  Text("Select account").tag(ProviderAccountID?.none)
                  ForEach(accounts) { account in
                    Text("\(account.label) (\(account.kind.displayName))")
                      .tag(Optional(account.id))
                  }
                }
                .onChange(of: selectedAccountID) { _, newValue in
                  syncDefaultModelSelection(for: newValue)
                }

                Picker("Model", selection: $selectedModelID) {
                  Text("Select model").tag(ModelID?.none)
                  ForEach(availableModels) { record in
                    Text(record.model.displayName).tag(Optional(record.model.id))
                  }
                }
              }

              if let account = selectedAccount, let providers {
                let definition = account.definition
                let resolvedBaseURL = account.baseURLOverride ?? definition.defaultBaseURL
                Divider()
                HStack(alignment: .top, spacing: 20) {
                  VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("Kind", value: account.kind.displayName)
                    LabeledContent("Provider ID", value: account.providerID.rawValue)
                    LabeledContent("Status", value: providers.isReady(account) ? "Ready" : (account.isEnabled ? "Needs setup" : "Disabled"))
                    LabeledContent("Credential", value: providers.hasCredential(account.id) ? "Stored in Keychain" : (definition.requiresCredential ? "Missing" : "Optional"))
                    LabeledContent("API Family", value: definition.apiFamily.rawValue)
                    LabeledContent("Auth", value: authDescription(definition.authentication))
                  }
                  .frame(maxWidth: .infinity, alignment: .leading)

                  VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("Resolved Base URL") {
                      Text(resolvedBaseURL.absoluteString)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    }
                    LabeledContent("Chat Path", value: definition.chatCompletionsPath)
                    LabeledContent("Models Path", value: definition.modelsPath ?? "None")
                    LabeledContent("Models Loaded", value: availableModels.count.formatted())
                    if let selectedModelID {
                      let caps = providers.capabilities(accountID: account.id, modelID: selectedModelID)
                      LabeledContent("Capabilities", value: capabilitySummary(caps))
                    }
                  }
                  .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: 10) {
                  Button("Test Connection", systemImage: "checkmark.shield") {
                    Task { await runConnectionTest() }
                  }
                  .buttonStyle(MacActionButtonStyle(.secondary))
                  .disabled(isTesting || selectedAccountID == nil)

                  Button("Refresh Models", systemImage: "arrow.clockwise") {
                    Task { await runModelDiscovery() }
                  }
                  .buttonStyle(MacActionButtonStyle(.secondary))
                  .disabled(isTesting || selectedAccountID == nil || definition.modelsPath == nil)

                  if isTesting {
                    ProgressView()
                      .controlSize(.small)
                  }
                  Spacer()
                }
                .padding(.top, 4)

                if let actionFeedback {
                  Text(actionFeedback)
                    .font(.caption)
                    .foregroundStyle(MacDesignTokens.Colors.textMuted)
                }
              }
            }
          }
          .padding(8)
        }

        GroupBox("Quick Live Stream Console") {
          VStack(alignment: .leading, spacing: 10) {
            TextEditor(text: $prompt)
              .font(.body)
              .frame(height: 68)
              .overlay {
                RoundedRectangle(cornerRadius: 6)
                  .stroke(MacDesignTokens.Colors.separator, lineWidth: 1)
              }

            HStack(spacing: 10) {
              Toggle("Request reasoning", isOn: $includeReasoning)
              Spacer()
              Button("Stream", systemImage: "paperplane.fill") {
                startStream()
              }
              .buttonStyle(MacActionButtonStyle(.primary))
              .disabled(
                selectedAccountID == nil
                  || selectedModelID == nil
                  || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  || streamTask != nil
              )

              Button("Stop", systemImage: "stop.fill", role: .destructive) {
                stopStream()
              }
              .buttonStyle(MacActionButtonStyle(.destructive))
              .disabled(streamTask == nil)
            }

            LabeledContent("Status", value: consoleStatus)
              .font(.caption)

            if !reasoningText.isEmpty {
              DisclosureGroup("Reasoning") {
                Text(reasoningText)
                  .font(.caption.monospaced())
                  .textSelection(.enabled)
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .padding(.top, 4)
              }
            }

            if !visibleText.isEmpty {
              Text(visibleText)
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(MacDesignTokens.Colors.surface, in: RoundedRectangle(cornerRadius: 8))
            }
          }
          .padding(8)
        }

        GroupBox("Registered Provider Definitions (\(providers?.definitions.count ?? 0))") {
          VStack(alignment: .leading, spacing: 6) {
            ForEach(providers?.definitions ?? []) { definition in
              HStack(spacing: 10) {
                Text(definition.displayName)
                  .font(.subheadline.weight(.medium))
                  .frame(width: 150, alignment: .leading)
                Text(definition.defaultBaseURL.absoluteString)
                  .font(.caption.monospaced())
                  .foregroundStyle(MacDesignTokens.Colors.textMuted)
                  .lineLimit(1)
                  .truncationMode(.middle)
                  .textSelection(.enabled)
                Spacer()
                Text("\(definition.apiFamily.rawValue) · \(definition.seedModels.count) seeds")
                  .font(.caption2)
                  .foregroundStyle(MacDesignTokens.Colors.textMuted)
              }
              .padding(.vertical, 2)
              Divider()
            }
          }
          .padding(8)
        }
      }
      .padding(4)
    }
    .onAppear {
      if selectedAccountID == nil {
        selectedAccountID = accounts.first?.id
        syncDefaultModelSelection(for: selectedAccountID)
      }
    }
    .onDisappear {
      stopStream()
    }
  }

  private func syncDefaultModelSelection(for accountID: ProviderAccountID?) {
    guard let accountID, let providers else {
      selectedModelID = nil
      return
    }
    selectedModelID = providers.account(accountID)?.defaultModelID
      ?? providers.models(for: accountID).first?.model.id
  }

  private func authDescription(_ auth: ProviderAuthentication) -> String {
    switch auth {
    case .bearer: "Bearer token"
    case .header(let name): "Header (\(name))"
    case .none: "None"
    }
  }

  private func capabilitySummary(_ caps: ResolvedModelCapabilities) -> String {
    var badges: [String] = []
    if caps[.reasoning] == .supported { badges.append("Reasoning") }
    if caps[.tools] == .supported { badges.append("Tools") }
    if caps[.imageInput] == .supported { badges.append("Vision") }
    if caps[.fileInput] == .supported { badges.append("Files") }
    if let ctx = caps.contextWindow { badges.append("\(ctx.formatted()) ctx") }
    if let maxOut = caps.maxOutputTokens { badges.append("\(maxOut.formatted()) out") }
    return badges.isEmpty ? "Standard text" : badges.joined(separator: " · ")
  }

  private func runConnectionTest() async {
    guard let providers, let selectedAccountID else { return }
    isTesting = true
    actionFeedback = nil
    defer { isTesting = false }
    let ok = await providers.testConnection(accountID: selectedAccountID, modelID: selectedModelID)
    actionFeedback = ok
      ? "Connection test succeeded."
      : (providers.errorMessage ?? "Connection test failed.")
  }

  private func runModelDiscovery() async {
    guard let providers, let selectedAccountID else { return }
    isTesting = true
    actionFeedback = nil
    defer { isTesting = false }
    let ok = await providers.refreshModels(accountID: selectedAccountID)
    actionFeedback = ok
      ? "Refreshed models (\(providers.models(for: selectedAccountID).count) visible)."
      : (providers.errorMessage ?? "Model refresh failed.")
  }

  private func startStream() {
    guard let services = model.coreServices,
      let accountID = selectedAccountID,
      let modelID = selectedModelID
    else { return }

    streamTask?.cancel()
    streamRevision &+= 1
    let revision = streamRevision
    let promptText = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    let wantReasoning = includeReasoning

    visibleText = ""
    reasoningText = ""
    consoleStatus = "Connecting…"

    streamTask = Task { @MainActor in
      do {
        let request = ProviderRequest(
          model: modelID,
          messages: [ProviderMessage(role: .user, content: promptText)],
          options: ProviderRequestOptions(
            reasoning: wantReasoning ? ReasoningOptions(enabled: true) : nil
          )
        )
        let stream = try await services.providerRuntime.stream(request: request, accountID: accountID)
        guard streamRevision == revision else { return }
        consoleStatus = "Streaming…"

        for try await event in stream {
          try Task.checkCancellation()
          guard streamRevision == revision else { return }
          switch event {
          case .textDelta(let delta):
            visibleText += delta
          case .reasoningDelta(let delta):
            reasoningText += delta
          case .usage(let usage):
            consoleStatus = "\(usage.inputTokens ?? 0) input · \(usage.outputTokens ?? 0) output"
          case .completed(let response):
            let finish = response.finishReason ?? "stop"
            consoleStatus = "Completed (\(finish))"
          }
        }
      } catch is CancellationError {
        guard streamRevision == revision else { return }
        consoleStatus = "Cancelled"
      } catch {
        guard streamRevision == revision else { return }
        consoleStatus = "Error: \(error.localizedDescription)"
      }

      guard streamRevision == revision else { return }
      streamTask = nil
    }
  }

  private func stopStream() {
    streamRevision &+= 1
    streamTask?.cancel()
    streamTask = nil
    if consoleStatus == "Streaming…" || consoleStatus == "Connecting…" {
      consoleStatus = "Cancelled"
    }
  }
}

// MARK: - Upsell Replays & Simulated Pro

#endif
