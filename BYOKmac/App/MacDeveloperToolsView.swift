#if DEBUG
import BYOKchatProviderCore
import Foundation
import MacAppFoundation
import SwiftUI

@MainActor
struct MacDeveloperToolsView: View {
  let model: MacAppModel
  let purchases: PurchaseManager
  let onboarding: OnboardingState

  private enum Tab: String, Hashable {
    case catalog
    case fts5
    case seed
    case providers
    case upsells
  }

  @State private var selectedTab: Tab = .catalog

  var body: some View {
    TabView(selection: $selectedTab) {
      MacCatalogInspectorTab(model: model)
        .tabItem {
          Label("Model Catalog", systemImage: "square.stack.3d.up")
        }
        .tag(Tab.catalog)

      MacFTS5InspectorTab(model: model, purchases: purchases)
        .tabItem {
          Label("FTS5 Search", systemImage: "magnifyingglass")
        }
        .tag(Tab.fts5)

      MacSeedDataTab(model: model)
        .tabItem {
          Label("Seed Data", systemImage: "tray.and.arrow.down.fill")
        }
        .tag(Tab.seed)

      MacProviderConsoleTab(model: model)
        .tabItem {
          Label("Provider Console", systemImage: "terminal")
        }
        .tag(Tab.providers)

      MacUpsellReplaysTab(purchases: purchases, onboarding: onboarding)
        .tabItem {
          Label("Pro & Upsells", systemImage: "crown")
        }
        .tag(Tab.upsells)
    }
    .padding(16)
    .frame(minWidth: 780, minHeight: 560)
    .background(MacDesignTokens.Colors.canvas)
    .macProUpsellPresenter()
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
              .disabled(isWorking || providers == nil || providers?.isRefreshingModelCatalog == true)

              Button("Check If Stale (TTL)", systemImage: "clock.arrow.circlepath") {
                Task { await refreshCatalog(force: false) }
              }
              .disabled(isWorking || providers == nil || providers?.isRefreshingModelCatalog == true)

              Button("Clear Catalog Cache", systemImage: "trash", role: .destructive) {
                Task { await clearCache() }
              }
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
              .disabled(isWorking || model.coreServices == nil)

              Button("Rebuild Index", systemImage: "arrow.clockwise") {
                Task { await rebuildIndex() }
              }
              .disabled(isWorking || model.coreServices == nil)

              Button("Clear Index", systemImage: "trash", role: .destructive) {
                confirmClear = true
              }
              .disabled(isWorking || status?.statistics.databaseExists != true)

              Button("Refresh Status", systemImage: "arrow.clockwise.circle") {
                Task { await reloadStatus() }
              }
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
            Toggle("Sample Conversations (Markdown, code blocks, usage metadata)", isOn: $includeConversations)
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
              .buttonStyle(.borderedProminent)
              .disabled(
                isWorking
                  || model.coreServices == nil
                  || (!includeConversations && !includeProjects && !includeLibraryItems && !includeTelemetry)
              )

              Button("Reload Workspace", systemImage: "arrow.clockwise") {
                Task { await reloadWorkspace() }
              }
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
        let samples: [(title: String, prompt: String, answer: String, reasoning: String, inTokens: Int, outTokens: Int, cost: String)] = [
          (
            title: "Swift 6 Strict Concurrency Audit",
            prompt: "Summarize the safest pattern for bridging an actor-backed store into an @Observable @MainActor SwiftUI model.",
            answer: """
            ## Recommended Bridge Pattern

            Keep persistence and SQLite access inside a dedicated `actor`, and publish immutable `Sendable` snapshots to your `@MainActor @Observable` UI model:

            ```swift
            @MainActor @Observable
            final class DiagnosticsBridge {
              private(set) var stats = TelemetryStoreStatistics.empty
              func refresh(from recorder: TelemetryRecorder) async {
                stats = await recorder.statistics()
              }
            }
            ```

            This avoids data races while keeping SwiftUI updates deterministic on the main actor.
            """,
            reasoning: "Evaluate actor isolation boundaries, Sendable value snapshots, and SwiftUI observation updates.",
            inTokens: 1_840,
            outTokens: 412,
            cost: "0.0117"
          ),
          (
            title: "macOS Release Readiness Checklist",
            prompt: "Turn our macOS v1.0 parity notes into a compact verification table.",
            answer: """
            | Area | Status | Notes |
            | --- | --- | --- |
            | Local Providers | Verified | Ollama & LM Studio optional API keys |
            | FTS5 Search | Verified | Incremental SQLite indexing |
            | Diagnostics | Verified | Daily rollups, MCP labels, ShareLink |
            """,
            reasoning: "Group parity areas into a scannable Markdown table suitable for release sign-off.",
            inTokens: 960,
            outTokens: 218,
            cost: "0.0061"
          ),
        ]

        for (offset, sample) in samples.enumerated() {
          let conversation = try await services.conversationStore.createConversation(
            providerID: target.providerID,
            accountID: target.accountID,
            modelID: target.modelID,
            systemPrompt: "Be concise, accurate, and practical."
          )
          let turnDate = now.addingTimeInterval(Double(-900 * (offset + 1)))
          let turn = try await services.conversationStore.beginTurn(
            conversationID: conversation.id,
            userText: sample.prompt,
            at: turnDate
          )
          let response = ProviderResponse(
            text: sample.answer,
            reasoning: sample.reasoning,
            providerID: target.providerID,
            accountID: target.accountID,
            modelID: target.modelID,
            finishReason: "stop",
            usage: ProviderUsage(
              inputTokens: sample.inTokens,
              outputTokens: sample.outTokens,
              cachedInputTokens: sample.inTokens / 3,
              reasoningTokens: 140
            ),
            metadata: [
              ChatBilling.costKey: sample.cost,
              ChatBilling.accuracyKey: ChatCostAccuracy.providerReported.rawValue,
              ChatBilling.modelRequestCountKey: "1",
            ]
          )
          _ = try await services.conversationStore.completeMessage(
            conversationID: conversation.id,
            messageID: turn.assistantMessage.id,
            response: response,
            at: turnDate.addingTimeInterval(4)
          )
          try await services.conversationStore.renameConversation(conversation.id, title: sample.title)
          createdConversationIDs.append(conversation.id)
        }
        seededSummary.append("\(createdConversationIDs.count) conversations")
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
                  .disabled(isTesting || selectedAccountID == nil)

                  Button("Refresh Models", systemImage: "arrow.clockwise") {
                    Task { await runModelDiscovery() }
                  }
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
              .buttonStyle(.borderedProminent)
              .disabled(
                selectedAccountID == nil
                  || selectedModelID == nil
                  || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  || streamTask != nil
              )

              Button("Stop", systemImage: "stop.fill", role: .destructive) {
                stopStream()
              }
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

@MainActor
private struct MacUpsellReplaysTab: View {
  let purchases: PurchaseManager
  let onboarding: OnboardingState

  @Environment(\.openWindow) private var openWindow

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        GroupBox("Pro Upsell Replays") {
          VStack(alignment: .leading, spacing: 10) {
            LabeledContent("Current Entitlement", value: purchases.hasPro ? "BYOK Pro Active" : "Free")

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 10)], spacing: 10) {
              ForEach(MacProFeature.allCases, id: \.rawValue) { feature in
                Button {
                  MacProGateCenter.shared.request(feature)
                } label: {
                  Label(featureTitle(feature), systemImage: featureSymbol(feature))
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
              }
            }

            Divider()

            HStack(spacing: 10) {
              Button("Open Pro Paywall", systemImage: "crown.fill") {
                openWindow(id: MacWindowID.proPaywall)
              }

              Button("Replay Onboarding", systemImage: "rectangle.stack.fill") {
                onboarding.restart()
                openWindow(id: BYOKmacWindowID.onboarding)
              }

              Spacer()
            }
          }
          .padding(8)
        }

        GroupBox("Simulated Entitlement Controls") {
          VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
              Button("Use Simulated Purchases", systemImage: "wrench.and.screwdriver") {
                UserDefaults.standard.set(true, forKey: MacPurchaseStore.simulatedModeKey)
                Task { await purchases.setSimulatedPurchasesEnabled(true) }
              }

              Button("Use StoreKit", systemImage: "bag") {
                UserDefaults.standard.set(false, forKey: MacPurchaseStore.simulatedModeKey)
                Task { await purchases.setSimulatedPurchasesEnabled(false) }
              }

              Button("Reset Simulated Purchases", systemImage: "arrow.counterclockwise", role: .destructive) {
                UserDefaults.standard.set(true, forKey: MacPurchaseStore.simulatedModeKey)
                Task {
                  await purchases.setSimulatedPurchasesEnabled(true)
                  await purchases.resetSimulatedPurchases()
                }
              }
              Spacer()
            }

            Divider()

            FoundationDeveloperView(
              purchaseManager: purchases,
              configuration: MacPurchaseStore.developerConfiguration
            )
            .frame(minHeight: 260)
          }
          .padding(8)
        }
      }
      .padding(4)
    }
  }

  private func featureTitle(_ feature: MacProFeature) -> String {
    switch feature.rawValue {
    case "providerAccounts": "Provider Connections"
    case "projects": "Projects"
    case "mcpServers": "MCP Servers"
    case "analytics": "Analytics History"
    case "themes": "Themes"
    case "chatSearch": "Full-Text Chat Search"
    default: feature.rawValue
    }
  }

  private func featureSymbol(_ feature: MacProFeature) -> String {
    switch feature.rawValue {
    case "providerAccounts": "key.horizontal.fill"
    case "projects": "folder.fill"
    case "mcpServers": "shippingbox.fill"
    case "analytics": "chart.bar.xaxis"
    case "themes": "paintpalette.fill"
    case "chatSearch": "magnifyingglass"
    default: "crown"
    }
  }
}
#endif
